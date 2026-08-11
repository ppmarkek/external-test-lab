#!/usr/bin/env bash
set -Eeuo pipefail

# Public post-upgrade verification requires pre-upgrade public evidence from
# the same Genesis; it never reaches into another operator's state home.
source "$(dirname "$0")/lib.sh"

PROPOSAL_ID="${1:-}"
[[ "$PROPOSAL_ID" =~ ^[1-9][0-9]*$ ]] || die 'usage: network upgrade verify <passed-proposal-id>'
[[ "${GDC_RELEASE_PROFILE:-}" == v2026.08.06 ]] || die 'network upgrade verify requires --release v2026.08.06'
CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-}"
[[ "$CHAIN_BASE" =~ ^https://[A-Za-z0-9.-]+$ ]]   || die 'GDC_CHAIN_PUBLIC_BASE must be the HTTPS public chain endpoint'
CHAIN_BASE="${CHAIN_BASE%/}"
BASELINE_DIR="${GDC_UPGRADE_BASELINE_EVIDENCE_DIR:-}"

PROFILE_FILE="$(dirname "$0")/../profiles/releases/v2026.08.06.lock"
profile_value() { awk -F= -v key="$1" '$1 == key {print $2; exit}' "$PROFILE_FILE"; }
GONKA_RELEASE="$(profile_value GONKA_RELEASE)"
GONKA_COMMIT="$(profile_value GONKA_COMMIT)"
INFERENCED_UPGRADE_URL="$(profile_value INFERENCED_UPGRADE_URL)"
INFERENCED_UPGRADE_SHA256="$(profile_value INFERENCED_UPGRADE_SHA256)"
DAPI_UPGRADE_URL="$(profile_value DAPI_UPGRADE_URL)"
DAPI_UPGRADE_SHA256="$(profile_value DAPI_UPGRADE_SHA256)"
[[ "$GONKA_RELEASE" == 0.2.15 && "$GONKA_COMMIT" =~ ^[0-9a-f]{40}$ ]]   || die 'v2026.08.06 release lock is incomplete'

RUN_ID="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}"
PUBLIC_VERIFY_RUN_ID="${RUN_ID}-post-upgrade-network"
RUN="$GDC_HOME/runs/$RUN_ID/public-upgrade-verify-$PROPOSAL_ID"
mkdir -p "$RUN"
install_evidence_exit_trap 'Public upgrade verification'

blocked() {
  cat >"$RUN/verdict.md" <<EOF
# Public upgrade verification: BLOCKED

$1
EOF
  printf 'BLOCKED %s; evidence: %s\n' "$1" "$RUN" >&2
  exit 3
}

[[ -d "$BASELINE_DIR" && -s "$BASELINE_DIR/genesis.json" && -s "$BASELINE_DIR/participant-observations.json" ]] \
  || blocked 'GDC_UPGRADE_BASELINE_EVIDENCE_DIR must name a pre-upgrade public-network-verify bundle with genesis.json and participant-observations.json'
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json"   || die 'cannot read canonical post-upgrade Genesis'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
[[ "$(genesis_sha256 "$BASELINE_DIR/genesis.json")" == "$GENESIS_SHA256" ]] \
  || blocked 'baseline public evidence belongs to a different Genesis lineage'

step "Verify passed immutable software-upgrade proposal $PROPOSAL_ID"
curl -fsS --connect-timeout 5 --max-time 15   "$CHAIN_BASE/chain-api/cosmos/gov/v1/proposals/$PROPOSAL_ID" >"$RUN/proposal.json"
plan_height="$("$ROOT/scripts/verify-upgrade-proposal-binding.sh"   "$RUN/proposal.json" "v$GONKA_RELEASE"   "$INFERENCED_UPGRADE_URL" "$INFERENCED_UPGRADE_SHA256"   "$DAPI_UPGRADE_URL" "$DAPI_UPGRADE_SHA256")"   || die "proposal $PROPOSAL_ID is not the passed immutable v$GONKA_RELEASE target"

step 'Compare public participant identity set with pre-upgrade evidence'
curl -fsS --connect-timeout 5 --max-time 15   "$CHAIN_BASE/chain-api/productscience/inference/inference/participant" >"$RUN/participants-chain.json"
jq '[.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)
  | {address,validator_key,inference_url}] | sort_by(.address)' "$RUN/participants-chain.json" >"$RUN/active-participants.json"
jq '[.[] | {address,validator_key,inference_url}] | sort_by(.address)'   "$BASELINE_DIR/participant-observations.json" >"$RUN/baseline-participants.json"
diff -u "$RUN/baseline-participants.json" "$RUN/active-participants.json" >"$RUN/participant-identity.diff"   || die 'ACTIVE participant address, validator-key, or public endpoint set changed across upgrade'

step 'Verify every public participant reports the pinned target runtime'
while IFS= read -r participant; do
  endpoint="$(jq -er .inference_url <<<"$participant")"
  address="$(jq -er .address <<<"$participant")"
  curl -fsS --connect-timeout 5 --max-time 15 "$endpoint/v1/versions" >"$RUN/version-$address.json"
  jq -e --arg commit "$GONKA_COMMIT" '
    (.node_version.version | ltrimstr("v")) == "0.2.15"
    and .node_version.commit == $commit
  ' "$RUN/version-$address.json" >/dev/null     || die "$address does not report the pinned 0.2.15 runtime"
done < <(jq -c '.[]' "$RUN/active-participants.json")

step 'Require the complete public topology, PoC, and confirmation-PoC gate after upgrade'
set +e
GDC_RUN_ID="$PUBLIC_VERIFY_RUN_ID" GDC_RELEASE_PROFILE=v2026.08.06 \
  "$ROOT/scripts/phase-public-network-verify.sh"
public_rc=$?
set -e
public_bundle="$GDC_HOME/runs/$PUBLIC_VERIFY_RUN_ID/public-network-verify"
[[ -n "$public_bundle" && -s "$public_bundle/verdict.md" ]]   || die 'post-upgrade public network verifier produced no verdict bundle'
cp "$public_bundle/verdict.md" "$RUN/public-network-verdict.md"
[[ "$public_rc" -eq 0 ]] || {
  cat >"$RUN/verdict.md" <<EOF
# Public upgrade verification: INCOMPLETE

The immutable target runtime and identity preservation checks passed, but the
post-upgrade public network gate did not pass. See public-network-verdict.md.
EOF
  exit "$public_rc"
}

jq -n --arg proposal_id "$PROPOSAL_ID" --argjson plan_height "$plan_height"   --arg genesis_sha256 "$GENESIS_SHA256" --arg baseline "$BASELINE_DIR"   --arg public_bundle "$public_bundle"   '{schema_version:1,verdict:"PASS",proposal_id:$proposal_id,plan_height:$plan_height,genesis_sha256:$genesis_sha256,baseline_evidence:$baseline,post_upgrade_public_evidence:$public_bundle}'   >"$RUN/receipt.json"
cat >"$RUN/verdict.md" <<EOF
# Public upgrade verification: PASS

Proposal $PROPOSAL_ID activated the pinned v$GONKA_RELEASE runtime while
preserving the canonical Genesis and public participant identity set. The
complete post-upgrade public topology, PoC and confirmation-PoC gate passed.
EOF
printf 'PASS public upgrade verification: %s\n' "$RUN"
