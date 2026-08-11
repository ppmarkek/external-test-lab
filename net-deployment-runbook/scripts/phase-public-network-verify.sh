#!/usr/bin/env bash
set -Eeuo pipefail

# A network observer owns no validator account files, SSH aliases, mnemonics,
# or Genesis loopback access. This phase consumes only public RPC/REST data
# and participant-advertised public endpoints.
source "$(dirname "$0")/lib.sh"

CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-}"
[[ "$CHAIN_BASE" =~ ^https://[A-Za-z0-9.-]+$ ]]   || die 'GDC_CHAIN_PUBLIC_BASE must be an HTTPS public participant endpoint, for example https://node0.gonka-dev.net'
CHAIN_BASE="${CHAIN_BASE%/}"
EXPECTED_CHAIN_ID="${GDC_VERIFY_CHAIN_ID:-gonka-devnet-community}"
MODEL_ID="${GDC_VERIFY_MODEL_ID:-Qwen/Qwen3-0.6B}"
LAG_THRESHOLD="${GDC_MAX_NODE_LAG_BLOCKS:-5}"
PROGRESS_TIMEOUT="${GDC_PUBLIC_VERIFY_PROGRESS_TIMEOUT_SECONDS:-120}"
EXPECTED_ACTIVE_COUNT="${GDC_VERIFY_EXPECTED_ACTIVE_COUNT:-5}"
EXPECTED_TOPOLOGY_FILE="${GDC_EXPECTED_TOPOLOGY_FILE:-}"
EXTERNAL_JOIN_RECEIPT_DIR="${GDC_EXTERNAL_JOIN_RECEIPT_DIR:-}"
GATE_A_EVIDENCE_DIR="${GDC_GATE_A_EVIDENCE_DIR:-}"
RELEASE_PROFILE="${GDC_RELEASE_PROFILE:-v2026.07.23}"
PROFILE_FILE="$(dirname "$0")/../profiles/releases/$RELEASE_PROFILE.lock"
profile_value() { awk -F= -v key="$1" '$1 == key {print $2; exit}' "$PROFILE_FILE"; }
[[ -s "$PROFILE_FILE" ]] || die "no release profile lock exists for $RELEASE_PROFILE"
CPOC_EPOCHS="${GDC_CPOC_PROBE_EPOCHS:-$(profile_value GDC_CPOC_PROBE_EPOCHS)}"
CPOC_TIMEOUT="${GDC_CPOC_PROBE_TIMEOUT_SECONDS:-$(profile_value GDC_CPOC_PROBE_TIMEOUT_SECONDS)}"
CPOC_POLL_SECONDS="${GDC_CPOC_PROBE_POLL_SECONDS:-$(profile_value GDC_CPOC_PROBE_POLL_SECONDS)}"
[[ "$LAG_THRESHOLD" =~ ^[0-9]+$ && "$PROGRESS_TIMEOUT" =~ ^[1-9][0-9]*$ \
  && "$EXPECTED_ACTIVE_COUNT" =~ ^[1-9][0-9]*$ && "$CPOC_EPOCHS" =~ ^[1-9][0-9]*$ \
  && "$CPOC_TIMEOUT" =~ ^[1-9][0-9]*$ && "$CPOC_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || die 'public verification thresholds must be positive integers'

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/public-network-verify"
mkdir -p "$RUN"
GENESIS_SHA256=UNAVAILABLE
VERDICT_WRITTEN=false
ACTIVE_PARTICIPANT_COUNT=0
EFFECTIVE_VALIDATOR_COUNT=0

write_verdict() {
  local verdict="$1" reason="$2"
  cat >"$RUN/verdict.md" <<EOF
# Public network verification: $verdict

$reason

Evidence is limited to public endpoints and contains no operator credentials.
EOF
  jq -n --arg verdict "$verdict" --arg reason "$reason" \
    --arg chain_base "$CHAIN_BASE" --arg expected_chain_id "$EXPECTED_CHAIN_ID" \
    --arg genesis_sha256 "$GENESIS_SHA256" --arg model_id "$MODEL_ID" \
    --arg release_profile "$RELEASE_PROFILE" --argjson expected_active_count "$EXPECTED_ACTIVE_COUNT" \
    --argjson active_participant_count "$ACTIVE_PARTICIPANT_COUNT" \
    --argjson effective_validator_count "$EFFECTIVE_VALIDATOR_COUNT" \
    --arg external_join_receipt "$EXTERNAL_JOIN_RECEIPT_DIR" --arg gate_a_evidence "$GATE_A_EVIDENCE_DIR" \
    --arg expected_topology_file "$EXPECTED_TOPOLOGY_FILE" \
    --argjson cpoc_probe_epochs "$CPOC_EPOCHS" \
    '{schema_version:1,verdict:$verdict,reason:$reason,chain_base:$chain_base,expected_chain_id:$expected_chain_id,genesis_sha256:$genesis_sha256,model_id:$model_id,release_profile:$release_profile,expected_active_count:$expected_active_count,active_participant_count:$active_participant_count,effective_validator_count:$effective_validator_count,external_join_receipt:$external_join_receipt,gate_a_evidence:$gate_a_evidence,expected_topology_file:$expected_topology_file,cpoc_probe_epochs:$cpoc_probe_epochs}' \
    >"$RUN/receipt.json"
  VERDICT_WRITTEN=true
}

on_exit() {
  local rc=$?
  if (( rc != 0 )) && [[ "$VERDICT_WRITTEN" == false ]]; then
    write_verdict INCONCLUSIVE "public observer stopped with exit code $rc before a final verdict"
  fi
}
trap on_exit EXIT

blocked() {
  write_verdict BLOCKED "$1"
  printf 'BLOCKED %s; evidence: %s\n' "$1" "$RUN" >&2
  exit 3
}

failed() {
  write_verdict FAIL "$1"
  printf 'FAIL %s; evidence: %s\n' "$1" "$RUN" >&2
  exit 1
}

inconclusive() {
  write_verdict INCONCLUSIVE "$1"
  printf 'INCONCLUSIVE %s; evidence: %s\n' "$1" "$RUN" >&2
  exit 2
}

record_poc_snapshot() {
  local snapshot="$1" epoch="$2" address weight_evidence model_present
  model_present=false
  jq -e --arg model "$MODEL_ID" '.epoch_group_data.sub_group_models | index($model) != null' "$snapshot" >/dev/null \
    && model_present=true
  printf '[]' >"$RUN/poc-snapshot-weights.json"
  while IFS= read -r address; do
    weight_evidence="$RUN/poc-weight-$epoch-$address.json"
    "$ROOT/scripts/check-validation-weight-evidence.sh" "$snapshot" "$address" >"$weight_evidence" \
      || inconclusive "current PoC weight evidence for $address is malformed"
    jq --arg address "$address" --slurpfile weight "$weight_evidence" \
      '. + [$weight[0] + {participant_address:$address}]' "$RUN/poc-snapshot-weights.json" \
      >"$RUN/poc-snapshot-weights.tmp"
    mv "$RUN/poc-snapshot-weights.tmp" "$RUN/poc-snapshot-weights.json"
  done < <(jq -r '.[].address' "$RUN/active-participants.json")
  jq -e 'all(.[]; .distribution_integrity == true)' "$RUN/poc-snapshot-weights.json" >/dev/null \
    || failed 'current PoC weight distribution differs from the committed total'
  jq --argjson epoch "$epoch" --argjson model_present "$model_present" \
    --slurpfile group "$snapshot" --slurpfile weights "$RUN/poc-snapshot-weights.json" \
    '. + [{epoch:$epoch,model_present:$model_present,epoch_group:$group[0],weights:$weights[0]}]' \
    "$RUN/poc-observations.json" >"$RUN/poc-observations.tmp"
  mv "$RUN/poc-observations.tmp" "$RUN/poc-observations.json"
}

poc_coverage_complete() {
  local address
  while IFS= read -r address; do
    jq -e --arg address "$address" '
      any(.[]; .model_present == true and any(.weights[]?;
        .participant_address == $address and .participant_eligible == true))
    ' "$RUN/poc-observations.json" >/dev/null || return 1
  done < <(jq -r '.[].address' "$RUN/active-participants.json")
}

step 'Bind public observer evidence to canonical Genesis lineage'
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" \
  || inconclusive 'cannot read canonical public Genesis'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
jq -e --arg chain_id "$EXPECTED_CHAIN_ID" '.chain_id == $chain_id' "$RUN/genesis.json" >/dev/null   || failed "canonical Genesis chain ID differs from $EXPECTED_CHAIN_ID"
jq -e '
  .app_state.inference.params as $params
  | $params.poc_params.confirmation_poc_v2_enabled == true
  and $params.confirmation_poc_params.expected_confirmations_per_epoch == "1"
  and $params.confirmation_poc_params.slash_fraction == {"value":"0","exponent":0}
  and $params.confirmation_poc_params.upgrade_protection_window == "20"
' "$RUN/genesis.json" >/dev/null   || blocked 'canonical Genesis does not expose the required bounded confirmation-PoC profile'

step 'Bind the expected current-run topology to the canonical Genesis'
[[ -s "$EXPECTED_TOPOLOGY_FILE" ]] \
  || blocked 'GDC_EXPECTED_TOPOLOGY_FILE must name the sanitized current-run topology manifest'
jq -e --arg genesis_sha256 "$GENESIS_SHA256" --arg chain_id "$EXPECTED_CHAIN_ID" \
  --arg model "$MODEL_ID" --argjson expected_count "$EXPECTED_ACTIVE_COUNT" '
  .schema_version == 1
  and .genesis_sha256 == $genesis_sha256
  and .chain_id == $chain_id
  and (.participants | type == "array" and length == $expected_count)
  and (([.participants[].address] | length) == ([.participants[].address] | unique | length))
  and (([.participants[].validator_key] | length) == ([.participants[].validator_key] | unique | length))
  and all(.participants[];
    (.address | test("^[a-zA-Z0-9]+$"))
    and (.validator_key | type == "string" and length > 0)
    and (.public_host | test("^[A-Za-z0-9.-]+$"))
    and .runtime_id == ("qwen3-0.6b:" + .address)
    and (.model_id // $model) == $model)
' "$EXPECTED_TOPOLOGY_FILE" >/dev/null \
  || blocked 'expected topology manifest is malformed, has duplicate identities, or does not bind this Genesis/profile'
cp "$EXPECTED_TOPOLOGY_FILE" "$RUN/expected-topology.json"

step 'Require an independently-owned external Host JOIN_PASS receipt'
[[ -d "$EXTERNAL_JOIN_RECEIPT_DIR" && -s "$EXTERNAL_JOIN_RECEIPT_DIR/receipt.json" && -s "$EXTERNAL_JOIN_RECEIPT_DIR/verdict.md" ]] \
  || blocked 'GDC_EXTERNAL_JOIN_RECEIPT_DIR must name an external Host JOIN_PASS evidence bundle'
grep -qx '# Host join: PASS' "$EXTERNAL_JOIN_RECEIPT_DIR/verdict.md" \
  || blocked 'external Host receipt does not declare JOIN_PASS'
jq -e --arg genesis_sha256 "$GENESIS_SHA256" --arg model "$MODEL_ID" '
  .verdict == "PASS"
  and .operator_mode == "external-operator"
  and .genesis_sha256 == $genesis_sha256
  and (.participant_address | test("^[a-zA-Z0-9]+$"))
  and (.validator_key | type == "string" and length > 0)
  and .runtime_id == ("qwen3-0.6b:" + .participant_address)
  and (.public_host | test("^[A-Za-z0-9.-]+$"))
  and .poc_accepted_once == true
  and (.poc_accepted_epoch | tonumber) > 0
  and (.poc_participant_weight | tonumber) > 0
  and (.poc_accepted_weight_sum | tonumber) > 0
  and (.poc_accepted_weight_sum | tonumber) == (.poc_committed_total | tonumber)
' "$EXTERNAL_JOIN_RECEIPT_DIR/receipt.json" >/dev/null \
  || blocked 'external Host receipt is not a current-lineage external-operator JOIN_PASS receipt'
jq -e --slurpfile expected "$RUN/expected-topology.json" '
  .participant_address as $address
  | .validator_key as $validator_key
  | .runtime_id as $runtime_id
  | .public_host as $public_host
  | $expected[0].participants
  | any(.[]; .address == $address and .validator_key == $validator_key
      and .runtime_id == $runtime_id and .public_host == $public_host)
' "$EXTERNAL_JOIN_RECEIPT_DIR/receipt.json" >/dev/null \
  || blocked 'external Host receipt identity is absent from the expected current-run topology manifest'

if (( EXPECTED_ACTIVE_COUNT > 2 )); then
  step 'Require the prior public Gate A PASS before Gate B topology verification'
  [[ -d "$GATE_A_EVIDENCE_DIR" && -s "$GATE_A_EVIDENCE_DIR/receipt.json" && -s "$GATE_A_EVIDENCE_DIR/verdict.md" ]] \
    || blocked 'GDC_GATE_A_EVIDENCE_DIR must name the prior public Gate A PASS bundle before Gate B'
  grep -qx '# Public network verification: PASS' "$GATE_A_EVIDENCE_DIR/verdict.md" \
    || blocked 'Gate A evidence does not declare a public network PASS'
  jq -e --arg genesis_sha256 "$GENESIS_SHA256" '
    .verdict == "PASS"
    and .expected_active_count == 2
    and .genesis_sha256 == $genesis_sha256
    and (.external_join_receipt | type == "string" and length > 0)
  ' "$GATE_A_EVIDENCE_DIR/receipt.json" >/dev/null \
    || blocked 'Gate A PASS evidence is not bound to this Genesis or lacks external Host evidence'
fi

step 'Capture ACTIVE participants and live consensus validators from public chain APIs'
curl -fsS --connect-timeout 5 --max-time 15   "$CHAIN_BASE/chain-api/productscience/inference/inference/participant" >"$RUN/participants-chain.json"
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/validators?per_page=100" >"$RUN/validators.json"
jq '[.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)
  | {address,validator_key,inference_url,status}]' "$RUN/participants-chain.json" >"$RUN/active-participants.json"
active_count="$(jq length "$RUN/active-participants.json")"
ACTIVE_PARTICIPANT_COUNT="$active_count"
(( active_count > 0 )) || failed 'no ACTIVE participants are present in public chain state'
(( active_count == EXPECTED_ACTIVE_COUNT )) \
  || failed "ACTIVE participant count $active_count differs from expected topology count $EXPECTED_ACTIVE_COUNT"
jq -e 'all(.[]; (.address | type == "string") and (.validator_key | type == "string") and (.inference_url | test("^https://[A-Za-z0-9.-]+$")))'   "$RUN/active-participants.json" >/dev/null   || failed 'an ACTIVE participant lacks a usable public address, validator key, or HTTPS inference URL'
jq -e --slurpfile expected "$RUN/expected-topology.json" '
  ([.[] | {address,validator_key,public_host:(.inference_url | sub("^https://"; ""))}] | sort_by(.address)) as $actual
  | ([$expected[0].participants[] | {address,validator_key,public_host}] | sort_by(.address)) as $expected
  | $actual == $expected
' "$RUN/active-participants.json" >/dev/null \
  || failed 'ACTIVE participant identities do not exactly match the expected current-run topology manifest'

step 'Prove public chain progress rather than a static reachable endpoint'
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" >"$RUN/status-first.json"
first_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/status-first.json")"
deadline=$((SECONDS + PROGRESS_TIMEOUT))
current_height=0
while (( SECONDS < deadline )); do
  curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" >"$RUN/status-second.json"
  current_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/status-second.json")"
  (( current_height > first_height )) && break
  printf 'WAIT  public chain height=%s initial=%s\n' "$current_height" "$first_height"
  sleep 2
done
(( current_height > first_height )) || inconclusive "public chain height did not advance beyond $first_height"

step 'Verify every ACTIVE participant has a synchronized public endpoint, exact runtime, and effective validator key'
printf '[]' >"$RUN/participant-observations.json"
common_height="$current_height"
while IFS= read -r participant; do
  address="$(jq -er .address <<<"$participant")"
  validator_key="$(jq -er .validator_key <<<"$participant")"
  endpoint="$(jq -er .inference_url <<<"$participant")"
  status="$(curl -fsS --connect-timeout 5 --max-time 15 "$endpoint/chain-rpc/status")"
  endpoint_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$status")"
  catching_up="$(jq -r '.result.sync_info.catching_up // false' <<<"$status")"
  [[ "$catching_up" == false ]] || failed "$address endpoint is still catching up"
  lag=$((current_height - endpoint_height)); (( lag >= 0 )) || lag=0
  (( lag <= LAG_THRESHOLD )) || failed "$address endpoint lag $lag exceeds threshold $LAG_THRESHOLD"
  (( endpoint_height < common_height )) && common_height="$endpoint_height"
  runtime_id="qwen3-0.6b:$address"
  expected_runtime_id="$(jq -er --arg address "$address" '.participants[] | select(.address == $address) | .runtime_id' "$RUN/expected-topology.json")"
  [[ "$runtime_id" == "$expected_runtime_id" ]] \
    || failed "$address runtime identity differs from the expected current-run topology manifest"
  curl -fsS --connect-timeout 5 --max-time 15     "$CHAIN_BASE/chain-api/productscience/inference/inference/hardware_nodes/$address" >"$RUN/hardware-$address.json"
  jq -e --arg runtime_id "$runtime_id" --arg model "$MODEL_ID" '
    .nodes.hardware_nodes
    | any(.[]; .local_id == $runtime_id and (.models | index($model) != null)
      and (.status == "INFERENCE" or .status == "POC"))
  ' "$RUN/hardware-$address.json" >/dev/null     || failed "$address lacks its exact chain-recorded $runtime_id runtime"
  jq -e --arg key "$validator_key" '
    .result.validators | any(.[]; .pub_key.value == $key and (.voting_power | tonumber) > 0)
  ' "$RUN/validators.json" >/dev/null     || failed "$address is ACTIVE but not an effective consensus validator with positive voting power"
  EFFECTIVE_VALIDATOR_COUNT=$((EFFECTIVE_VALIDATOR_COUNT + 1))
  jq --argjson participant "$participant" --arg runtime_id "$runtime_id"     --argjson endpoint_height "$endpoint_height" --argjson lag "$lag"     '. + [$participant + {runtime_id:$runtime_id,endpoint_height:$endpoint_height,lag:$lag}]'     "$RUN/participant-observations.json" >"$RUN/participant-observations.tmp"
  mv "$RUN/participant-observations.tmp" "$RUN/participant-observations.json"
done < <(jq -c '.[]' "$RUN/active-participants.json")

step "Compare public block hashes at common height $common_height"
while IFS= read -r endpoint; do
  curl -fsS --connect-timeout 5 --max-time 15 "$endpoint/chain-rpc/block?height=$common_height"     | jq -er '.result.block_id.hash'
done < <(jq -r '.[].inference_url' "$RUN/active-participants.json") | sort -u >"$RUN/common-height-hashes.txt"
[[ "$(wc -l <"$RUN/common-height-hashes.txt")" -eq 1 ]]   || failed "ACTIVE participant endpoints disagree on the block hash at height $common_height"

step 'Record current PoC state without treating it as confirmation-PoC proof'
curl -fsS --connect-timeout 5 --max-time 15   "$CHAIN_BASE/chain-api/productscience/inference/inference/current_epoch_group_data" >"$RUN/current-epoch-group.json"
initial_poc_epoch="$(jq -er '.epoch_group_data.epoch_index | tonumber' "$RUN/current-epoch-group.json")" \
  || inconclusive 'current PoC state lacks a valid epoch index'
printf '[]' >"$RUN/poc-observations.json"
record_poc_snapshot "$RUN/current-epoch-group.json" "$initial_poc_epoch"

step "Observe confirmation-PoC phases for $CPOC_EPOCHS complete epochs"
curl -fsS --connect-timeout 5 --max-time 15 \
  "$CHAIN_BASE/chain-api/productscience/inference/inference/get_current_epoch" >"$RUN/cpoc-initial-epoch.json"
initial_epoch="$(jq -er '.epoch | tonumber' "$RUN/cpoc-initial-epoch.json")"
(( initial_epoch > 1 )) || inconclusive 'confirmation-PoC observation cannot begin before epoch index 2'
deadline_epoch=$((initial_epoch + CPOC_EPOCHS))
deadline_seconds=$((SECONDS + CPOC_TIMEOUT))
printf '[]' >"$RUN/cpoc-observations.json"

while (( SECONDS < deadline_seconds )); do
  curl -fsS --connect-timeout 5 --max-time 15 \
    "$CHAIN_BASE/chain-api/productscience/inference/inference/get_current_epoch" >"$RUN/cpoc-current-epoch.json"
  observed_epoch="$(jq -er '.epoch | tonumber' "$RUN/cpoc-current-epoch.json")"
  curl -fsS --connect-timeout 5 --max-time 15 \
    "$CHAIN_BASE/chain-api/productscience/inference/inference/active_confirmation_poc_event" >"$RUN/cpoc-active-event.json"
  curl -fsS --connect-timeout 5 --max-time 15 \
    "$CHAIN_BASE/chain-api/productscience/inference/inference/confirmation_poc_events/$observed_epoch" >"$RUN/cpoc-events-$observed_epoch.json"
  curl -fsS --connect-timeout 5 --max-time 15 \
    "$CHAIN_BASE/chain-api/productscience/inference/inference/current_epoch_group_data" >"$RUN/cpoc-epoch-group-$observed_epoch.json"
  record_poc_snapshot "$RUN/cpoc-epoch-group-$observed_epoch.json" "$observed_epoch"
  jq --arg observed_at "$(date -u +%FT%TZ)" --argjson epoch "$observed_epoch" \
    --slurpfile active "$RUN/cpoc-active-event.json" \
    --slurpfile events "$RUN/cpoc-events-$observed_epoch.json" \
    --slurpfile group "$RUN/cpoc-epoch-group-$observed_epoch.json" \
    '. + [{observed_at:$observed_at,epoch:$epoch,active_event:$active[0],events:$events[0],epoch_group:$group[0]}]' \
    "$RUN/cpoc-observations.json" >"$RUN/cpoc-observations.tmp"
  mv "$RUN/cpoc-observations.tmp" "$RUN/cpoc-observations.json"

  completed_epoch="$(jq -r '[.[] | .events.events[]? | select(.phase == "CONFIRMATION_POC_COMPLETED") | (.epoch_index | tonumber)] | max // 0' "$RUN/cpoc-observations.json")"
  phases_complete=false
  jq -e '
    [.[] | .active_event.event.phase?] as $phases
    | ($phases | index("CONFIRMATION_POC_GRACE_PERIOD") != null)
    and ($phases | index("CONFIRMATION_POC_GENERATION") != null)
    and ($phases | index("CONFIRMATION_POC_VALIDATION") != null)
  ' "$RUN/cpoc-observations.json" >/dev/null 2>&1 && phases_complete=true
  applied=false
  if (( completed_epoch > 0 )); then
    jq -e --argjson completed_epoch "$completed_epoch" '
      [.[]
       | select(.epoch > $completed_epoch)
       | .epoch_group.epoch_group_data.validation_weights[]?
       | select((.confirmation_weight | tonumber) > 0)]
      | length > 0
    ' "$RUN/cpoc-observations.json" >/dev/null 2>&1 && applied=true
  fi
  poc_coverage=false
  poc_coverage_complete && poc_coverage=true
  if [[ "$phases_complete" == true && "$applied" == true && "$poc_coverage" == true ]]; then
    write_verdict PASS "public topology, PoC and confirmation-PoC event lineage passed through epoch $observed_epoch"
    printf 'PASS public network verification: %s\n' "$RUN"
    exit 0
  fi
  if (( observed_epoch >= deadline_epoch )); then
    inconclusive "confirmation-PoC deadline epoch $deadline_epoch reached (phases_complete=$phases_complete completed_epoch=$completed_epoch applied=$applied poc_coverage=$poc_coverage)"
  fi
  printf 'WAIT  CPoC epoch=%s/%s phases_complete=%s completed_epoch=%s applied=%s poc_coverage=%s\n' \
    "$observed_epoch" "$deadline_epoch" "$phases_complete" "$completed_epoch" "$applied" "$poc_coverage"
  sleep "$CPOC_POLL_SECONDS"
done
inconclusive "confirmation-PoC wall-clock deadline reached before epoch $deadline_epoch"
