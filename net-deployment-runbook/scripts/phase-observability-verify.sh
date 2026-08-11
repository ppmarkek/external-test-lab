#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=lib.sh
# shellcheck disable=SC1091 # Runtime-relative source is resolved by the script itself.
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
(( chain_height > 0 )) \
  || failed 'direct public chain probe reported a non-positive chain height'
active_count="$(jq '[.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)] | length' "$RUN/participants.json")"
effective_count="$(jq --slurpfile participants "$RUN/participants.json" '
  .result.validators as $validators
  | [$participants[0].participant[]
     | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)
     | .validator_key as $key
     | select($validators | any(.[]; .pub_key.value == $key and (.voting_power | tonumber) > 0))]
  | length
' "$RUN/validators.json")"
expected_count="$(jq -r '(.expected_active_count? // 0) | tonumber? // 0' "$NETWORK_EVIDENCE/receipt.json")"
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
(( expected_count == 5 )) \
  || blocked "observability acceptance requires a five-Host public network PASS, got expected count $expected_count"
(( active_count == expected_count && effective_count == expected_count )) \
  || failed "direct public chain probe differs from the required five ACTIVE/effective validators (active=$active_count effective=$effective_count expected=$expected_count)"

COUNTER_DELTA_EVIDENCE="${GDC_GATEWAY_COUNTER_DELTA_EVIDENCE:-}"
[[ -s "$COUNTER_DELTA_EVIDENCE" ]] \
  || blocked 'GDC_GATEWAY_COUNTER_DELTA_EVIDENCE must prove increments from three current-run authenticated completions'
jq -e '
  .schema_version == 1 and .verdict == "PASS"
  and .overlay == "gdc-gateway-usage-textfile-v1"
  and (.deltas.devshard_gateway_requests_total | tonumber) >= 3
  and (.deltas.devshard_gateway_attempts_terminal_total | tonumber) >= 3
  and (.deltas.gdc_gateway_observed_requests_total | tonumber) >= 3
  and (.deltas.gdc_gateway_observed_input_tokens_total | tonumber) > 0
  and (.deltas.gdc_gateway_observed_output_tokens_total | tonumber) > 0
  and (.deltas.gdc_gateway_observed_latency_milliseconds_count | tonumber) >= 3
  and (.deltas.gdc_gateway_observed_latency_milliseconds_sum | tonumber) > 0
' "$COUNTER_DELTA_EVIDENCE" >/dev/null \
  || blocked 'gateway counter-delta evidence is malformed or does not prove three completed authenticated requests'

