#!/usr/bin/env bash
# =============================================================================
# LLMLAB BRING-UP — repeatable lab deployment (Podman)
# Simulates: client -> LiteLLM gateway (virtual keys, budgets) -> inference
#            enclave -> OTel collector -> Splunk HEC -> detections
# Prereqs: podman machine running, ~/llmlab/{lab.env, litellm-config.yaml,
#          otel-config.yaml, .llama_key, .openrouter_key} present.
# Usage:   ./bring-up.sh [--fresh]   (--fresh removes existing containers first)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

FRESH=0; [[ "${1:-}" == "--fresh" ]] && FRESH=1

# --- 1. Load secrets ---------------------------------------------------------
set -a; source ./lab.env; set +a
export LLAMA_KEY="$(cat .llama_key)"
export OPENROUTER_KEY="$(cat .openrouter_key)"
NET=llmlab

# --- 2. Clean slate ----------------------------------------------------------
if [[ $FRESH == 1 ]]; then
  podman rm -f splunk litellm postgres otelcol 2>/dev/null || true
fi
ct_exists() { podman container inspect "$1" >/dev/null 2>&1; }

# --- 3. Network --------------------------------------------------------------
podman network inspect "$NET" >/dev/null 2>&1 || podman network create "$NET"

# --- 4. Postgres (LiteLLM key/budget DB) -------------------------------------
ct_exists postgres || \
podman run -d --name postgres --network "$NET" \
  -e POSTGRES_USER=litellm -e POSTGRES_PASSWORD="${SPLUNK_PASSWORD}" \
  -e POSTGRES_DB=litellm \
  docker.io/library/postgres:16-alpine >/dev/null

# --- 5. Splunk Enterprise (trial) -------------------------------------------
ct_exists splunk || \
podman run -d --name splunk --network "$NET" --hostname splunk \
  -p 8000:8000 -p 8088:8088 \
  -e SPLUNK_START_ARGS=--accept-license \
  -e SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com \
  -e SPLUNK_PASSWORD="${SPLUNK_PASSWORD}" \
  -e SPLUNK_HEC_TOKEN="${HEC_TOKEN}" \
  -e SPLUNK_HEC_SSL=false \
  docker.io/splunk/splunk:latest >/dev/null

# --- 6. OTel collector (OTLP -> Splunk HEC) ----------------------------------
ct_exists otelcol || \
podman run -d --name otelcol --network "$NET" \
  --env-file ./lab.env \
  -v "$PWD/otel-config.yaml:/etc/otelcol-contrib/config.yaml:Z" \
  docker.io/otel/opentelemetry-collector-contrib:latest >/dev/null

# --- 7. LiteLLM proxy (gateway) ----------------------------------------------
ct_exists litellm || \
podman run -d --name litellm --network "$NET" \
  -p 4000:4000 \
  -e LLAMA_KEY -e OPENROUTER_KEY \
  -e MASTER_KEY -e USER_KEY -e BUDGET_KEY \
  -e DATABASE_URL="postgresql://litellm:${SPLUNK_PASSWORD}@postgres:5432/litellm" \
  -e OTEL_EXPORTER_OTLP_ENDPOINT=http://otelcol:4318 \
  -e STORE_MODEL_IN_DB=True \
  -v ./litellm-config.yaml:/app/config.yaml:Z \
  ghcr.io/berriai/litellm:main-stable \
  --config /app/config.yaml --port 4000 >/dev/null

# --- 8. Create the llmlab index (HEC does NOT auto-create it) -----------------
echo "[*] Creating llmlab index (waits for splunkd)..."
for i in $(seq 1 24); do
  sleep 5
  podman exec splunk bash -c "curl -sk -m 10 'https://localhost:8089/services/data/indexes' -u \"admin:\$SPLUNK_PASSWORD\" --data-urlencode 'name=llmlab' --data-urlencode 'datatype=event' --data-urlencode 'maxTotalDataSizeMB=512' --data-urlencode 'frozenTimePeriodInSecs=7776000'" >/dev/null 2>&1 && break
done

# --- 9. Health checks (wait for each hop) ------------------------------------
echo "[*] Waiting for services..."
for i in $(seq 1 60); do
  ok=1
  curl -s http://localhost:8000 >/dev/null || ok=0            # Splunk Web
  curl -s http://localhost:4000/health/liveliness >/dev/null || ok=0  # LiteLLM
  [[ $ok == 1 ]] && break
  sleep 5
done
echo "[*] Splunk Web:        http://localhost:8000  (admin / \$SPLUNK_PASSWORD in lab.env)"
echo "[*] LiteLLM proxy:     http://localhost:4000"
echo "[*] HEC endpoint:      http://localhost:8088  (token \$HEC_TOKEN, index llmlab)"
echo "[+] Bring-up complete. Next: register virtual keys (see runbook)."
