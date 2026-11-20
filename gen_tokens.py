import os, uuid, pathlib
home = pathlib.Path.home()
lab = home / "llmlab"
lab.mkdir(exist_ok=True)
envf = lab / "lab.env"
if not envf.exists():
    hec = str(uuid.uuid4())
    master = "sk-litellm-" + uuid.uuid4().hex[:24]
    envf.write_text(
        f"HEC_TOKEN={hec}\nMASTER_KEY={master}\n"
        f"SPLUNK_PASSWORD={uuid.uuid4().hex[:16]}\n"
        f"USER_KEY=sk-user-" + uuid.uuid4().hex[:24] + "\n"
        f"BUDGET_KEY=sk-budget-" + uuid.uuid4().hex[:24] + "\n",
        encoding="ascii",
    )
# verify
vals = dict(line.split("=", 1) for line in envf.read_text().strip().splitlines())
print({k: (v[:8] + "..." if k != "HEC_TOKEN" else v) for k, v in vals.items()})
