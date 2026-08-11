#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/scripts/phase-public-network-verify.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

active_address=gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expected_address=gonka1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$tmp/bin" "$tmp/external-join"
jq -n '{chain_id:"gonka-devnet-community",app_state:{inference:{params:{poc_params:{confirmation_poc_v2_enabled:true},confirmation_poc_params:{expected_confirmations_per_epoch:"1",slash_fraction:{value:"0",exponent:0},upgrade_protection_window:"20"}}}}}' \
  >"$tmp/genesis.json"
genesis_sha256="$(jq -eS . "$tmp/genesis.json" | sha256sum | awk '{print $1}')"
jq -n --arg genesis_sha256 "$genesis_sha256" --arg address "$expected_address" \
  '{schema_version:1,verdict:"PASS",operator_mode:"external-operator",genesis_sha256:$genesis_sha256,participant_address:$address,validator_key:"expected-validator-key",runtime_id:("qwen3-0.6b:" + $address),public_host:"expected.example.net",poc_accepted_once:true,poc_accepted_epoch:2,poc_participant_weight:10,poc_accepted_weight_sum:10,poc_committed_total:10}' \
  >"$tmp/external-join/receipt.json"
printf '# Host join: PASS\n' >"$tmp/external-join/verdict.md"
jq -n --arg genesis_sha256 "$genesis_sha256" --arg address "$expected_address" \
  '{schema_version:1,chain_id:"gonka-devnet-community",genesis_sha256:$genesis_sha256,participants:[{address:$address,validator_key:"expected-validator-key",public_host:"expected.example.net",runtime_id:("qwen3-0.6b:" + $address),model_id:"Qwen/Qwen3-0.6B"}]}' \
  >"$tmp/expected-topology.json"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  */chain-rpc/genesis)
    jq -n --slurpfile genesis "$FAKE_GENESIS" '{result:{genesis:$genesis[0]}}'
    ;;
  */chain-api/productscience/inference/inference/participant)
    jq -n --arg address "$FAKE_ACTIVE_ADDRESS" '{participant:[{address:$address,validator_key:"active-validator-key",inference_url:"https://active.example.net",status:1}]}'
    ;;
  */chain-rpc/validators?per_page=100)
    printf '%s\n' '{"result":{"validators":[]}}'
    ;;
  *)
    printf 'unexpected fixture curl URL: %s\n' "$url" >&2
    exit 64
    ;;
esac
EOF
chmod 755 "$tmp/bin/curl"

set +e
PATH="$tmp/bin:$PATH" FAKE_GENESIS="$tmp/genesis.json" FAKE_ACTIVE_ADDRESS="$active_address" \
  GDC_HOME="$tmp/observer" GDC_CHAIN_PUBLIC_BASE=https://active.example.net \
  GDC_VERIFY_EXPECTED_ACTIVE_COUNT=1 GDC_EXPECTED_TOPOLOGY_FILE="$tmp/expected-topology.json" \
  GDC_EXTERNAL_JOIN_RECEIPT_DIR="$tmp/external-join" \
  "$PHASE" >"$tmp/output" 2>&1
rc=$?
set -e

[[ "$rc" -eq 1 ]] || {
  cat "$tmp/output" >&2
  echo "expected wrong-topology fixture to FAIL, got exit $rc" >&2
  exit 1
}
verdict="$(find "$tmp/observer/runs" -name verdict.md -path '*/public-network-verify/verdict.md' -print -quit)"
[[ -s "$verdict" ]]
grep -Fq '# Public network verification: FAIL' "$verdict"
grep -Fq 'do not exactly match the expected current-run topology manifest' "$verdict"

echo 'PASS public observer rejects a same-count topology with different identities'
