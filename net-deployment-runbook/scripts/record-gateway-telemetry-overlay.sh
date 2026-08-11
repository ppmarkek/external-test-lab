#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_project

completion="${1:-}"
[[ $# -eq 1 && -s "$completion" ]] || {
  echo 'usage: record-gateway-telemetry-overlay.sh COMPLETION_JSON' >&2
  exit 2
}
[[ -x "$ROOT/scripts/install-gateway-telemetry-overlay.sh" ]] || die 'gateway telemetry overlay installer is missing'

input_tokens="$(jq -er '.usage.prompt_tokens | tonumber | select(. > 0)' "$completion")" \
  || die 'successful completion evidence has no positive exact prompt-token usage'
output_tokens="$(jq -er '.usage.completion_tokens | tonumber | select(. > 0)' "$completion")" \
  || die 'successful completion evidence has no positive exact completion-token usage'
jq -e '.choices[0].message.content | type == "string" and length > 0' "$completion" >/dev/null \
  || die 'gateway telemetry overlay accepts only a non-empty successful completion'
request_sha256="$(sha256sum "$completion" | awk '{print $1}')"
observed_at="$(date -u +%FT%TZ)"
latency_ms="${GDC_GATEWAY_TELEMETRY_LATENCY_MS:-0}"
[[ "$latency_ms" =~ ^[0-9][0-9]*$ ]] || die 'GDC_GATEWAY_TELEMETRY_LATENCY_MS must be a non-negative integer'

chain_base="${GDC_CHAIN_PUBLIC_BASE:-https://$GENESIS_PUBLIC_HOST}"
chain_base="${chain_base%/}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
capture_canonical_genesis "$chain_base/chain-rpc/genesis" "$tmp/genesis.json" \
  || die 'cannot bind gateway telemetry overlay to canonical public Genesis'
genesis_sha256="$(genesis_sha256 "$tmp/genesis.json")"

evidence_dir="${GDC_GATEWAY_TELEMETRY_EVIDENCE_DIR:-$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}-gateway-telemetry}"
mkdir -p "$evidence_dir"
jq -n --arg genesis_sha256 "$genesis_sha256" --arg request_sha256 "$request_sha256" \
  --arg model "$MODEL_ID" --argjson input_tokens "$input_tokens" --argjson output_tokens "$output_tokens" \
  --argjson latency_ms "$latency_ms" --arg observed_at "$observed_at" \
  '{schema_version:1,overlay:"gdc-gateway-usage-textfile-v1",upstream_metric_gap:"official DevShard exposes no cumulative exact input/output token counters",genesis_sha256:$genesis_sha256,request_sha256:$request_sha256,model:$model,input_tokens:$input_tokens,output_tokens:$output_tokens,latency_ms:$latency_ms,observed_at:$observed_at}' \
  >"$evidence_dir/overlay-observation.json"

remote_args="$(printf ' %q' "$genesis_sha256" "$request_sha256" "$MODEL_ID" "$input_tokens" "$output_tokens" "$latency_ms" "$observed_at")"
ssh -T "$GATEWAY_NODE" "sudo bash -s --$remote_args" <"$ROOT/scripts/install-gateway-telemetry-overlay.sh"
cat >"$evidence_dir/verdict.md" <<EOF
# Gateway telemetry compatibility overlay: PASS

The immutable gdc-gateway-usage-textfile-v1 overlay recorded exact usage
from one successful authenticated completion. It is provenance-tagged by
request SHA-256 and canonical Genesis, and explicitly does not claim to be a
native DevShard token metric.
EOF
printf 'PASS recorded explicit gateway telemetry overlay: %s\n' "$evidence_dir"
