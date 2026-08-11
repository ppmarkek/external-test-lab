#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/observability-verify"
mkdir -p "$RUN"
install_evidence_exit_trap 'OPS observability verification'
record_phase_profile observability-verify

blocked() {
  cat >"$RUN/verdict.md" <<EOF
# OPS observability verification: BLOCKED

$1
EOF
  printf 'BLOCKED %s; evidence: %s\n' "$1" "$RUN" >&2
  exit 3
}

failed() {
  cat >"$RUN/verdict.md" <<EOF
# OPS observability verification: FAIL

$1
EOF
  printf 'FAIL %s; evidence: %s\n' "$1" "$RUN" >&2
  exit 1
}

NETWORK_EVIDENCE="${GDC_NETWORK_EVIDENCE_DIR:-}"
[[ -d "$NETWORK_EVIDENCE" && -s "$NETWORK_EVIDENCE/verdict.md" && -s "$NETWORK_EVIDENCE/receipt.json" ]] \
  || blocked 'GDC_NETWORK_EVIDENCE_DIR must name a current public network PASS bundle'
grep -qx '# Public network verification: PASS' "$NETWORK_EVIDENCE/verdict.md" \
  || blocked 'OPS observability verification is BLOCKED until the supplied public network verification has PASSed'

CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-https://$GENESIS_PUBLIC_HOST}"
CHAIN_BASE="${CHAIN_BASE%/}"
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json"   || die 'cannot capture canonical public Genesis for observability verification'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
jq -e --arg genesis_sha256 "$GENESIS_SHA256" '.verdict == "PASS" and .genesis_sha256 == $genesis_sha256' \
  "$NETWORK_EVIDENCE/receipt.json" >/dev/null \
  || blocked 'network PASS evidence belongs to a different Genesis lineage'

step 'Capture direct public chain topology for comparison'
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" >"$RUN/chain-status.json"
curl -fsS --connect-timeout 5 --max-time 15   "$CHAIN_BASE/chain-api/productscience/inference/inference/participant" >"$RUN/participants.json"
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/validators?per_page=100" >"$RUN/validators.json"
chain_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/chain-status.json")"
active_count="$(jq '[.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)] | length' "$RUN/participants.json")"
effective_count="$(jq --slurpfile participants "$RUN/participants.json" '
  .result.validators as $validators
  | [$participants[0].participant[]
     | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)
     | .validator_key as $key
     | select($validators | any(.[]; .pub_key.value == $key and (.voting_power | tonumber) > 0))]
  | length
' "$RUN/validators.json")"
(( active_count > 0 && effective_count > 0 )) \
  || failed 'direct public chain probe has no ACTIVE participants or effective validators'
jq -n --argjson height "$chain_height" --argjson active "$active_count" --argjson effective "$effective_count"   '{chain_height:$height,active_participants:$active,effective_validators:$effective}' >"$RUN/direct-topology.json"

step 'Require fresh successful Prometheus scrape series'
ssh -T "$GATEWAY_NODE"   "curl -fsSG --data-urlencode 'query=up' http://127.0.0.1:9099/api/v1/query" >"$RUN/prometheus-up.json"
freshness_seconds="${GDC_PROMETHEUS_FRESHNESS_SECONDS:-90}"
[[ "$freshness_seconds" =~ ^[1-9][0-9]*$ ]] || die 'GDC_PROMETHEUS_FRESHNESS_SECONDS must be a positive integer'
now="$(date +%s)"
jq -e --argjson now "$now" --argjson freshness "$freshness_seconds" '
  .status == "success"
  and ([.data.result[]
       | select((.value[1] | tonumber) == 1)
       | select(($now - (.value[0] | tonumber)) <= $freshness)] | length) > 0
' "$RUN/prometheus-up.json" >/dev/null \
  || failed 'Prometheus has no fresh successful scrape series'

step 'Verify public dashboard queries and browser rendering'
GDC_GRAFANA_EVIDENCE_DIR="$RUN/grafana" "$ROOT/scripts/verify-public-grafana.sh" \
  || failed 'public Grafana query or browser verification did not pass'
[[ -s "$RUN/grafana/finalize.md" ]] \
  || failed 'Grafana verifier did not produce a final evidence artifact'

jq -n --arg genesis_sha256 "$GENESIS_SHA256" --arg network_evidence "$NETWORK_EVIDENCE"   --argjson direct "$(cat "$RUN/direct-topology.json")"   '{schema_version:1,verdict:"PASS",genesis_sha256:$genesis_sha256,network_evidence:$network_evidence,direct_topology:$direct}'   >"$RUN/receipt.json"
cat >"$RUN/verdict.md" <<EOF
# OPS observability verification: PASS

Fresh Prometheus scrape series, public Grafana panels and browser rendering
agree with direct current-Genesis public chain probes: height $chain_height,
ACTIVE participants $active_count, effective validators $effective_count.
EOF
printf 'PASS OPS observability verification: %s\n' "$RUN"
