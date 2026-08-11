#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/scripts/phase-public-upgrade-verify.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/baseline"
jq -n '{chain_id:"gonka-devnet-community",app_state:{inference:{params:{marker:"baseline"}}}}' >"$tmp/baseline/genesis.json"
printf '[]\n' >"$tmp/baseline/participant-observations.json"
jq -n '{chain_id:"gonka-devnet-community",app_state:{inference:{params:{marker:"other-lineage"}}}}' >"$tmp/live-genesis.json"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
[[ "$url" == https://node1.example.net/chain-rpc/genesis ]] || {
  printf 'unexpected fixture curl URL: %s\n' "$url" >&2
  exit 64
}
jq -n --slurpfile genesis "$FAKE_LIVE_GENESIS" '{result:{genesis:$genesis[0]}}'
EOF
chmod 755 "$tmp/bin/curl"

set +e
PATH="$tmp/bin:$PATH" FAKE_LIVE_GENESIS="$tmp/live-genesis.json" \
  GDC_HOME="$tmp/observer" GDC_RELEASE_PROFILE=v2026.08.06 \
  GDC_CHAIN_PUBLIC_BASE=https://node1.example.net \
  GDC_UPGRADE_BASELINE_EVIDENCE_DIR="$tmp/baseline" \
  "$PHASE" 42 >"$tmp/output" 2>&1
rc=$?
set -e

[[ "$rc" -eq 3 ]] || {
  cat "$tmp/output" >&2
  echo "expected different-Genesis baseline fixture to BLOCK, got exit $rc" >&2
  exit 1
}
verdict="$(find "$tmp/observer/runs" -name verdict.md -path '*/public-upgrade-verify-42/verdict.md' -print -quit)"
[[ -s "$verdict" ]]
grep -Fq '# Public upgrade verification: BLOCKED' "$verdict"
grep -Fq 'baseline public evidence belongs to a different Genesis lineage' "$verdict"

echo 'PASS public upgrade verifier rejects evidence from another Genesis lineage'
