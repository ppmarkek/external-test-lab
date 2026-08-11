#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/scripts/phase-observability-verify.sh"

[[ -x "$PHASE" ]]
grep -Fq 'GDC_NETWORK_EVIDENCE_DIR' "$PHASE"
grep -Fq 'GDC_GATEWAY_COUNTER_DELTA_EVIDENCE' "$PHASE"
grep -Fq 'three current-run authenticated completions' "$PHASE"
grep -Fq 'Public network verification: PASS' "$PHASE"
grep -Fq 'OPS observability verification: BLOCKED' "$PHASE"
grep -Fq 'OPS observability verification: FAIL' "$PHASE"
grep -Fq 'capture_canonical_genesis' "$PHASE"
grep -Fq 'Prometheus has no fresh successful scrape series' "$PHASE"
grep -Fq 'required non-synthetic Prometheus counter is absent or stale' "$PHASE"
grep -Fq 'gdc_gateway_observed_input_tokens_total' "$PHASE"
grep -Fq 'gdc_gateway_observed_output_tokens_total' "$PHASE"
grep -Fq 'gdc-gateway-usage-textfile-v1' "$PHASE"
grep -Fq 'Require a routable gateway with positive current escrow capacity' "$PHASE"
grep -Fq 'gateway has no positive current escrow capacity despite its runtime status' "$PHASE"
grep -Fq 'current_capacity_cap_requests' "$PHASE"
grep -Fq 'gdc_telegram_bot_tokens_total' "$PHASE"
grep -Fq 'verify-public-grafana.sh' "$PHASE"
grep -Fq 'OPS observability verification: PASS' "$PHASE"
grep -Fq 'effective_validators' "$PHASE"
# shellcheck disable=SC2016 # The literal jq filter must include its dollar sign.
grep -Fq '.result.validators as $validators' "$PHASE"
grep -Fq 'observability acceptance requires a five-Host public network PASS' "$PHASE"
grep -Fq 'direct public chain probe reported a non-positive chain height' "$PHASE"
grep -Fq 'Require a fresh target for every Host service and every inference component' "$PHASE"
grep -Fq 'for job in gonka-node host cadvisor' "$PHASE"
grep -Fq 'require_up_for_named_host' "$PHASE"
grep -Fq 'require_component_containers' "$PHASE"
grep -Fq 'node_ml_host' "$PHASE"
grep -Fq 'gdc_nvidia_available' "$PHASE"
grep -Fq '/api/ds/query' "$ROOT/scripts/verify-public-grafana.sh"
grep -Fq 'from:"now-15m"' "$ROOT/scripts/verify-public-grafana.sh"
grep -Fq 'range query returned no data or an error' "$ROOT/scripts/verify-public-grafana.sh"
grep -Fq 'source_expression' "$ROOT/scripts/verify-public-grafana.sh"

echo 'PASS observability verification contract'
