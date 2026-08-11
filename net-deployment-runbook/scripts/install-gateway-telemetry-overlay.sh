#!/usr/bin/env bash
set -Eeuo pipefail

# This is an explicit compatibility overlay for the pinned official DevShard
# releases. They expose request and latency metrics but not cumulative exact
# response-token counters. The overlay consumes only already-retained,
# successful authenticated completion usage and never attempts to infer token
# counts from logs or fabricate zero-valued samples.
[[ $# -eq 7 ]] || {
  echo 'usage: install-gateway-telemetry-overlay.sh GENESIS_SHA256 REQUEST_SHA256 MODEL INPUT_TOKENS OUTPUT_TOKENS LATENCY_MS OBSERVED_AT' >&2
  exit 2
}
genesis_sha256="$1"
request_sha256="$2"
model="$3"
input_tokens="$4"
output_tokens="$5"
latency_ms="$6"
observed_at="$7"
[[ "$genesis_sha256" =~ ^[0-9a-f]{64}$ && "$request_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 2
[[ "$model" =~ ^[A-Za-z0-9._/-]+$ ]] || exit 2
[[ "$input_tokens" =~ ^[1-9][0-9]*$ && "$output_tokens" =~ ^[1-9][0-9]*$ && "$latency_ms" =~ ^[0-9][0-9]*$ ]] || exit 2
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || exit 2

state_dir="${GDC_GATEWAY_TELEMETRY_STATE_DIR:-/var/lib/gdc-gateway-telemetry}"
state_file="$state_dir/observations.json"
textfile_dir="${GDC_GATEWAY_TELEMETRY_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
textfile_owner="${GDC_GATEWAY_TELEMETRY_TEXTFILE_OWNER:-root}"
textfile_group="${GDC_GATEWAY_TELEMETRY_TEXTFILE_GROUP:-root}"
lock_file="$state_dir/lock"
[[ "$state_dir" == /* && "$textfile_dir" == /* ]] || exit 2
[[ "$textfile_owner" =~ ^[A-Za-z0-9_.-]+$ && "$textfile_group" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 2
install -d -m 0755 "$state_dir" "$textfile_dir"
exec 9>"$lock_file"
flock -x 9

state_tmp="$(mktemp "$state_dir/observations.XXXXXX")"
metrics_tmp="$(mktemp "$textfile_dir/gateway-telemetry.XXXXXX")"
cleanup() { rm -f "$state_tmp" "$metrics_tmp"; }
trap cleanup EXIT

if [[ -s "$state_file" ]]; then
  jq -e 'type == "array"' "$state_file" >/dev/null
else
  printf '[]\n' >"$state_file"
fi
jq --arg genesis_sha256 "$genesis_sha256" --arg request_sha256 "$request_sha256" \
  --arg model "$model" --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens" \
  --argjson latency_ms "$latency_ms" --arg observed_at "$observed_at" '
  if any(.[]; .request_sha256 == $request_sha256) then .
  else . + [{schema_version:1,overlay:"gdc-gateway-usage-textfile-v1",
             genesis_sha256:$genesis_sha256,request_sha256:$request_sha256,
             model:$model,input_tokens:$input_tokens,output_tokens:$output_tokens,
             latency_ms:$latency_ms,observed_at:$observed_at}]
  end
' "$state_file" >"$state_tmp"
mv "$state_tmp" "$state_file"

input_total="$(jq '[.[] | select(.genesis_sha256 == $genesis) | .input_tokens] | add // 0' --arg genesis "$genesis_sha256" "$state_file")"
output_total="$(jq '[.[] | select(.genesis_sha256 == $genesis) | .output_tokens] | add // 0' --arg genesis "$genesis_sha256" "$state_file")"
request_total="$(jq '[.[] | select(.genesis_sha256 == $genesis)] | length' --arg genesis "$genesis_sha256" "$state_file")"
latency_total="$(jq '[.[] | select(.genesis_sha256 == $genesis) | .latency_ms] | add // 0' --arg genesis "$genesis_sha256" "$state_file")"

cat >"$metrics_tmp" <<EOF
# HELP gdc_gateway_observed_requests_total Successful authenticated completions observed from retained gateway evidence
# TYPE gdc_gateway_observed_requests_total counter
gdc_gateway_observed_requests_total{genesis_sha256="$genesis_sha256",model="$model",overlay="gdc-gateway-usage-textfile-v1"} $request_total
# HELP gdc_gateway_observed_input_tokens_total Exact prompt tokens from successful gateway responses
# TYPE gdc_gateway_observed_input_tokens_total counter
gdc_gateway_observed_input_tokens_total{genesis_sha256="$genesis_sha256",model="$model",overlay="gdc-gateway-usage-textfile-v1"} $input_total
# HELP gdc_gateway_observed_output_tokens_total Exact completion tokens from successful gateway responses
# TYPE gdc_gateway_observed_output_tokens_total counter
gdc_gateway_observed_output_tokens_total{genesis_sha256="$genesis_sha256",model="$model",overlay="gdc-gateway-usage-textfile-v1"} $output_total
# HELP gdc_gateway_observed_latency_milliseconds_sum Sum of observed completion latency in milliseconds
# TYPE gdc_gateway_observed_latency_milliseconds_sum counter
gdc_gateway_observed_latency_milliseconds_sum{genesis_sha256="$genesis_sha256",model="$model",overlay="gdc-gateway-usage-textfile-v1"} $latency_total
# HELP gdc_gateway_observed_latency_milliseconds_count Number of observed completion latency samples
# TYPE gdc_gateway_observed_latency_milliseconds_count counter
gdc_gateway_observed_latency_milliseconds_count{genesis_sha256="$genesis_sha256",model="$model",overlay="gdc-gateway-usage-textfile-v1"} $request_total
EOF
install -o "$textfile_owner" -g "$textfile_group" -m 0644 "$metrics_tmp" "$textfile_dir/gateway-telemetry.prom"