step 'Require a fresh target for every Host service and every inference component'
# A green Prometheus process says nothing about the individual services. Bind
# every required target to the aliases in the current public topology, then
# require fresh `up == 1` observations for node RPC, host exporter and cAdvisor.
mapfile -t expected_hosts < <(jq -er '.participants[].alias' "$NETWORK_EVIDENCE/expected-topology.json")
(( ${#expected_hosts[@]} == expected_count )) \
  || blocked 'network PASS topology is incomplete for observability target verification'
require_up_for_hosts() {
  local job="$1" query file
  query="up{job=\"$job\"}"
  file="$RUN/prometheus-up-$job.json"
  ssh -T "$GATEWAY_NODE" \
    "curl -fsSG --data-urlencode 'query=$query' http://127.0.0.1:9099/api/v1/query" >"$file"
  for host in "${expected_hosts[@]}"; do
    jq -e --arg host "$host" --argjson now "$now" --argjson freshness "$freshness_seconds" '
      .status == "success"
      and any(.data.result[]?;
        .metric.host == $host
        and (.value[1] | tonumber) == 1
        and (($now - (.value[0] | tonumber)) <= $freshness))
    ' "$file" >/dev/null \
      || failed "Prometheus target job $job for $host is absent, down, or stale"
  done
}
for job in gonka-node host cadvisor; do
  require_up_for_hosts "$job"
done
require_up_for_named_host() {
  local job="$1" host="$2" query file
  query="up{job=\"$job\"}"
  file="$RUN/prometheus-up-$job.json"
  ssh -T "$GATEWAY_NODE" \
    "curl -fsSG --data-urlencode 'query=$query' http://127.0.0.1:9099/api/v1/query" >"$file"
  jq -e --arg host "$host" --argjson now "$now" --argjson freshness "$freshness_seconds" '
    .status == "success"
    and any(.data.result[]?;
      .metric.host == $host
      and (.value[1] | tonumber) == 1
      and (($now - (.value[0] | tonumber)) <= $freshness))
  ' "$file" >/dev/null \
    || failed "Prometheus target job $job for $host is absent, down, or stale"
}
for job_and_host in "gateway:$GATEWAY_NODE" "telegram-consumer:$TELEGRAM_BOT_HOST"; do
  IFS=: read -r job host <<<"$job_and_host"
  require_up_for_named_host "$job" "$host"
done

# DAPI and MLNode do not expose a native Prometheus endpoint in the official
# 0.2.14/0.2.15 stack. Their independently scraped cAdvisor samples remain
# real service evidence only when the expected container is presently seen on
# every validator Host; do not substitute a synthetic zero-valued series.
# The split gdc-node4-ml machine owns gdc-node4's MLNode, so resolve its
# configured ML alias rather than falsely requiring the container locally.
require_component_containers() {
  local service="$1" host component_file
  component_file="$RUN/prometheus-container-$service.json"
  ssh -T "$GATEWAY_NODE" \
    "curl -fsSG --data-urlencode 'query=container_last_seen{container_label_com_docker_compose_service=\"$service\"}' http://127.0.0.1:9099/api/v1/query" >"$component_file"
  for host in "${component_hosts[@]}"; do
    jq -e --arg host "$host" --argjson now "$now" --argjson freshness "$freshness_seconds" '
      .status == "success"
      and any(.data.result[]?;
        .metric.host == $host
        and (.value[1] | tonumber) > 0
        and (($now - (.value[0] | tonumber)) <= $freshness))
    ' "$component_file" >/dev/null \
      || failed "cAdvisor has no fresh $service container sample for $host"
  done
}
component_hosts=("${expected_hosts[@]}")
require_component_containers api
component_hosts=()
for host in "${expected_hosts[@]}"; do
  component_hosts+=("$(node_ml_host "$host" || printf '%s' "$host")")
done
require_component_containers mlnode

gpu_file="$RUN/prometheus-gpu.json"
ssh -T "$GATEWAY_NODE" \
  "curl -fsSG --data-urlencode 'query=gdc_nvidia_available' http://127.0.0.1:9099/api/v1/query" >"$gpu_file"
jq -e --argjson now "$now" --argjson freshness "$freshness_seconds" '
  .status == "success"
  and any(.data.result[]?;
    (.value[1] | tonumber) > 0
    and (($now - (.value[0] | tonumber)) <= $freshness))
' "$gpu_file" >/dev/null \
  || failed 'Prometheus has no fresh available-GPU series for the current topology'

step 'Require non-synthetic gateway and Telegram accounting counter families'
# Dashboard `or vector(0)` fallbacks are presentation only. The lifecycle
# requires real counter families before it can claim request and token deltas.
required_counter_metrics=(
  devshard_gateway_requests_total
  devshard_gateway_attempts_terminal_total
  gdc_gateway_observed_requests_total
  gdc_gateway_observed_input_tokens_total
  gdc_gateway_observed_output_tokens_total
  gdc_gateway_observed_latency_milliseconds_count
  gdc_telegram_bot_inference_requests_total
  gdc_telegram_bot_tokens_total
)
for metric in "${required_counter_metrics[@]}"; do
  metric_file="$RUN/prometheus-$metric.json"
  metric_query="$metric"
  if [[ "$metric" == gdc_gateway_observed_* ]]; then
    metric_query="$metric{genesis_sha256=\"$GENESIS_SHA256\",overlay=\"gdc-gateway-usage-textfile-v1\"}"
  fi
  ssh -T "$GATEWAY_NODE" \
    "curl -fsSG --data-urlencode 'query=$metric_query' http://127.0.0.1:9099/api/v1/query" >"$metric_file"
  jq -e --argjson now "$now" --argjson freshness "$freshness_seconds" '
    .status == "success"
    and ([.data.result[]?
         | select((.value[0] | tonumber) <= $now)
         | select(($now - (.value[0] | tonumber)) <= $freshness)
         | select((.value[1] | tonumber) > 0)] | length) > 0
  ' "$metric_file" >/dev/null \
    || blocked "required non-synthetic Prometheus counter is absent or stale: $metric"
done

step 'Require a routable gateway with positive current escrow capacity'
# `/v1/status` is a runtime description, not an admission proof. Query the
# authenticated local admin endpoint without exporting its credential: the
# current effective limiter values must be positive for the same Gateway that
# serves the public route. A preserved PoC snapshot mismatch can otherwise
# leave an active-looking gateway at scale factor zero and return HTTP 429.
gateway_capacity_file="$RUN/gateway-admin-capacity.json"
ssh -T "$GATEWAY_NODE" 'set -Eeuo pipefail
  set -a; . /srv/dai/ops/gateway.env; set +a
  curl -fsS http://127.0.0.1:18080/v1/admin/devshards \
    -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY"' >"$gateway_capacity_file"
jq -e --arg model "$MODEL_ID" '
  ([.devshards[]? | select(.active == true and (.runtime.phase // .phase) == "active"
      and ((.runtime.requests_blocked // .requests_blocked // false) == false)] | length) > 0)
  and (.limiter.models[$model].effective_max_concurrent_requests | tonumber) > 0
  and (.limiter.models[$model].effective_max_input_tokens_in_flight | tonumber) > 0
  and (.limiter.models[$model].current_capacity_cap_requests | tonumber) > 0
  and (.limiter.models[$model].current_capacity_cap_input_tokens | tonumber) > 0
' "$gateway_capacity_file" >/dev/null \
  || failed 'gateway has no positive current escrow capacity despite its runtime status'

step 'Verify public dashboard queries and browser rendering'
GDC_GRAFANA_EVIDENCE_DIR="$RUN/grafana" "$ROOT/scripts/verify-public-grafana.sh" \
  || failed 'public Grafana query or browser verification did not pass'
[[ -s "$RUN/grafana/finalize.md" ]] \
  || failed 'Grafana verifier did not produce a final evidence artifact'

jq -n --arg genesis_sha256 "$GENESIS_SHA256" --arg network_evidence "$NETWORK_EVIDENCE" --arg counter_delta_evidence "$COUNTER_DELTA_EVIDENCE" \
  --argjson direct "$(cat "$RUN/direct-topology.json")" \
  '{schema_version:1,verdict:"PASS",genesis_sha256:$genesis_sha256,network_evidence:$network_evidence,counter_delta_evidence:$counter_delta_evidence,direct_topology:$direct}' \
  >"$RUN/receipt.json"
cat >"$RUN/verdict.md" <<EOF
# OPS observability verification: PASS

Fresh Prometheus scrape series, public Grafana panels and browser rendering
agree with direct current-Genesis public chain probes: height $chain_height,
ACTIVE participants $active_count, effective validators $effective_count.
EOF
printf 'PASS OPS observability verification: %s\n' "$RUN"
