# LLMLab — Control Every AI Call in Your Company

**One gateway. One set of records. Every AI request accounted for.**

LLMLab is a working miniature of an "AI firewall." You (or a tool) ask for AI the normal way — but pointed at the gateway instead of at OpenAI/OpenRouter directly. The gateway checks your personal API key, enforces your budget and which models you're allowed, forwards the request to the real AI, and sends a complete record of the exchange (prompt, response, tokens, cost, who asked) to Splunk. Splunk is where you search history ("show me everything user X asked last week"), set alerts ("page me if someone's key sends 100 requests in 5 minutes"), and prove compliance ("here is the audit trail").

Think airport security for AI: everyone needs a ticket (key), everyone goes through one checkpoint (gateway), and there's a camera record of everyone who passed through (Splunk).

---

## What's Running Under the Hood

| Piece | What it is | Why you care |
|---|---|---|
| **LiteLLM** (port 4000) | The checkpoint/gateway | The *only* door to AI. Hands out personal keys, enforces budgets, blocks unauthorized models. This is where you get control. |
| **Postgres** (port 5432, internal) | The key registry database | Remembers every key, who owns it, what they spent. The "list of ticket holders." |
| **Splunk** (port 8000) | The recording & alerting system | Every prompt and response, searchable. Where alerts live. Your evidence locker. |
| **OTel collector** (port 4318, internal) | The camera feed pipe | Moves the records from the gateway to Splunk automatically. |
| **Your AI provider** | OpenAI/OpenRouter/whatever | The actual brain. The gateway decides who talks to it. |

**Nothing is exposed to the internet or your LAN.** Splunk and the gateway answer only on this PC (`localhost`). Anyone scanning your network finds nothing.

---

## What You Need

