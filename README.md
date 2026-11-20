<img width="2480" height="1218" alt="image" src="https://github.com/user-attachments/assets/051045a6-d6d7-472b-8d50-ec4bd90897ee" />
# LLMLab — LLM Gateway Surveillance Lab (Sysadmin Runbook)

**Purpose:** Home lab replicating a production design: all LLM inference goes through a controlled gateway (per-user keys, budgets, model RBAC), hitting an "air-gapped" local inference enclave — with every call's full telemetry (prompt, response, trace, timing, cost) indexed in Splunk for detection engineering.

**Everything is free, local, and nothing is bound to `0.0.0.0`.**

---

## 1. Architecture at a Glance

Open `llmlab-architecture.html` (in this folder) in a browser for the full visual.

```
Hermes / any client
   │  Bearer <virtual key>
   ▼
LiteLLM proxy :4000  ──── Postgres :5432 (keys · budgets · spend)
   │        │
   │        └─ OTel spans ─► otelcol :4318 ─► Splunk HEC :8088 ─► index=llmlab
   ▼
qwen3-8b ─► scoped portproxy (vSwitch IP only) ─► llama.cpp CUDA :18434 (127.0.0.1 only)
cloud-model / cloud-auto ─► OpenRouter (external, free tier, for RBAC tests)
```

**Security posture (why this is safe to run at home):**
- llama.cpp is Hermes-managed and binds **127.0.0.1 only** — never exposed
- The only path from containers to it is a Windows `netsh portproxy` listening **only** on the internal WSL vSwitch address `172.27.176.1:18434`, plus a firewall rule allowing inbound **only from `172.27.176.0/20`** (the podman/WSL internal subnet — not LAN-routable)
- A direct request to the enclave from anything else returns **401** — this is the lab's "unauthorized direct-to-upstream" detection target
- Splunk Web (:8000) and HEC (:8088) are published to localhost only; Splunk REST (:8089) is deliberately **not** published — search from inside the container

---

## 2. Files in `~/llmlab/`

| File | Purpose |
|---|---|
| `compose.yaml` | **Declarative stack definition** (podman compose). Equivalent to bring-up.sh — use one or the other. |
| `bring-up.sh` | Imperative bring-up (idempotent; `--fresh` removes & recreates all 4 containers). |
| `validate.sh` | **12-check validator** — run any time; exits non-zero if anything is broken. |
| `lab.env` | All secrets: `SPLUNK_PASSWORD`, `HEC_TOKEN`, `MASTER_KEY`, `USER_KEY`, `BUDGET_KEY`. |
| `litellm-config.yaml` | Model definitions: `qwen3-8b` (local enclave), `cloud-model` (gemma-4-31b:free), `cloud-auto` (OpenRouter auto-router). |
| `otel-config.yaml` | OTLP receiver :4318 → `splunk_hec` exporter → `http://splunk:8088`, index `llmlab`. |
| `.llama_key` | The llama.cpp enclave API key (extracted from Hermes managed runtime — LiteLLM is the **sole holder**). |
| `.openrouter_key` | OpenRouter key for the cloud models. |
| `admin-setup.ps1` | Elevated one-time setup: portproxy + firewall rules (already applied). |
| `gen_tokens.py` | Regenerates `lab.env` secrets (only if you want to rotate everything). |

**Images** (all pulled and cached): `docker.io/splunk/splunk:latest`, `ghcr.io/berriai/litellm:main-stable`, `docker.io/library/postgres:16-alpine`, `docker.io/otel/opentelemetry-collector-contrib:latest`.

> ⚠️ Do **not** pull `ghcr.io/signalfx/splunk-otel-collector` — it 403s for anonymous pulls. The contrib image is the equivalent and works.

---

## 3. Prerequisites

