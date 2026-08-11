#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/scripts/phase-public-upgrade-verify.sh"

[[ -x "$PHASE" ]]
grep -Fq 'GDC_UPGRADE_BASELINE_EVIDENCE_DIR' "$PHASE"
grep -Fq 'PUBLIC_VERIFY_RUN_ID' "$PHASE"
grep -Fq 'baseline public evidence belongs to a different Genesis lineage' "$PHASE"
! grep -Fq "find \"\$GDC_HOME/runs\" -path '*/public-network-verify/verdict.md'" "$PHASE"
grep -Fq 'capture_canonical_genesis' "$PHASE"
grep -Fq 'verify-upgrade-proposal-binding.sh' "$PHASE"
grep -Fq 'participant-identity.diff' "$PHASE"
grep -Fq 'phase-public-network-verify.sh' "$PHASE"
grep -Fq 'Public upgrade verification: PASS' "$PHASE"
grep -Fq 'Public upgrade verification: INCOMPLETE' "$PHASE"
! grep -Fq 'node_account_file' "$PHASE"
! grep -Fq 'ssh "$GENESIS_NODE"' "$PHASE"

echo 'PASS public upgrade verification contract'
