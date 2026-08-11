#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-gateway-telemetry-overlay.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
owner="$(id -un)"
group="$(id -gn)"
genesis=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
request=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
env GDC_GATEWAY_TELEMETRY_STATE_DIR="$tmp/state" GDC_GATEWAY_TELEMETRY_TEXTFILE_DIR="$tmp/textfile" GDC_GATEWAY_TELEMETRY_TEXTFILE_OWNER="$owner" GDC_GATEWAY_TELEMETRY_TEXTFILE_GROUP="$group" \
  "$INSTALLER" "$genesis" "$request" Qwen/Qwen3-0.6B 7 3 42 2026-08-11T00:00:00Z
# The same immutable completion observation must never be counted twice.
env GDC_GATEWAY_TELEMETRY_STATE_DIR="$tmp/state" GDC_GATEWAY_TELEMETRY_TEXTFILE_DIR="$tmp/textfile" GDC_GATEWAY_TELEMETRY_TEXTFILE_OWNER="$owner" GDC_GATEWAY_TELEMETRY_TEXTFILE_GROUP="$group" \
  "$INSTALLER" "$genesis" "$request" Qwen/Qwen3-0.6B 7 3 42 2026-08-11T00:00:00Z

jq -e 'length == 1 and .[0].input_tokens == 7 and .[0].output_tokens == 3' "$tmp/state/observations.json" >/dev/null
grep -Fqx "gdc_gateway_observed_requests_total{genesis_sha256=\"$genesis\",model=\"Qwen/Qwen3-0.6B\",overlay=\"gdc-gateway-usage-textfile-v1\"} 1" "$tmp/textfile/gateway-telemetry.prom"
grep -Fqx "gdc_gateway_observed_input_tokens_total{genesis_sha256=\"$genesis\",model=\"Qwen/Qwen3-0.6B\",overlay=\"gdc-gateway-usage-textfile-v1\"} 7" "$tmp/textfile/gateway-telemetry.prom"
grep -Fqx "gdc_gateway_observed_output_tokens_total{genesis_sha256=\"$genesis\",model=\"Qwen/Qwen3-0.6B\",overlay=\"gdc-gateway-usage-textfile-v1\"} 3" "$tmp/textfile/gateway-telemetry.prom"

echo 'PASS gateway telemetry compatibility overlay deduplicates exact response usage'
