#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/retired-post-upgrade-worker"
mkdir -p "$RUN"

cat >"$RUN/verdict.md" <<'EOF'
# Centralized post-upgrade worker: BLOCKED

This legacy scheduler is retired with the centralized post-upgrade
orchestrator. It cannot invoke lifecycle or economic actions automatically.
EOF
printf 'BLOCKED centralized post-upgrade worker is retired; evidence: %s\n' "$RUN" >&2
exit 3