- One **Windows 11** PC with **16 GB RAM** (that's it — this was built on a standard gaming desktop)
- **[Podman Desktop](https://podman-desktop.io/)** installed and its machine started (this is what runs the four pieces above in isolation)
- Internet for the one-time download of the four container images (~3 GB)
- About **10 minutes**

No cloud accounts. No subscriptions. No Splunk license purchase (the included trial works, and a free permanent license exists — see [Licensing](#licensing-free-forever)).

---

## Deploy It

### The Easy Way (one command)

```bash
cd ~/llmlab
bash bring-up.sh
```

That single script: creates an isolated network → starts the database → starts Splunk (takes 2–4 minutes on first boot) → starts the collector → starts the gateway → creates the Splunk "recording folder" (index) → waits until everything responds → prints your login info.

First run downloads images (~3 GB, a few minutes). Every run after that is ~30 seconds.

Add `--fresh` to wipe everything and start over clean: `bash bring-up.sh --fresh`

### The Structured Way (if you prefer declarative config)

```bash
cd ~/llmlab
set -a; source ./lab.env; set +a          # load secrets into environment
export LLAMA_KEY=$(cat .llama_key)        # (only if using a local model)
export OPENROUTER_KEY=$(cat .openrouter_key)
podman compose -f compose.yaml up -d
```

Then create the Splunk index once (the compose file doesn't do this automatically):

```bash
source lab.env
podman exec splunk bash -c "curl -sk 'https://localhost:8089/services/data/indexes' -u \"admin:$SPLUNK_PASSWORD\" --data-urlencode 'name=llmlab' --data-urlencode 'datatype=event' --data-urlencode 'maxTotalDataSizeMB=512'"
```

> **Pick one method and stick with it** — running both on the same names causes container-name conflicts. To switch: `podman rm -f splunk litellm postgres otelcol`, then use the other method.

---

## Prove It Works

```bash
bash validate.sh
```

Runs 12 checks: containers alive → endpoints responding → wrong keys get rejected → a real AI call works end to end → the record actually landed in Splunk. Prints `12 passed, 0 failed` when healthy.

Then log in and look around:

| What | Where | Login |
|---|---|---|
| **Splunk** (the record system) | http://localhost:8000 | `admin` / password in `lab.env` |
| **LiteLLM admin panel** (manage keys) | http://localhost:4000/ui | the `MASTER_KEY` from `lab.env` |

First Splunk search to try: `index=llmlab sourcetype=litellm:otel` — you'll see every AI request in full detail.

---

## Day-to-Day Use

**Give someone AI access:** In the LiteLLM panel → Keys → Create Key. Name it after the person, set a monthly budget if you want. Hand them the `sk-...` string. That's their ticket — revoke it any time.

**Make an AI request:** Point any OpenAI-compatible tool at the gateway instead of the provider:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-THE-PERSONAL-KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "your-model", "messages": [{"role": "user", "content": "hello"}]}'
```

**Watch it live:** Splunk → search `index=llmlab` → watch records appear as people use AI.

**Set an alert (example):** Splunk → Alerts → "page me if any key gets 401'd more than 10 times in 5 minutes" — that's someone using a stolen/guessed key.

---

## The Threat Model (Why This Actually Defends You)

Full detail lives in two files — open them in a browser, they're presentation-ready:

- **[llmlab-threat-model-atlas.html](llmlab-threat-model-atlas.html)** — the architecture diagram with MITRE ATLAS attack techniques overlaid on every component, focused on the **top 3 insider risks** for air-gapped IP environments:
  1. **Rogue agents** — a malicious insider deploys an autonomous AI agent that *legitimately* holds tool access. Mitigation: the gateway chokepoint — every agent call needs a key, per-key rate limits, input/output validation, full attribution.
  2. **Poisoned LLM** — malware smuggled across the air gap *inside* a trusted model file. Mitigation: import vetting, model allowlists, change control.
  3. **Poisoned context** — an insider plants malicious instructions in a RAG index or MCP feed, hijacking AI behavior indirectly. Mitigation: treat retrieved content as untrusted input, scan it, allowlist sources.

- **[KEY-ATTRIBUTION-CHEATSHEET.html](KEY-ATTRIBUTION-CHEATSHEET.html)** — the test/validation commands, Splunk search queries for every detection, and each mitigation mapped to formal **NIST SP 800-53 Rev 5 controls** (AC-02, AU-12, SC-05, SI-10, …) for your compliance conversations.

**The pitch in one line:** the same gateway that gives you convenience (one door) gives you compliance evidence (one record) and insider-threat defense (one chokepoint) — features most vendors charge extra for.

---

## Licensing (Free Forever)

| When | What | Why |
|---|---|---|
| Today | Splunk **Enterprise trial** (built into the container) | Full features including scheduled alerts, 60 days |
| This week | Request the free **[Developer license](https://dev.splunk.com/enterprise/dev_license)** | 10 GB/day, renewable every 6 months, alerts keep working |
| Any time | Or switch to **Splunk Free** | Permanent, 500 MB/day (this lab uses almost none), but scheduled alerts disabled — manual search still works |

---

## Fixing Problems

| Symptom | Fix |
|---|---|
| `validate.sh` says a container isn't running | `podman ps -a` to see which; check its logs with `podman logs <name>` |
| Splunk won't load / just spins | First boot takes 2–4 minutes. `podman logs -f splunk` and wait for "Ansible playbook complete" |
| AI calls return 401 | The key you're using isn't registered in the gateway. Check with the `/key/info` command in the cheatsheet, or just create a fresh key in the UI |
| Splunk has no events | The index `llmlab` must exist *before* events arrive — re-run the index-creation command in the Deploy section |
| LiteLLM can't reach the database | Postgres container isn't up, or the password in `DATABASE_URL` doesn't match `SPLUNK_PASSWORD` |
| Everything's broken, start over | `bash bring-up.sh --fresh` (wipes containers, keeps your secrets file) |

---

## Shut It Down / Start Over

```bash
podman compose -f compose.yaml down   # or: podman stop splunk litellm postgres otelcol
```

**Know before you tear down:** Splunk's recorded data lives inside its container. Stopping is fine — it comes back. *Deleting* the container (`rm`) deletes the recordings. If you want them permanent, add a named volume before first deployment (details in [RUNBOOK.md §10](RUNBOOK.md)).

---

## File Map (what's what in this folder)

| File | Read it? | What it is |
|---|---|---|
| **README.md** | **you are here** | The human-friendly overview |
| `RUNBOOK.md` | deep-dive | Original detailed ops runbook (more technical) |
| `KEY-ATTRIBUTION-CHEATSHEET.html` | when validating | Test commands + Splunk queries + NIST mapping |
| `llmlab-threat-model-atlas.html` | for presentations | Threat-model diagram (MITRE ATLAS overlay) |
| `llmlab-architecture.html` | for presentations | Clean architecture diagram (no threats) |
| `bring-up.sh` | run once | One-command deployment script |
| `compose.yaml` | reference | The same deployment as declarative config |
| `validate.sh` | run any time | 12-check health test |
| `lab.env` | 🔴 secrets | Contains every password/key — **never commit, never share** |
| `.llama_key` / `.openrouter_key` | 🔴 secrets | Upstream provider API keys |
| `litellm-config.yaml` | edit to add models | Which AI models the gateway offers |
| `otel-config.yaml` | don't touch | Telemetry plumbing |
| `admin-setup.ps1` | run once (admin) | Windows firewall rules (local-only lab setup) |
| `gen_tokens.py` | one-time | Generated the secrets originally |

---

*Built 2026-11-19 · threat-model extension 2026-11-23 · runs entirely on one Windows PC · zero cost software*
