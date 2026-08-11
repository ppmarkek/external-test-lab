#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/scripts/phase-bridge-deploy-sepolia.sh"

grep -Fq 'GDC_POST_UPGRADE_EVIDENCE_DIR' "$DEPLOY"
grep -Fq 'Public upgrade verification: PASS' "$DEPLOY"
grep -Fq 'post-upgrade public evidence belongs to another Genesis lineage' "$DEPLOY"
grep -Fq 'private keys are never read from .env or argv' "$DEPLOY"
! grep -Fq 'GDC_SEPOLIA_PRIVATE_KEY:-' "$DEPLOY"
grep -Fq 'must have mode 0600' "$DEPLOY"
! grep -Fq 'mode 0600 or 0400' "$DEPLOY"
grep -Fq 'bridge_deploy_exit' "$DEPLOY"
grep -Fq 'Sepolia bridge deployment: BLOCKED' "$DEPLOY"
grep -Fq 'GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)' "$DEPLOY"
grep -Fq 'GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)' "$ROOT/scripts/phase-bridge-register-sepolia.sh"
grep -Fq 'GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)' "$ROOT/scripts/phase-bridge-observer.sh"
! grep -Fq 'GDC_SEPOLIA_PRIVATE_KEY=' "$ROOT/.env.example"

echo 'PASS bridge deployment safety contract'
