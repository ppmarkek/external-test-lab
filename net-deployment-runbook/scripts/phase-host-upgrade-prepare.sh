#!/usr/bin/env bash
set -Eeuo pipefail

# Host-scoped target preparation. It deliberately has one SSH target and
# never obtains another operator's keys or connection details.
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]] || die 'host upgrade prepare requires --release v2026.08.06'

NODE="$(node_name "${1:-}")"
PROPOSAL_ID="${2:-}"
[[ "$PROPOSAL_ID" =~ ^[1-9][0-9]*$ ]] || die 'usage: host upgrade prepare <ssh-alias> <passed-proposal-id>'
topology_contains_node "$NODE" || die "unknown Host alias: $NODE"

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/host-upgrade-prepare-$NODE-$PROPOSAL_ID"
mkdir -p "$RUN"
install_evidence_exit_trap 'Host upgrade preparation'
record_phase_profile "host-upgrade-prepare-$NODE"
CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-https://$GENESIS_PUBLIC_HOST}"
CHAIN_BASE="${CHAIN_BASE%/}"
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json"   || die 'cannot read canonical public Genesis for host upgrade preparation'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
bind_run_manifest_genesis "$GENESIS_SHA256"

step "Verify immutable passed software-upgrade proposal $PROPOSAL_ID"
curl -fsS --connect-timeout 5 --max-time 15   "$CHAIN_BASE/chain-api/cosmos/gov/v1/proposals/$PROPOSAL_ID" >"$RUN/proposal.json"
upgrade_name="v$GONKA_RELEASE"
plan_height="$("$ROOT/scripts/verify-upgrade-proposal-binding.sh"   "$RUN/proposal.json" "$upgrade_name"   "$INFERENCED_UPGRADE_URL" "$INFERENCED_UPGRADE_SHA256"   "$DAPI_UPGRADE_URL" "$DAPI_UPGRADE_SHA256")"   || die "proposal $PROPOSAL_ID is not a passed immutable $upgrade_name upgrade"
current_height="$(curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status"   | jq -er '.result.sync_info.latest_block_height | tonumber')"
(( plan_height >= current_height + 1 ))   || die "proposal $PROPOSAL_ID activation height $plan_height has already passed; use host upgrade watch to record recovery state"

step "Pre-fetch exactly the pinned target artifacts on $NODE"
ssh_ready "$NODE" || die "$NODE is unreachable"
CACHE_DIR="/srv/dai/$NODE/gdc-upgrade-cache/$PROPOSAL_ID"
ssh "$NODE" "sudo install -d -m 0700 '$CACHE_DIR'"
ssh "$NODE" "sudo curl -fsSL '$INFERENCED_UPGRADE_URL' -o '$CACHE_DIR/inferenced.zip'"
ssh "$NODE" "sudo curl -fsSL '$DAPI_UPGRADE_URL' -o '$CACHE_DIR/decentralized-api.zip'"
ssh "$NODE" "printf '%s  %s\n%s  %s\n' '$INFERENCED_UPGRADE_SHA256' '$CACHE_DIR/inferenced.zip' '$DAPI_UPGRADE_SHA256' '$CACHE_DIR/decentralized-api.zip' | sudo sha256sum -c -"

STATE_FILE="$STATE/upgrade/$PROPOSAL_ID.env"
mkdir -p "$(dirname "$STATE_FILE")"
{
  printf 'state=PREPARED\n'
  printf 'prepared_at=%s\n' "$(date -u +%FT%TZ)"
  printf 'node=%s\n' "$NODE"
  printf 'proposal_id=%s\n' "$PROPOSAL_ID"
  printf 'plan_height=%s\n' "$plan_height"
  printf 'genesis_sha256=%s\n' "$GENESIS_SHA256"
  printf 'release_profile=%s\n' "$GDC_RELEASE_PROFILE"
  printf 'inferenced_sha256=%s\n' "$INFERENCED_UPGRADE_SHA256"
  printf 'dapi_sha256=%s\n' "$DAPI_UPGRADE_SHA256"
  printf 'remote_cache=%s\n' "$CACHE_DIR"
} >"$STATE_FILE"
jq -n --arg state PREPARED --arg node "$NODE" --arg proposal_id "$PROPOSAL_ID"   --argjson plan_height "$plan_height" --arg genesis_sha256 "$GENESIS_SHA256"   --arg remote_cache "$CACHE_DIR"   '{schema_version:1,state:$state,node:$node,proposal_id:$proposal_id,plan_height:$plan_height,genesis_sha256:$genesis_sha256,remote_cache:$remote_cache}'   >"$RUN/receipt.json"
cat >"$RUN/verdict.md" <<EOF
# Host upgrade preparation: PREPARED

$NODE independently verified proposal $PROPOSAL_ID, canonical Genesis lineage
and target artifact digests, then cached only its own target archives at
$CACHE_DIR. Run host upgrade watch $NODE $PROPOSAL_ID to observe activation.
EOF
printf 'PREPARED Host upgrade evidence: %s\n' "$RUN"
