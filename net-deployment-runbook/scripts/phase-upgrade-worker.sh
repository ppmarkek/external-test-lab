#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/retired-upgrade-worker"
mkdir -p "$RUN"

cat >"$RUN/verdict.md" <<'EOF'
# Centralized upgrade worker: BLOCKED

This legacy worker is retired. A network-owner process must not SSH into or
upgrade a fleet centrally. Each independent Host operator must run the
canonical `host upgrade prepare` and `host upgrade watch` commands for the
passed proposal, followed by the public `network upgrade verify` gate.
EOF
printf 'BLOCKED centralized upgrade worker is retired; evidence: %s\n' "$RUN" >&2
exit 3
