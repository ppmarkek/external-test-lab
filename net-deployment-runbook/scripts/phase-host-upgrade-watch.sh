#!/usr/bin/env bash
set -Eeuo pipefail

# Host-scoped activation watcher. It observes only the named operator's
# endpoint and its own public consensus identity.
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]] || die 'host upgrade watch requires --release v2026.08.06'

NODE="$(node_name "${1:-}")"
PROPOSAL_ID="${2:-}"
[[ "$PROPOSAL_ID" =~ ^[1-9][0-9]*$ ]] || die 'usage: host upgrade watch <ssh-alias> <passed-proposal-id>'
STATE_FILE="$STATE/upgrade/$PROPOSAL_ID.env"
[[ -s "$STATE_FILE" ]] || die "no PREPARED state for proposal $PROPOSAL_ID; run host upgrade prepare $NODE $PROPOSAL_ID first"
grep -qx "node=$NODE" "$STATE_FILE" || die "prepared upgrade state belongs to another Host"
grep -qx "proposal_id=$PROPOSAL_ID" "$STATE_FILE" || die 'prepared upgrade state has a different proposal ID'
grep -qx 'state=PREPARED' "$STATE_FILE" || die 'prepared upgrade state is not resumable from PREPARED'

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/host-upgrade-watch-$NODE-$PROPOSAL_ID"
mkdir -p "$RUN"
install_evidence_exit_trap 'Host upgrade watch'
record_phase_profile "host-upgrade-watch-$NODE"
CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-https://$GENESIS_PUBLIC_HOST}"
CHAIN_BASE="${CHAIN_BASE%/}"
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json"   || die 'cannot read canonical public Genesis for host upgrade watch'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
grep -qx "genesis_sha256=$GENESIS_SHA256" "$STATE_FILE"   || die 'prepared Host upgrade state belongs to a different Genesis lineage'
bind_run_manifest_genesis "$GENESIS_SHA256"

curl -fsS --connect-timeout 5 --max-time 15   "$CHAIN_BASE/chain-api/cosmos/gov/v1/proposals/$PROPOSAL_ID" >"$RUN/proposal.json"
upgrade_name="v$GONKA_RELEASE"
plan_height="$("$ROOT/scripts/verify-upgrade-proposal-binding.sh"   "$RUN/proposal.json" "$upgrade_name"   "$INFERENCED_UPGRADE_URL" "$INFERENCED_UPGRADE_SHA256"   "$DAPI_UPGRADE_URL" "$DAPI_UPGRADE_SHA256")"   || die "proposal $PROPOSAL_ID is not a passed immutable $upgrade_name upgrade"
grep -qx "plan_height=$plan_height" "$STATE_FILE"   || die 'prepared Host upgrade state has a different activation height'

write_state() {
  local state="$1"
  sed -i -E "s/^state=.*/state=$state/" "$STATE_FILE"
  printf 'observed_at=%s\n' "$(date -u +%FT%TZ)" >>"$STATE_FILE"
}

NODE_URL="$(node_url "$NODE")"
IDENTITY="$(node_identity_file "$NODE")"
[[ -s "$IDENTITY" ]] || die "$NODE has no local public consensus identity"
VALIDATOR_KEY="$(jq -er .consensus_pubkey "$IDENTITY")"
deadline=$((SECONDS + ${GDC_HOST_UPGRADE_WATCH_TIMEOUT_SECONDS:-21600}))
state=PREPARED
while (( SECONDS < deadline )); do
  chain_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" 2>/dev/null || true)"
  current_height="$(jq -r '.result.sync_info.latest_block_height // 0 | tonumber' <<<"$chain_status" 2>/dev/null || true)"
  if [[ ! "$current_height" =~ ^[0-9]+$ ]] || (( current_height < plan_height )); then
    state=WAITING_HEIGHT
    write_state "$state"
    printf 'WAIT  %s activation height=%s target=%s\n' "$NODE" "$current_height" "$plan_height"
    sleep 5
    continue
  fi

  state=ACTIVATED
  write_state "$state"
  versions="$(curl -fsS --connect-timeout 5 --max-time 15 "$NODE_URL/v1/versions" 2>/dev/null || true)"
  if ! jq -e --arg commit "$GONKA_COMMIT" '
    (.node_version.version | ltrimstr("v")) == "0.2.15" and .node_version.commit == $commit
  ' <<<"$versions" >/dev/null 2>&1; then
    printf 'WAIT  %s target runtime is not yet public after activation height\n' "$NODE"
    sleep 5
    continue
  fi

  node_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$NODE_URL/chain-rpc/status" 2>/dev/null || true)"
  node_height="$(jq -r '.result.sync_info.latest_block_height // 0 | tonumber' <<<"$node_status" 2>/dev/null || true)"
  catching_up="$(jq -r '.result.sync_info.catching_up // true' <<<"$node_status" 2>/dev/null || true)"
  lag=$((current_height - node_height)); (( lag >= 0 )) || lag=0
  if [[ "$catching_up" != false ]] || (( lag > ${GDC_MAX_NODE_LAG_BLOCKS:-5} )); then
    printf 'WAIT  %s synchronization height=%s chain=%s lag=%s catching_up=%s\n' "$NODE" "$node_height" "$current_height" "$lag" "$catching_up"
    sleep 5
    continue
  fi
  state=SYNCED
  write_state "$state"

  curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/validators?per_page=100" >"$RUN/validators.json"
  if jq -e --arg key "$VALIDATOR_KEY" '
    .result.validators | any(.[]; .pub_key.value == $key and (.voting_power | tonumber) > 0)
  ' "$RUN/validators.json" >/dev/null; then
    state=VALIDATOR_EFFECTIVE
    write_state "$state"
    jq -n --arg state "$state" --arg node "$NODE" --arg proposal_id "$PROPOSAL_ID"       --argjson plan_height "$plan_height" --arg genesis_sha256 "$GENESIS_SHA256"       --arg validator_key "$VALIDATOR_KEY"       '{schema_version:1,state:$state,node:$node,proposal_id:$proposal_id,plan_height:$plan_height,genesis_sha256:$genesis_sha256,validator_key:$validator_key}'       >"$RUN/receipt.json"
    cat >"$RUN/verdict.md" <<EOF
# Host upgrade watch: PASS

$NODE reached target runtime, synchronized after activation height $plan_height,
and restored positive consensus voting power using only its own Host state.
EOF
    printf 'PASS Host upgrade watch evidence: %s\n' "$RUN"
    exit 0
  fi
  printf 'WAIT  %s is synchronized but not yet an effective validator\n' "$NODE"
  sleep 5
done

write_state FAILED
cat >"$RUN/verdict.md" <<EOF
# Host upgrade watch: INCONCLUSIVE

$NODE did not reach VALIDATOR_EFFECTIVE before the bounded watch deadline.
Retry the same host upgrade watch command; no other Host was modified.
EOF
exit 2
