# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Create a team brain, or refresh the km-owned team files in one. Runs from the km skill directory
against a target repo; it is not copied into brains.

  init <repo> --name NAME --team DESC --initials XX --folder DIR=PURPOSE [--folder ...]
              [--rule TEXT ...] [--profile SLUG]
      Render the team templates into <repo> and copy the km-owned files. Refuses to run if any
      file it would write already exists. Files only: git add, the first gen_index run and the
      commit are left to the caller.

  upgrade <repo>
      For a repo whose schema.local.yaml sets `team_brain: true`: refresh every km-owned file (the
      base schema and scripts too), adding a missing script since they import each other; a
      workflow the repo deleted stays deleted and is reported. Prints what changed.

Run:  python3 <km>/team/km_team.py init|upgrade <repo> ...
"""
from __future__ import annotations

import argparse
import datetime
import filecmp
import re
import shutil
import sys
from pathlib import Path

TEAM = Path(__file__).resolve().parent
KM = TEAM.parent
TEMPLATES = {                         # template in team/ -> path in the brain (repo-owned after init)
    "CONVENTIONS.team.template.md": "CONVENTIONS.md",
    "CLAUDE.team.template.md": "CLAUDE.md",
    "README.team.template.md": "README.md",
    "schema.local.team.template.yaml": "schema.local.yaml",
    "_index.root.template.md": "_index.md",
    "gitignore.template": ".gitignore",
}
BASE = {                              # km-owned files every brain has (source in km/ -> brain path)
    "schema.base.yaml": "schema.base.yaml",
    "validate.py": "scripts/validate.py",
    "km_promote.py": "scripts/km_promote.py",
}
PLACEHOLDERS = ("<BRAIN>", "<TEAM>", "<MAINTAINER>", "<profile>", "<date>", "<FOLDER_ROWS>",
                "<PLACEMENT_RULES>", "<folder>", "<purpose>")


def owned() -> list[tuple[Path, str, bool]]:
    """Every km-owned file of a team brain: (source, brain path, add it on upgrade when missing).
    Scripts import each other, so a missing one is added; a workflow the team deleted stays deleted."""
    return ([(KM / s, d, True) for s, d in BASE.items()]
            + [(p, f"scripts/{p.name}", True) for p in sorted((TEAM / "scripts").glob("*.py"))]
            + [(p, f".github/workflows/{p.name}", False) for p in sorted((TEAM / "workflows").glob("*.yml"))])


def _fill(text: str, values: dict[str, str]) -> str:
    for k, v in values.items():
        text = text.replace(k, v)
    return text


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _copy(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)


def _plain(label: str, value: str) -> str:
    """A value that lands inside a double-quoted YAML string or a table cell must stay one clean line."""
    value = value.strip()
    if not value or re.search(r'["\\|\n]', value):
        sys.exit(f"{label} {value!r}: must be non-empty, one line, without \" \\ or |")
    return value


def init(a: argparse.Namespace) -> int:
    repo = Path(a.repo)
    folders: list[tuple[str, str]] = []
    for spec in a.folder:
        name, sep, purpose = spec.partition("=")
        name = name.strip().strip("/")
        if not sep or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
            sys.exit(f"--folder {spec!r}: expected DIR=PURPOSE with DIR a top-level kebab-case folder name")
        folders.append((name, _plain("--folder purpose", purpose)))
    targets = [*TEMPLATES.values(), *(f"{n}/_index.md" for n, _ in folders), ".pre-commit-config.yaml",
               *(d for _, d, _ in owned())]
    existing = [t for t in targets if (repo / t).exists()]
    if existing:
        sys.exit(f"{repo} already has {', '.join(existing)}: refusing to overwrite (start from an empty repo)")
    rules = a.rule or [f"{p}: `{n}/`" for n, p in folders]
    values = {
        "<BRAIN>": _plain("--name", a.name), "<TEAM>": _plain("--team", a.team),
        "<MAINTAINER>": _plain("--initials", a.initials),
        "<profile>": a.profile or a.name.lower(), "<date>": datetime.date.today().isoformat(),
        "<FOLDER_ROWS>": "\n".join(f"| `{n}/` | {p} |" for n, p in folders),
        "<PLACEMENT_RULES>": "\n".join(f"- {r}" for r in rules),
    }
    rendered = {dst: _fill((TEAM / tpl).read_text(encoding="utf-8"), values) for tpl, dst in TEMPLATES.items()}
    folder_tpl = (TEAM / "_index.folder.template.md").read_text(encoding="utf-8")
    for n, p in folders:
        rendered[f"{n}/_index.md"] = _fill(folder_tpl, {**values, "<folder>": n, "<purpose>": p})
    left = sorted({f"{dst}: {ph}" for dst, text in rendered.items() for ph in PLACEHOLDERS if ph in text})
    if left:                          # check everything before writing anything
        sys.exit(f"placeholder(s) left after rendering: {', '.join(left)}")
    for dst, text in rendered.items():
        _write(repo / dst, text)
    _copy(KM / ".pre-commit-config.template.yaml", repo / ".pre-commit-config.yaml")
    for src, dst, _ in owned():
        _copy(src, repo / dst)
    print(f"km_team: initialized {a.name} in {repo} ({len(folders)} folders)")
    return 0


def upgrade(a: argparse.Namespace) -> int:
    import yaml                       # only the upgrade needs it, so init runs on a bare python3
    repo = Path(a.repo)
    local = repo / "schema.local.yaml"
    cfg = yaml.safe_load(local.read_text(encoding="utf-8")) if local.is_file() else None
    if not isinstance(cfg, dict) or cfg.get("team_brain") is not True:
        sys.exit(f"{local}: no `team_brain: true`, not a team brain")
    changed, added, skipped = [], [], []
    for src, dst, add_missing in owned():
        target = repo / dst
        if target.exists():
            if filecmp.cmp(src, target, shallow=False):
                continue
            changed.append(dst)
        elif add_missing:
            added.append(dst)
        else:
            skipped.append(dst)
            continue
        _copy(src, target)
    for label, items in (("updated", changed), ("added", added), ("not present, left out", skipped)):
        for i in items:
            print(f"km_team: {label}: {i}")
    if not (changed or added):
        print("km_team: team files up to date")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Create a team brain, or refresh its km-owned team files.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("init")
    i.add_argument("repo")
    i.add_argument("--name", required=True)
    i.add_argument("--team", required=True)
    i.add_argument("--initials", required=True)
    i.add_argument("--folder", action="append", required=True, metavar="DIR=PURPOSE")
    i.add_argument("--rule", action="append", metavar="TEXT")
    i.add_argument("--profile")
    u = sub.add_parser("upgrade")
    u.add_argument("repo")
    a = ap.parse_args()
    return init(a) if a.cmd == "init" else upgrade(a)


if __name__ == "__main__":
    sys.exit(main())
