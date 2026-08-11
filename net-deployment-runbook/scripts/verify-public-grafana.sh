#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_project

RUN="${GDC_GRAFANA_EVIDENCE_DIR:-$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}-public-grafana}"
NETWORK_URL="${GDC_PUBLIC_GRAFANA_URL:-https://$GRAFANA_HOST/d/gdc-network/gonka-devnet-network?orgId=1&from=now-24h&to=now&timezone=utc&kiosk}"
INFERENCE_URL="https://$GRAFANA_HOST/d/gdc-inference/gonka-devnet-inference?orgId=1&from=now-7d&to=now&timezone=utc&kiosk"
mkdir -p "$RUN"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  if curl -fsS "https://$GRAFANA_HOST/api/health" | jq -e '.database == "ok"' >"$RUN/health.json" 2>/dev/null; then break; fi
  printf 'WAIT  public Grafana health\n'; sleep 3
done
test -s "$RUN/health.json" || die 'public Grafana did not become healthy'

for dashboard in gdc-network gdc-inference; do
  curl -fsS "https://$GRAFANA_HOST/api/dashboards/uid/$dashboard" >"$RUN/$dashboard.json"
  jq -e --arg dashboard "$dashboard" '.dashboard.uid == $dashboard and ([.dashboard.panels[]? | select(.targets? != null)] | length >= 20) and ([.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)] | length >= 20)' "$RUN/$dashboard.json" >/dev/null || die "public Grafana dashboard $dashboard is incomplete"
done
jq -r '.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)' "$RUN/gdc-network.json" "$RUN/gdc-inference.json" | sort -u >"$RUN/panel-expressions.txt"
panel_deadline=$((SECONDS + 180))
panel_data_ready=false
missing_expression=''
while (( SECONDS < panel_deadline )); do
  : >"$RUN/panel-results.jsonl"
  missing_expression=''
  while IFS= read -r expression; do
    # A dashboard may use `or vector(0)` for presentation, but that synthetic
    # fallback is never evidence that the underlying metric exists. Query the
    # source expression separately and require a real frame from it.
    source_expression="$expression"
    if [[ "$expression" == *' or vector(0)' ]]; then
      source_expression="${expression% or vector(0)}"
    fi
    payload="$(jq -cn --arg expression "$source_expression" '{
      from:"now-15m",
      to:"now",
      queries:[{
        refId:"A",
        expr:$expression,
        interval:"15s",
        intervalMs:15000,
        maxDataPoints:1000,
        datasource:{uid:"prometheus",type:"prometheus"}
      }]
    }')"
    response="$(curl -sS --connect-timeout 5 --max-time 20 -w $'\n%{http_code}' \
      -X POST "https://$GRAFANA_HOST/api/ds/query" \
      -H 'Content-Type: application/json' --data "$payload")"
    http_code="${response##*$'\n'}"
    result="${response%$'\n'*}"
    jq -cn --arg expression "$expression" --arg source_expression "$source_expression" --arg http_code "$http_code" --argjson result "$result" \
      '{expression:$expression,source_expression:$source_expression,http_code:($http_code|tonumber),result:$result}' >>"$RUN/panel-results.jsonl"
    if [[ "$http_code" != 200 ]] || ! jq -e '
      (.results.A.error? | not)
      and ([.results.A.frames[]?.data.values[]? | length] | any(. > 0))
    ' <<<"$result" >/dev/null; then
      missing_expression="$expression"
      break
    fi
  done <"$RUN/panel-expressions.txt"
  if [[ -z "$missing_expression" ]]; then
    panel_data_ready=true
    break
  fi
  printf 'WAIT  public Grafana range query after datasource restart: %s\n' "$missing_expression"
  sleep 3
done
[[ "$panel_data_ready" == true ]] || die "public Grafana panel range query returned no data or an error: $missing_expression"

command -v google-chrome >/dev/null || die 'google-chrome is required to validate public Grafana rendering'
google-chrome --headless=new --no-sandbox --disable-gpu --virtual-time-budget=12000 --window-size=1440,1000 --dump-dom "$NETWORK_URL" >"$RUN/gdc-network-dom.html" 2>"$RUN/gdc-network-chrome.stderr"
google-chrome --headless=new --no-sandbox --disable-gpu --virtual-time-budget=12000 --window-size=1440,1000 --dump-dom "$INFERENCE_URL" >"$RUN/gdc-inference-dom.html" 2>"$RUN/gdc-inference-chrome.stderr"
for dashboard in gdc-network gdc-inference; do
  ! grep -Eqi 'no data|panel plugin not found|unauthorized|sign in to grafana' "$RUN/$dashboard-dom.html" || die "public Grafana browser DOM reports a data, panel, or authentication failure on $dashboard"
done
grep -q 'Gonka DevNet Network' "$RUN/gdc-network-dom.html" || die 'public Grafana browser DOM did not render the network dashboard'
grep -q 'Gonka DevNet Inference' "$RUN/gdc-inference-dom.html" || die 'public Grafana browser DOM did not render the inference dashboard'
cat >"$RUN/finalize.md" <<EOF
# Public Grafana: PASS

- Network: $NETWORK_URL
- Inference: $INFERENCE_URL
- Dashboards: gdc-network, gdc-inference
- Prometheus panel expressions: $(wc -l <"$RUN/panel-expressions.txt") returned live data.
- Browser DOM contains both rendered dashboards and no No data, plugin, or authentication failure.
EOF
printf 'PASS public Grafana: %s\n' "$RUN"