- **Windows 11** with WSL2, **Podman 6.x** (`podman machine start` — the machine is WSL-backed, currently sized 2GiB, 10 CPUs; the host `.wslconfig` caps the whole WSL VM at 6GB so Splunk+LiteLLM coexist with the host's 16GB)
- **Hermes managed llama.cpp runtime** running (auto-starts with Hermes desktop; serves `Qwen3-8B-128K-Q4_K_M` on `127.0.0.1:18434` with API key at `AppData\Local\hermes\runtimes\llamacpp\.api_key`)
- **One-time host setup (already done, re-run only on a new machine):**
  1. `%USERPROFILE%\.wslconfig` containing:
     ```ini
     [wsl2]
     memory=6GB
     processors=4
     ```
     then `wsl --shutdown`
  2. Elevated `admin-setup.ps1` (portproxy + firewall rules):
     ```powershell
     Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy','Bypass','-NoProfile','-File','C:\Users\jluc\llmlab\admin-setup.ps1'
     ```
     Verify: `netsh interface portproxy show v4tov4` → shows `172.27.176.1 18434 → 127.0.0.1 18434`

---

## 4. Bring the Stack Up

```bash
cd ~/llmlab

# Option A — declarative (compose). Secrets MUST be exported first — docker-compose
# is a child process and does NOT see unexported shell vars:
set -a; source ./lab.env; set +a
export LLAMA_KEY=$(cat .llama_key)
export OPENROUTER_KEY=$(cat .openrouter_key)
podman compose -f compose.yaml up -d

# Option B — imperative (script, self-contained; handles env + index creation):
bash bring-up.sh            # add --fresh to wipe & recreate containers
```

> **Important:** use Option A *or* B, not both on the same names — compose cannot adopt
> script-created containers (name conflict) and vice versa. To migrate script→compose:
> `bash bring-up.sh --fresh` is NOT needed; instead `podman rm -f splunk litellm postgres otelcol`
> then run the compose commands above. Both produce an identical stack.
>
> **Verified:** `podman compose -f compose.yaml config` exits 0 with zero "not set" warnings
> when the env sequence above is followed. Skipping the `set -a` export makes compose silently
> render **blank** `SPLUNK_PASSWORD`/`HEC_TOKEN` values — Splunk would boot with an empty admin
> password. The `config` subcommand is your pre-flight check.

Splunk's **first boot takes 2–4 minutes** (internal init). Watch it with:

```bash
podman logs -f splunk    # wait for "Ansible playbook complete"
```

`bring-up.sh` also **creates the `llmlab` index automatically** — compose users must do it once manually (Splunk's HEC does *not* auto-create indexes; events sent to a nonexistent index silently vanish):

```bash
source lab.env
podman exec splunk bash -c "curl -sk 'https://localhost:8089/services/data/indexes' -u \"admin:$SPLUNK_PASSWORD\" --data-urlencode 'name=llmlab' --data-urlencode 'datatype=event' --data-urlencode 'maxTotalDataSizeMB=512' --data-urlencode 'frozenTimePeriodInSecs=7776000'"
```

---

## 5. Validate Everything

```bash
bash validate.sh
```

Expected output — **12 passed, 0 failed**, covering:
1. All 4 containers running
2. Splunk Web :8000 / LiteLLM :4000 / HEC :8088 answering
3. **Negative auth tests** (bad key → 401 at LiteLLM; direct enclave access → 401)
4. Real inference through the whole path (LiteLLM → portproxy → Qwen3)
5. Telemetry actually indexed in Splunk (`litellm:otel` events ≥ 1)
6. Manual HEC round-trip event

---

## 6. Log In & Look Around (manual validation)

**Splunk Web** — `http://localhost:8000`
- User `admin`, password = `SPLUNK_PASSWORD` from `lab.env` (`grep SPLUNK_PASSWORD ~/llmlab/lab.env`)
- First search to run:
  ```spl
  index=llmlab sourcetype=litellm:otel
  ```
  You'll see `raw_gen_ai_request` spans: `trace_id`, full `input.messages` (the prompt), `llm.openai.choices` (the model's response incl. reasoning), timing, cost, status.

**LiteLLM Admin UI** — `http://localhost:4000/ui`
- Key = `MASTER_KEY` from `lab.env`
- Shows virtual keys, per-key spend, model routing

**Quick CLI probes:**
```bash
source ~/llmlab/lab.env
# Inference through the gateway (uses the enclave):
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"Reply with exactly: HOP-OK"}],"max_tokens":400}'
# Registered models:
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $MASTER_KEY"
# Unauthorized direct-to-enclave (the detection target — must be 401):
curl -s -o /dev/null -w "%{http_code}\n" http://172.27.176.1:18434/v1/models
```

> Note: Qwen3 is a **reasoning model** — keep `max_tokens ≥ 300` or it burns the budget on chain-of-thought and returns empty `content`.

---

## 7. Detection Engineering (SPL over `index=llmlab`)

All detections query `index=llmlab sourcetype=litellm:otel`. Field extraction tip: the events are single-line JSON — use `spath` or `| rex` to pull fields, or index-time `props.conf` if you want them first-class.

| Detection | SPL sketch |
|---|---|
| **Secret in prompt** | `index=llmlab sourcetype=litellm:otel input.messages="*AKIA*"` (pattern: `AKIA[0-9A-Z]{16}`) |
| **Auth-failure spike** | `index=llmlab status.code=STATUS_CODE_ERROR \| timechart span=5m count` — bucket by key |
| **Budget exhaustion** | LiteLLM logs budget-rejected requests → failure_callback spans |
| **Direct-to-upstream attempt** | Any successful call NOT via LiteLLM (compare enclave access logs vs gateway spans) |
| **Data exfil volume** | `stats sum(usage.completion_tokens) by key` over time — outlier detection |

Schedule these as **alerting searches** in Splunk (works on the trial / Developer license; the free license's alerting is disabled but manual searches still run).

---

## 8. Licensing Plan (all $0)

| Phase | License | Why |
|---|---|---|
| Now | **Enterprise trial** (docker image default) | Full features incl. scheduled alerts |
| Request today | **Developer license** (dev.splunk.com/enterprise/dev_license, ~2–3 days) | 10GB/day, 6-month renewable, non-prod — alerting continues |
| After trial | **Splunk Free** (`SPLUNK_LICENSE_URI=Free`) | Never expires; 500MB/day (lab uses ~nothing); alerting disabled, manual searches still work |

To drop in the Developer license when it arrives:
```yaml
# add to the splunk service in compose.yaml / bring-up.sh:
- SPLUNK_LICENSE_URI=/opt/splunk/etc/licenses/splunk.lic
# plus volume-mount the .lic file
```

---

## 9. Roadmap (not yet done — do these next session)

1. **Register the virtual keys** — `USER_KEY` and `BUDGET_KEY` exist in `lab.env` but aren't yet registered in LiteLLM's DB. Via the `/ui` or `POST /key/generate`. Give `BUDGET_KEY` a tiny `max_budget` for the exhaustion test.
2. **Point Hermes at the gateway** — `hermes config set model.provider custom`, `model.base_url http://localhost:4000/v1`, key via `~/.hermes/.env`. This makes *your own agent traffic* the monitored workload.
3. **Trip the detections on purpose** — bad-key loop (401 spike), budget-exhaustion loop, decoy `AKIA...` in a prompt (stays local — that's why the enclave is the primary upstream).
4. **Save the SPL detections as scheduled alerts** and test alert firing in the trial window.

---

## 10. Teardown / Reset (when YOU choose)

```bash
cd ~/llmlab
bash bring-up.sh --fresh   # full clean rebuild (keeps lab.env secrets)
# or:
podman compose -f compose.yaml down          # stops & removes containers
podman compose -f compose.yaml up -d         # back up
```

**Persistence caveat (verified as-built):** Splunk's data (index, users, the `llmlab` index
definition) lives **inside the splunk container's writable layer** — no named volume is
mounted, so `podman rm splunk` / `down` **loses indexed data** and the index must be
re-created (bring-up.sh does it automatically; compose users re-run the command in §4).
If you want durability across rebuilds, add this to the splunk service in BOTH
compose.yaml and bring-up.sh **before first deployment** on a fresh machine:
```yaml
    volumes:
      - splunk-data:/opt/splunk/etc
# ...and at file end:
volumes:
  splunk-data: {}
```

The **llama.cpp enclave and Hermes are untouched** by any teardown — they're managed by the Hermes desktop backend, not this lab.

---

*Generated 2026-11-19, re-validated same evening · Lab state: 4 containers healthy, validate.sh 12/12 PASS (twice), 61+ litellm:otel events indexed, compose config validates clean.*
