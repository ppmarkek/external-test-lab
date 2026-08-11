#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/scripts/phase-observability-verify.sh"

[[ -x "$PHASE" ]]
grep -Fq 'GDC_NETWORK_EVIDENCE_DIR' "$PHASE"
grep -Fq 'Public network verification: PASS' "$PHASE"
grep -Fq 'OPS observability verification: BLOCKED' "$PHASE"
grep -Fq 'OPS observability verification: FAIL' "$PHASE"
grep -Fq 'capture_canonical_genesis' "$PHASE"
grep -Fq 'Prometheus has no fresh successful scrape series' "$PHASE"
grep -Fq 'verify-public-grafana.sh' "$PHASE"
grep -Fq 'OPS observability verification: PASS' "$PHASE"
grep -Fq 'effective_validators' "$PHASE"
grep -Fq '.result.validators as $validators' "$PHASE"

echo 'PASS observability verification contract'
