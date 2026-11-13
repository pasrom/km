"""Fail when e2e/ names a GitHub organisation, account or repository: `check_names.py [PATH...]`.

The e2e driver is public and runs against a private sandbox whose names come from the environment
(e2e/README.md). The only repository it may name literally is km's own, `pasrom/km`. A slug is looked
for where GitHub names one: after `github.com/` (or `github.com:`), after an API path's `repos/`, as
the owner after `orgs/`, `organizations/`, `users/` and in an owner-only `github.com/` link, after
`uses:`, `--repo`, `-R`, `km ready` and `gh repo <verb>`. A placeholder (`{org}`, `$ORG`, `<org>`)
starts with a character no login has, so it never matches.

`KM_E2E_DENY_FILE`, when set, names a file kept outside the repository with one term per line (`#`
starts a comment): any of them found in any case, not inside a longer word (`acme` counts in
`acme-team`, not in `acmeco`), fails too. That is where the real names belong, never in this file.

Exit 0 when nothing is found, 1 with one line per finding.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ALLOWED = {("pasrom", "km")}
NAME = r"[A-Za-z0-9][A-Za-z0-9_.-]*"
SLUG = re.compile(rf"(?:github\.com[/:]|\brepos/|\buses:\s*|--repo[= ]\s*|(?<![\w-])-R\s+"
                  rf"|\bkm\s+ready\s+|\bgh\s+repo\s+\w+\s+)({NAME})/({NAME})")
OWNER = re.compile(rf"(?:\b(?:orgs|organizations|users)/|github\.com/)({NAME})(?![\w.-]*/)")
HERE = Path(__file__).resolve().parent


def deny_terms() -> list[str]:
    path = os.environ.get("KM_E2E_DENY_FILE")
    if not path:
        return []
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    return [t for ln in lines if (t := ln.split("#", 1)[0].strip())]


def findings(text: str, deny: list[str]) -> list[str]:
    out = []
    for m in SLUG.finditer(text):
        owner, repo = m.group(1), re.sub(r"(\.git)?([@#].*)?$", "", m.group(2))
        if (owner, repo) not in ALLOWED:
            out.append(f"names the repository {owner}/{repo}")
    out += [f"names the account {m.group(1)}" for m in OWNER.finditer(text) if m.group(1) != "pasrom"]
    for term in deny:
        # a term inside a longer word does not count, one joined by a hyphen does (acme in acme-team)
        if re.search(rf"(?<![A-Za-z0-9]){re.escape(term)}(?![A-Za-z0-9])", text, re.IGNORECASE):
            out.append("names a term of the deny list")   # the term itself is not printed
    return out


def files(paths: list[str]) -> list[Path]:
    out = []
    for p in map(Path, paths or [str(HERE)]):
        out += sorted(f for f in p.rglob("*") if f.is_file() and "__pycache__" not in f.parts) if p.is_dir() else [p]
    return out


def main(argv: list[str]) -> int:
    deny, bad = deny_terms(), 0
    for f in files(argv):
        try:
            text = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = f.read_bytes().decode("latin-1")
        for i, line in enumerate(text.splitlines(), 1):
            for what in findings(line, deny):
                print(f"{f}:{i}: {what}")
                bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
