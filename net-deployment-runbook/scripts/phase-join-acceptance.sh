#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

# This evidence phase is shared by a completed Genesis bootstrap and an
# independent Host join. `node_name` deliberately rejects the Genesis alias
# for the *join action* itself; applying that action-only restriction here
# made a healthy Genesis unable to prove its required PoC/validator gate.
NODE="${1:-}"
topology_contains_node "$NODE" || die "unknown SSH alias: $NODE"
ACCOUNT="$(node_account_file "$NODE")"
IDENTITY="$(node_identity_file "$NODE")"
[[ -s "$ACCOUNT" && -s "$IDENTITY" ]] || die "$NODE has no local public account/identity required for join acceptance"
ADDRESS="$(jq -er .address "$ACCOUNT")"
VALIDATOR_KEY="$(jq -er .consensus_pubkey "$IDENTITY")"
RUNTIME_ID="$(runtime_id_for_participant "$ADDRESS")"

EPOCHS="${GDC_JOIN_EFFECTIVE_EPOCHS:-}"
TIMEOUT="${GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS:-}"
[[ "$EPOCHS" =~ ^[1-9][0-9]*$ && "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || die 'release profile must define positive GDC_JOIN_EFFECTIVE_EPOCHS and GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS'
record_phase_profile "join-acceptance-$NODE"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/join-acceptance-$NODE"
mkdir -p "$RUN"
# The exit trap is installed before the first public-chain probe. Initialise
# receipt fields so an early transport failure itself remains diagnosable.
GENESIS_HASH=UNAVAILABLE
deadline_epoch=0
poc_accepted_once=false
poc_accepted_epoch=0
poc_participant_weight=0
poc_accepted_weight_sum=0
poc_committed_total=0
printf '[]' >"$RUN/poc-acceptance-observations.json"

# A transport or parsing failure must still leave an honest, sanitized
# evidence verdict.  Expected negative outcomes below write their own more
# specific receipt before exiting.
on_exit() {
  local rc=$?
  if (( rc != 0 )) && [[ ! -s "$RUN/verdict.md" ]]; then
    if declare -F write_receipt >/dev/null; then
      write_receipt INCONCLUSIVE "join acceptance stopped with exit code $rc"
    else
      jq -n --arg verdict INCONCLUSIVE --arg reason "join acceptance stopped with exit code $rc before receipt initialization" \
        '{schema_version:1,verdict:$verdict,reason:$reason}' >"$RUN/receipt.json"
    fi
    cat >"$RUN/verdict.md" <<EOF
# Host join: INCONCLUSIVE

Join acceptance stopped with exit code $rc before its final verdict. Inspect
the run log and evidence bundle; no successful join is implied.
EOF
  fi
}
trap on_exit EXIT

CHAIN_BASE="https://${GENESIS_PUBLIC_HOST}"
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" \
  || die 'cannot read canonical public Genesis for join acceptance'
GENESIS_HASH="$(genesis_sha256 "$RUN/genesis.json")"
bind_run_manifest_genesis "$GENESIS_HASH"

group_endpoint="$CHAIN_BASE/chain-api/productscience/inference/inference/current_epoch_group_data"
hardware_endpoint="$CHAIN_BASE/chain-api/productscience/inference/inference/hardware_nodes/$ADDRESS"
participant_endpoint="$CHAIN_BASE/v2/participants/$ADDRESS"
validators_endpoint="$CHAIN_BASE/chain-rpc/validators?per_page=100"
initial_group="$(curl -fsS --connect-timeout 5 --max-time 15 "$group_endpoint")"
initial_epoch="$(jq -er '.epoch_group_data.epoch_index | tonumber' <<<"$initial_group")"
deadline_epoch=$((initial_epoch + EPOCHS))
deadline_seconds=$((SECONDS + TIMEOUT))

write_receipt() {
  local verdict="$1" reason="$2"
  jq -n \
    --arg verdict "$verdict" --arg reason "$reason" --arg run_id "${GDC_RUN_ID:-manual}" \
    --arg chain_id "$CHAIN_ID" --arg genesis_sha256 "$GENESIS_HASH" \
    --arg participant_address "$ADDRESS" --arg validator_key "$VALIDATOR_KEY" \
    --arg runtime_id "$RUNTIME_ID" --arg public_host "$(node_public_host "$NODE")" \
    --arg runbook_commit "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf UNAVAILABLE)" \
    --arg profile_hash "$(profile_hash)" --arg operator_mode "${GDC_OPERATOR_MODE:-single-operator}" \
    --argjson deadline_epoch "$deadline_epoch" \
    --argjson poc_accepted_once "$poc_accepted_once" --argjson poc_accepted_epoch "$poc_accepted_epoch" \
    --argjson poc_participant_weight "$poc_participant_weight" --argjson poc_accepted_weight_sum "$poc_accepted_weight_sum" --argjson poc_committed_total "$poc_committed_total" \
    '{schema_version:1,verdict:$verdict,reason:$reason,run_id:$run_id,chain_id:$chain_id,genesis_sha256:$genesis_sha256,participant_address:$participant_address,validator_key:$validator_key,runtime_id:$runtime_id,public_host:$public_host,runbook_commit:$runbook_commit,profile_hash:$profile_hash,operator_mode:$operator_mode,deadline_epoch:$deadline_epoch,poc_accepted_once:$poc_accepted_once,poc_accepted_epoch:$poc_accepted_epoch,poc_participant_weight:$poc_participant_weight,poc_accepted_weight_sum:$poc_accepted_weight_sum,poc_committed_total:$poc_committed_total}' \
    >"$RUN/receipt.json"
}

inconclusive() {
  local reason="$1"
  write_receipt INCONCLUSIVE "$reason"
  cat >"$RUN/verdict.md" <<EOF
# Host join: INCONCLUSIVE

$NODE reached PARTICIPANT_ACTIVE but did not prove every JOIN_PASS state before
epoch $deadline_epoch: $reason

Retry the same command after the next eligible epoch. The existing account,
consensus identity and runtime identity are retained; no new participant must
be created.
EOF
  printf 'INCONCLUSIVE %s; evidence: %s\n' "$reason" "$RUN" >&2
  exit 2
}

fail() {
  local reason="$1"
  write_receipt FAIL "$reason"
  cat >"$RUN/verdict.md" <<EOF
# Host join: FAIL

$NODE violated a required post-ACTIVE join invariant: $reason

The existing account and identity are retained for diagnosis, but this run
must not be treated as a successful join.
EOF
  printf 'FAIL %s; evidence: %s\n' "$reason" "$RUN" >&2
  exit 1
}

blocked() {
  local reason="$1"
  write_receipt BLOCKED "$reason"
  cat >"$RUN/verdict.md" <<EOF
# Host join: BLOCKED

$NODE cannot complete the required join proof: $reason

Supply the named safe precondition, then retry the same command. The existing
account and identity are retained; no new participant must be created.
EOF
  printf 'BLOCKED %s; evidence: %s\n' "$reason" "$RUN" >&2
  exit 3
}

step "Wait for $NODE PoC eligibility and effective validator membership through epoch $deadline_epoch"
while (( SECONDS < deadline_seconds )); do
  participant="$(curl -fsS --connect-timeout 5 --max-time 15 "$participant_endpoint" 2>/dev/null || true)"
  group="$(curl -fsS --connect-timeout 5 --max-time 15 "$group_endpoint" 2>/dev/null || true)"
  hardware="$(curl -fsS --connect-timeout 5 --max-time 15 "$hardware_endpoint" 2>/dev/null || true)"
  validators="$(curl -fsS --connect-timeout 5 --max-time 15 "$validators_endpoint" 2>/dev/null || true)"
  epoch="$(jq -r '.epoch_group_data.epoch_index // empty' <<<"$group" 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || { printf 'WAIT  join acceptance cannot read epoch state\n'; sleep 5; continue; }
  printf '%s\n' "$participant" >"$RUN/participant.json"
  printf '%s\n' "$group" >"$RUN/epoch-group.json"
  printf '%s\n' "$hardware" >"$RUN/hardware-nodes.json"
  printf '%s\n' "$validators" >"$RUN/validators.json"

  participant_active=false
  jq -e '.participant.status == "ACTIVE" or .participant.status == "PARTICIPANT_STATUS_ACTIVE" or .participant.status == "1" or .participant.status == 1' \
    "$RUN/participant.json" >/dev/null 2>&1 && participant_active=true
  runtime_ready=false
  jq -e --arg runtime_id "$RUNTIME_ID" --arg model "$MODEL_ID" '
    .nodes.hardware_nodes
    | any(.[]; .local_id == $runtime_id and (.models | index($model) != null) and (.status == "INFERENCE" or .status == "POC"))
  ' "$RUN/hardware-nodes.json" >/dev/null 2>&1 && runtime_ready=true
  weight_evidence="$RUN/validation-weight-evidence.json"
  "$ROOT/scripts/check-validation-weight-evidence.sh" "$RUN/epoch-group.json" "$ADDRESS" >"$weight_evidence" \
    || fail 'validation-weight evidence is malformed or cannot be reconciled'
  distribution_integrity="$(jq -r .distribution_integrity "$weight_evidence")"
  participant_weight="$(jq -er '.participant_weight | tonumber' "$weight_evidence")"
  accepted_weight_sum="$(jq -er '.accepted_weight_sum | tonumber' "$weight_evidence")"
  committed_total="$(jq -er '.committed_total | tonumber' "$weight_evidence")"
  jq --argjson epoch "$epoch" --slurpfile weight "$weight_evidence" \
    '. + [{epoch:$epoch,weight_evidence:$weight[0]}]' "$RUN/poc-acceptance-observations.json" \
    >"$RUN/poc-acceptance-observations.tmp"
  mv "$RUN/poc-acceptance-observations.tmp" "$RUN/poc-acceptance-observations.json"
  if [[ "$distribution_integrity" != true && "$accepted_weight_sum" -gt 0 ]]; then
    fail "validation-weight distribution is rejected (accepted_sum=$accepted_weight_sum committed_total=$committed_total participant_weight=$participant_weight)"
  fi
  poc_accepted=false
  jq -e '.participant_eligible == true' "$weight_evidence" >/dev/null && poc_accepted=true
  if [[ "$poc_accepted" == true ]]; then
    poc_accepted_once=true
    poc_accepted_epoch="$epoch"
    poc_participant_weight="$participant_weight"
    poc_accepted_weight_sum="$accepted_weight_sum"
    poc_committed_total="$committed_total"
  fi
  validator_effective=false
  jq -e --arg key "$VALIDATOR_KEY" '
    .result.validators
    | any(.[]; .pub_key.value == $key and (.voting_power | tonumber) > 0)
  ' "$RUN/validators.json" >/dev/null 2>&1 && validator_effective=true

  [[ "$participant_active" == true ]] || fail 'participant is no longer ACTIVE'
  if [[ "$poc_accepted_once" == true && "$runtime_ready" == true ]]; then
    record_join_state "$NODE" POC_ACCEPTED "$ADDRESS"
  fi
  if [[ "$validator_effective" == true ]]; then
    record_join_state "$NODE" VALIDATOR_EFFECTIVE "$ADDRESS"
  fi
  # Requiring the deadline epoch even when all conditions appear early proves
  # the promised four complete epoch transitions after ACTIVE.
  if (( epoch >= deadline_epoch )) \
    && [[ "$poc_accepted_once" == true && "$runtime_ready" == true && "$validator_effective" == true ]]; then
    break
  fi
  if (( epoch >= deadline_epoch )); then
    inconclusive "eligibility deadline reached (runtime=$runtime_ready poc_accepted_once=$poc_accepted_once validator_effective=$validator_effective)"
  fi
  printf 'WAIT  join state epoch=%s/%s runtime=%s poc_accepted_once=%s validator_effective=%s participant_weight=%s accepted_sum=%s committed_total=%s\n' \
    "$epoch" "$deadline_epoch" "$runtime_ready" "$poc_accepted_once" "$validator_effective" \
    "$participant_weight" "$accepted_weight_sum" "$committed_total"
  sleep 5
done
(( SECONDS < deadline_seconds )) || inconclusive 'wall-clock deadline reached before eligibility evidence'

KEY_FILE="${GDC_JOIN_GATEWAY_CLIENT_KEY_FILE:-}"
[[ -n "$KEY_FILE" && -f "$KEY_FILE" ]] \
  || blocked 'GDC_JOIN_GATEWAY_CLIENT_KEY_FILE is required for the final authenticated gateway regression'
[[ "$(stat -c %a "$KEY_FILE")" == 600 ]] \
  || blocked 'GDC_JOIN_GATEWAY_CLIENT_KEY_FILE must have mode 0600'
CLIENT_KEY="$(cut -d, -f1 <"$KEY_FILE")"
[[ -n "$CLIENT_KEY" ]] || blocked 'GDC_JOIN_GATEWAY_CLIENT_KEY_FILE is empty'
step 'Run one authenticated gateway regression (routing through the new Host is not required)'
"$ROOT/04-ops/test-inference-until-ready.sh" \
  "https://$API_HOST" "$CLIENT_KEY" "$RUN/gateway-regression" \
  "$RUN/gateway-regression/completion.json" 180

record_join_state "$NODE" COMPLETE "$ADDRESS"
write_receipt PASS 'active participant, exact chain runtime, positive accepted PoC weight in the bounded window, effective validator, and authenticated gateway regression proved'
cat >"$RUN/verdict.md" <<EOF
# Host join: PASS

- participant: $ADDRESS ACTIVE;
- runtime: $RUNTIME_ID is chain-recorded;
- PoC: positive accepted validation weight observed in epoch $poc_accepted_epoch with participant weight $poc_participant_weight and accepted sum $poc_accepted_weight_sum matching committed total $poc_committed_total;
- validator: $VALIDATOR_KEY has positive live consensus voting power;
- gateway: authenticated regression succeeded.
EOF
printf 'PASS %s JOIN_PASS evidence: %s\n' "$NODE" "$RUN"
