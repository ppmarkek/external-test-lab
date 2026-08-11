#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/retired-post-upgrade-advance"
mkdir -p "$RUN"

cat >"$RUN/verdict.md" <<'EOF'
# Centralized post-upgrade advance: BLOCKED

This legacy orchestrator is retired. It must not automatically submit or vote
on governance proposals, deploy gateways, settle economic state, or run HA
actions after an upgrade. Those actions require their own scoped runbooks and
fresh independently reviewed public evidence.
EOF
printf 'BLOCKED centralized post-upgrade advance is retired; evidence: %s\n' "$RUN" >&2
exit 3
