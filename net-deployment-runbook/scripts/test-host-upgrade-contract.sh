#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREPARE="$ROOT/scripts/phase-host-upgrade-prepare.sh"
WATCH="$ROOT/scripts/phase-host-upgrade-watch.sh"

[[ -x "$PREPARE" && -x "$WATCH" ]]
for phase in "$PREPARE" "$WATCH"; do
  grep -Fq 'host upgrade' "$phase"
  grep -Fq 'verify-upgrade-proposal-binding.sh' "$phase"
  grep -Fq 'capture_canonical_genesis' "$phase"
  grep -Fq 'bind_run_manifest_genesis' "$phase"
  ! grep -Fq 'for node in' "$phase"
done
grep -Fq 'gdc-upgrade-cache' "$PREPARE"
grep -Fq 'sha256sum -c -' "$PREPARE"
grep -Fq 'state=PREPARED' "$PREPARE"
grep -Fq 'WAITING_HEIGHT' "$WATCH"
grep -Fq 'ACTIVATED' "$WATCH"
grep -Fq 'SYNCED' "$WATCH"
grep -Fq 'VALIDATOR_EFFECTIVE' "$WATCH"
grep -Fq 'Host upgrade watch: PASS' "$WATCH"
grep -Fq 'Host upgrade watch: INCONCLUSIVE' "$WATCH"
! grep -Fq 'gdc-upgrade-proposal-' "$ROOT/scripts/phase-audit-lifecycle.sh"
grep -Fq 'no central worker is permitted' "$ROOT/scripts/phase-audit-lifecycle.sh"

echo 'PASS host-scoped upgrade contract'
