#!/usr/bin/env python3
"""PR-time fences for terraform/tbd-backups, ported from tbd's test_backup_offhost.py (F3, F5)
when the stack moved here (INFRA-18). Stdlib only; exits 1 with every failure listed."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STACK = ROOT / "terraform/tbd-backups"
TRUST = ROOT / "aws/bootstrap/tfc-backups-trust.json"
failures = []


def check(ok, msg):
    if not ok:
        failures.append(msg)


def actions(doc):
    out = set()
    for stmt in doc["Statement"]:
        a = stmt["Action"]
        out.update(a if isinstance(a, list) else [a])
    return out


# F3. The uploader is put-only and the probe list-only, both directions. Effect and Resource are
# as load-bearing as Action: a mutant that flipped Effect to Deny and widened Resource to
# arn:aws:s3:::*/* kept the action set identical.
uploader = json.loads((STACK / "policies/backup-uploader.json").read_text())
# The probe template injects its prefix list as raw JSON; stand in an empty list so it parses.
probe = json.loads((STACK / "policies/backup-probe.json").read_text().replace("${prefixes}", "[]"))
check(actions(uploader) == {"s3:PutObject", "kms:GenerateDataKey", "kms:Encrypt", "kms:DescribeKey"},
      f"uploader policy actions are {sorted(actions(uploader))}; it must stay exactly put + encrypt "
      "(read access would let a compromised droplet harvest every historical dump)")
check(actions(probe) == {"s3:ListBucket"}, f"probe policy actions are {sorted(actions(probe))}; must be exactly s3:ListBucket")
# Exact resources: a substring test would pass arn:aws:s3:::*${bucket}*.
SCOPED = {"arn:aws:s3:::${bucket}/${prefix}/*", "${kms_key_arn}", "arn:aws:s3:::${bucket}"}
for name, doc in (("uploader", uploader), ("probe", probe)):
    for stmt in doc["Statement"]:
        check(stmt["Effect"] == "Allow", f"{name} policy has a {stmt['Effect']} statement; these are grant policies")
        res = stmt["Resource"]
        for r in res if isinstance(res, list) else [res]:
            check(r in SCOPED, f"{name} policy grants on {r!r}, not exactly the bucket, prefix or key")
# StringEquals against an absent header fails, so the uploader must send both SSE headers; the
# uploader-side half of this fence stays in tbd with the script. Every PutObject statement: a second
# unconditioned one would otherwise allow unencrypted writes.
puts = [s for s in uploader["Statement"] if "s3:PutObject" in str(s["Action"])]
check(puts, "uploader policy has no PutObject statement")
for put in puts:
    cond = put.get("Condition", {}).get("StringEquals", {})
    check(cond.get("s3:x-amz-server-side-encryption") == "aws:kms", "an uploader PutObject statement does not require SSE aws:kms")
    check(any("kms-key-id" in k for k in cond), "an uploader PutObject statement does not pin the KMS key id")

# F5. TBD-372: the role trust is managed BY the workspace it authorizes, so a rename applied with
# the trust unchanged locks the workspace out of its own fix. The declared workspace must be
# authorized by ANY statement (not ALL: the safe rename widens to both names first), and a
# statement must not glob the declared name.
m = re.search(r'workspaces\s*\{[^}]*name\s*=\s*"([^"]+)"', (STACK / "versions.tf").read_text(), re.DOTALL)
check(m, "could not find the workspace name in versions.tf")
if m:
    ws = m.group(1)
    # main.tf builds the trust sub from var.tfc_workspace_name, so the plan-time precondition there
    # cannot see a rename in versions.tf alone; pin the two together here.
    v = re.search(r'variable\s+"tfc_workspace_name"\s*\{.*?default\s*=\s*"([^"]+)"',
                  (STACK / "variables.tf").read_text(), re.DOTALL)
    check(v and v.group(1) == ws, f"var tfc_workspace_name default {v and v.group(1)!r} != versions.tf workspace {ws!r}")
    trust = json.loads(TRUST.read_text())
    subs = [v for st in trust["Statement"] for c in st.get("Condition", {}).values()
            for k, v in c.items() if k.endswith(":sub")]
    subs = [s for v in subs for s in (v if isinstance(v, list) else [v])]
    check(any(f"workspace:{ws}:" in s for s in subs),
          f"versions.tf declares workspace {ws!r} but no trust statement authorizes it (subs: {subs}). "
          "Widen the trust, apply, rename, then narrow.")
    for s in subs:
        seg = re.search(r"workspace:([^:]+):", s)
        if seg and "*" in seg.group(1):
            prefix = seg.group(1).split("*")[0]
            check(not (prefix and ws.startswith(prefix)),
                  f"trust workspace segment {seg.group(1)!r} globs the declared workspace {ws!r}; name it exactly")

for f in failures:
    print(f"::error::{f}")
print("tbd-backups fences:", "FAIL" if failures else "ok")
sys.exit(1 if failures else 0)
