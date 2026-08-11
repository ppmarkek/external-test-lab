#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
deploy="$ROOT/scripts/deploy-telegram-bot.sh"

grep -Fq 'for host in "${GDC_NODES[@]}"; do' "$deploy"
grep -Fq '[[ "$host" == "$BOT_HOST" ]] && continue' "$deploy"
grep -Fq 'docker ps -q --filter name=gonka-devnet-bot-bot | xargs -r docker stop' "$deploy"
grep -Fq 'textfile_collector/telegram-bot.prom' "$deploy"
grep -Fq "docker info >/dev/null 2>&1' >/dev/null 2>&1 || continue" "$deploy"
grep -Fq 'docker compose up -d --build --force-recreate' "$deploy"
grep -Fq 'grep -qx gonka-devnet-bot-bot-1' "$deploy"
grep -Fq 'BOT_KEY_FILE="$SECRETS/gateway.telegram-client-key"' "$deploy"
grep -Fq 'BOT_INTERNAL_TOKEN_FILE="$SECRETS/telegram.conversation-api-token"' "$deploy"
grep -Fq 'Resolve the OPS role input before requiring it' "$deploy"
if grep -Fq 'ENV_FILE="${GDC_ENV:-$GDC_HOME/.env}"' "$deploy"; then
  echo 'Telegram deployment must resolve the OPS role input through load_project before requiring an environment file' >&2
  exit 1
fi
grep -Fq 'BOT_API_BASE_URL="https://${API_HOST}/v1"' "$deploy"
if grep -Fq 'https://api.gonka-dev.net/v1' "$deploy"; then
  echo 'Telegram deployment must not hard-code a generic API host instead of the configured gateway API origin' >&2
  exit 1
fi
grep -Fq 'GATEWAY_API_KEY=$BOT_GATEWAY_API_KEY' "$deploy"
grep -Fq 'INTERNAL_API_TOKEN=$BOT_INTERNAL_API_TOKEN' "$deploy"
grep -Fq 'Telegram conversation consumer is not yet ready' "$deploy"
grep -Fq 'python3 /app/bot.py --probe' "$deploy"
grep -Fq 'HEALTH_MAX_AGE_SECONDS=' "$deploy"
grep -Fq 'PROBE_MAX_OUTPUT_TOKENS=8' "$deploy"
grep -Fq 'max_output_tokens' "$ROOT/scripts/telegram-bot/bot.py"
grep -Fq 'inference_failure_reason' "$ROOT/scripts/telegram-bot/bot.py"
! grep -Eq 'gateway-key-pool|POOL_SOURCE|key issuer' "$deploy"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
TELEGRAM_BOT_TOKEN=fixture-telegram-token \
GATEWAY_API_KEY=fixture-gateway-key \
INTERNAL_API_TOKEN=fixture-internal-token \
STATE_DB="$tmp/bot.sqlite3" \
METRICS_FILE="$tmp/telegram-bot.prom" \
python3 - "$ROOT/scripts/telegram-bot/bot.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("telegram_bot_fixture", sys.argv[1])
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)
with bot.connection() as db:
    bot.record_inference(db, "http_429")
    health = bot.health_payload(db)
assert health["inference_ready"] is False
assert health["last_inference_outcome"] == "http_429"
assert health["inference_failure_reason"] == "http_429"
PY

grep -Fq '@telegram_consumer path /status/telegram-consumer' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq '@telegram_metrics_from_monitoring' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'remote_ip {$MONITORING_CIDR}' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'job_name: telegram-consumer' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'json("/status/telegram-consumer")' "$ROOT/04-ops/site/src/app.js"

grep -Fq './gdc.sh ops consumer telegram apply' "$ROOT/gdc.sh"
grep -Fq 'phase-telegram-consumer.sh' "$ROOT/gdc.sh"
grep -Fq 'gateway access-key ensure telegram' "$ROOT/gdc.sh"
grep -Fq 'phase-gateway-access-key.sh' "$ROOT/gdc.sh"
! grep -Eq 'telegram-key-probe|telegram-bot\)' "$ROOT/gdc.sh"

printf 'PASS Telegram conversation consumer deployment contract\n'
