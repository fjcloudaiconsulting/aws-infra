#!/usr/bin/env python3
"""Fail if any Secret under the given directory is not SOPS-encrypted (INFRA-23).

Rules: a Secret lives in its own *.secret.yaml file, that file carries SOPS
metadata with a MAC, and every data/stringData value is an ENC[...] string
(or empty, which sops leaves as is). Kustomize secretGenerator is not allowed.
Stdlib only, line-based: it understands the layout `sops encrypt` writes.
"""
import pathlib
import re
import sys

# YAML (quoted, commented, or nested in a List) or JSON.
KIND_SECRET = re.compile(r"""^\s*kind:\s*["']?Secret["']?\s*(#.*)?$|"kind"\s*:\s*"Secret\"""", re.M)
TOP_KEY = re.compile(r"^([^\s#][^:]*):\s*(.*)$")
ENTRY = re.compile(r"^\s+([^:#\s][^:]*):\s*(.*)$")


def problems(path):
    text = path.read_text()
    out = []
    if re.search(r"^\s*secretGenerator:", text, re.M):
        out.append("secretGenerator writes plaintext; use a *.secret.yaml file")
    if not path.name.lower().endswith(".secret.yaml"):
        if KIND_SECRET.search(text):
            out.append("Secret outside a *.secret.yaml file; move it and run `sops encrypt -i`")
        return out
    if not re.search(r"^sops:", text, re.M) or not re.search(r"^\s+mac: ENC\[", text, re.M):
        out.append("no SOPS metadata; run `sops encrypt -i`")
    block = None
    for line in text.splitlines():
        top = TOP_KEY.match(line)
        if top:
            block = top.group(1) if top.group(1) in ("data", "stringData") else None
            if block and top.group(2) and not top.group(2).startswith("#"):
                out.append(f"{block} is not encrypted (flow style)")
            continue
        m = ENTRY.match(line) if block else None
        if m and not m.group(2).startswith("ENC[") and m.group(2) not in ('""', "''"):
            out.append(f"{block}.{m.group(1)} is not encrypted")
    return out


def main(root):
    failed = False
    files = sorted(
        p for p in pathlib.Path(root).rglob("*") if p.suffix.lower() in (".yaml", ".yml", ".json")
    )
    for path in files:
        for p in problems(path):
            print(f"::error file={path}::{path}: {p}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "clusters"))
