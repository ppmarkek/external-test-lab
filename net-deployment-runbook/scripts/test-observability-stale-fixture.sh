#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/scripts/phase-observability-verify.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

address=gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$tmp/bin" "$tmp/network-pass"
cat >"$tmp/operator.env" <<'EOF'
GDC_NODE_ALIASES="node1"
GDC_NODE_PUBLIC_HOSTS="node1=localhost"
GDC_NODE_GPU_PROFILES="node1=t4-16g"
GDC_NODE_P2P_PORTS="node1=5000"
GDC_GENESIS_NODE=node1
GDC_PUBLIC_EDGE_NODE=node1
GDC_GATEWAY_NODE=node1
GDC_TELEGRAM_BOT_HOST=node1
EOF
jq -n '{chain_id:"gonka-devnet-community",app_state:{inference:{params:{marker:"fixture"}}}}' >"$tmp/genesis.json"
genesis_sha256="$(jq -eS . "$tmp/genesis.json" | sha256sum | awk '{print $1}')"
jq -n --arg genesis_sha256 "$genesis_sha256" '{schema_version:1,verdict:"PASS",genesis_sha256:$genesis_sha256}' >"$tmp/network-pass/receipt.json"
printf '# Public network verification: PASS\n' >"$tmp/network-pass/verdict.md"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  */chain-rpc/genesis)
    jq -n --slurpfile genesis "$FAKE_GENESIS" '{result:{genesis:$genesis[0]}}'
    ;;
  */chain-rpc/status)
    jq -n '{result:{sync_info:{latest_block_height:"101"}}}'
    ;;
  */chain-api/productscience/inference/inference/participant)
    jq -n --arg address "$FAKE_ADDRESS" '{participant:[{address:$address,validator_key:"fixture-validator-key",inference_url:"https://node1.example.net",status:"ACTIVE"}]}'
    ;;
  */chain-rpc/validators?per_page=100)
    jq -n '{result:{validators:[{pub_key:{value:"fixture-validator-key"},voting_power:"1"}]}}'
    ;;
  *)
    printf 'unexpected fixture curl URL: %s\n' "$url" >&2
    exit 64
    ;;
esac
EOF
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# Every scrape is intentionally older than the configured freshness window.
jq -n '{status:"success",data:{result:[{value:[1,"1"]}]}}'
EOF
chmod 755 "$tmp/bin/curl" "$tmp/bin/ssh"

set +e
PATH="$tmp/bin:$PATH" FAKE_ADDRESS="$address" FAKE_GENESIS="$tmp/genesis.json" \
  GDC_HOME="$tmp/observer" GDC_ENV="$tmp/operator.env" \
  GDC_CHAIN_PUBLIC_BASE=https://node1.example.net \
  GDC_NETWORK_EVIDENCE_DIR="$tmp/network-pass" GDC_PROMETHEUS_FRESHNESS_SECONDS=1 \
  "$PHASE" >"$tmp/output" 2>&1
rc=$?
set -e

[[ "$rc" -eq 1 ]] || {
  cat "$tmp/output" >&2
  echo "expected stale-Prometheus fixture to FAIL, got exit $rc" >&2
  exit 1
}
verdict="$(find "$tmp/observer/runs" -name verdict.md -path '*/observability-verify/verdict.md' -print -quit)"
[[ -s "$verdict" ]]
grep -Fq '# OPS observability verification: FAIL' "$verdict"
grep -Fq 'Prometheus has no fresh successful scrape series' "$verdict"

echo 'PASS observability verifier rejects stale Prometheus samples'
