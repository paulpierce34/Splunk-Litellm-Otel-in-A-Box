#!/usr/bin/env bash
# =============================================================================
# LLMLAB VALIDATE — end-to-end health + pipeline test
# Usage:  bash validate.sh          (run from ~/llmlab, or anywhere)
# Exits non-zero if any check fails. Safe to re-run any time.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./lab.env
LLAMA_KEY="$(cat .llama_key)"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
check(){ local name="$1" cond="$2"; if eval "$cond"; then ok "$name"; else bad "$name"; fi }

echo "=== 1. Container health ==="
for c in splunk litellm postgres otelcol; do
  st=$(podman container inspect "$c" --format '{{.State.Running}}' 2>/dev/null)
  check "container $c running" "[ '$st' = 'true' ]"
done

echo "=== 2. Service endpoints ==="
check "Splunk Web :8000 answers"        "[ \$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8000) != 000 ]"
check "LiteLLM :4000 alive"             "curl -s -m 5 http://localhost:4000/health/liveliness | grep -q alive"
check "HEC :8088 healthy"               "[ \$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H 'Authorization: Splunk '\$HEC_TOKEN http://localhost:8088/services/collector/health) = 200 ]"

echo "=== 3. Auth walls (negative tests) ==="
check "LiteLLM rejects bad key"         "[ \$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:4000/v1/chat/completions -H 'Authorization: Bearer sk-bogus' -H 'Content-Type: application/json' -d '{\"model\":\"qwen3-8b\",\"messages\":[]}') = 401 ]"
check "Enclave rejects direct access"   "[ \$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://172.27.176.1:18434/v1/models) = 401 ]"

echo "=== 4. Enclave inference (positive test, ~30-90s) ==="
resp=$(curl -s -m 180 http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"Reply with exactly: VALIDATE-OK"}],"max_tokens":400}')
echo "$resp" | grep -q "VALIDATE-OK" && ok "qwen3-8b inference through LiteLLM" || bad "qwen3-8b inference through LiteLLM"

echo "=== 5. Telemetry landed in Splunk (allow ~15s flush) ==="
sleep 15
count=$(podman exec splunk bash -c "curl -sk -m 40 'https://localhost:8089/services/search/jobs/export' -u \"admin:$SPLUNK_PASSWORD\" --data-urlencode 'search=search index=llmlab sourcetype=litellm:otel | stats count' --data-urlencode 'output_mode=json'" 2>/dev/null | grep -o '"count":"[0-9]*"' | grep -o '[0-9]*')
check "litellm:otel events indexed (count=$count)" "[ \${count:-0} -ge 1 ]"

echo "=== 6. HEC round-trip (manual event) ==="
curl -s -m 10 "http://localhost:8088/services/collector/event" \
  -H "Authorization: Splunk $HEC_TOKEN" \
  -d "{\"event\":{\"test\":\"validate-$RANDOM\"},\"index\":\"llmlab\",\"sourcetype\":\"test:ping\"}" | grep -q '"code":0' \
  && ok "HEC accepts event" || bad "HEC accepts event"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
