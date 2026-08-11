#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/scripts/phase-public-network-verify.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

address=gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$tmp/bin" "$tmp/external-join"
jq -n '{chain_id:"gonka-devnet-community",app_state:{inference:{params:{poc_params:{confirmation_poc_v2_enabled:true},confirmation_poc_params:{expected_confirmations_per_epoch:"1",slash_fraction:{value:"0",exponent:0},upgrade_protection_window:"20"}}}}}' \
  >"$tmp/genesis.json"
genesis_sha256="$(jq -eS . "$tmp/genesis.json" | sha256sum | awk '{print $1}')"
jq -n --arg genesis_sha256 "$genesis_sha256" --arg address "$address" \
  '{schema_version:1,verdict:"PASS",operator_mode:"external-operator",genesis_sha256:$genesis_sha256,participant_address:$address,validator_key:"fixture-validator-key",runtime_id:("qwen3-0.6b:" + $address),public_host:"node1.example.net"}' \
  >"$tmp/external-join/receipt.json"
printf '# Host join: PASS\n' >"$tmp/external-join/verdict.md"
jq -n --arg genesis_sha256 "$genesis_sha256" --arg address "$address" \
  '{schema_version:1,chain_id:"gonka-devnet-community",genesis_sha256:$genesis_sha256,participants:[{address:$address,validator_key:"fixture-validator-key",public_host:"node1.example.net",runtime_id:("qwen3-0.6b:" + $address),model_id:"Qwen/Qwen3-0.6B"}]}' \
  >"$tmp/expected-topology.json"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  */chain-rpc/genesis) jq -n --slurpfile genesis "$FAKE_GENESIS" '{result:{genesis:$genesis[0]}}' ;;
  *) printf 'unexpected fixture curl URL: %s\n' "$url" >&2; exit 64 ;;
esac
EOF
chmod 755 "$tmp/bin/curl"

set +e
PATH="$tmp/bin:$PATH" FAKE_GENESIS="$tmp/genesis.json" \
  GDC_HOME="$tmp/observer" GDC_CHAIN_PUBLIC_BASE=https://node1.example.net \
  GDC_VERIFY_EXPECTED_ACTIVE_COUNT=1 GDC_EXPECTED_TOPOLOGY_FILE="$tmp/expected-topology.json" \
  GDC_EXTERNAL_JOIN_RECEIPT_DIR="$tmp/external-join" \
  "$PHASE" >"$tmp/output" 2>&1
rc=$?
set -e

[[ "$rc" -eq 3 ]] || {
  cat "$tmp/output" >&2
  echo "expected receipt without bounded PoC evidence to BLOCK, got exit $rc" >&2
  exit 1
}
verdict="$(find "$tmp/observer/runs" -name verdict.md -path '*/public-network-verify/verdict.md' -print -quit)"
[[ -s "$verdict" ]]
grep -Fq '# Public network verification: BLOCKED' "$verdict"
grep -Fq 'external Host receipt is not a current-lineage external-operator JOIN_PASS receipt' "$verdict"

echo 'PASS public observer blocks an external receipt without bounded PoC evidence'
