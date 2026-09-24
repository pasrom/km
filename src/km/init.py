"""Create a brain from km's templates. km itself is not copied in: the brain pins a km release by
its commit (see km.pins) and runs `km` from there. The release is this km's own, or --pin VERSION.

  km init DIR --initials XX [--folder DIR=PURPOSE ...]
      A personal brain: CONVENTIONS.md, CLAUDE.md (kept if present), inbox/, schema.local.yaml and
      the pre-commit hook. Refuses a repo that already has a CONVENTIONS.md.

  km init DIR --team --name NAME --desc TEXT --initials XX --folder DIR=PURPOSE [--folder ...]
              [--rule TEXT ...] [--profile SLUG]
      A team brain: also the root and folder indexes, README, .gitignore, the two workflows and a
      Dependabot config. Refuses to run if any file it would write already exists.

Both render and check everything before writing anything, and refuse a release whose commit
cannot be looked up (not released yet, or no network). Files only: git add, the first
`km gen-index` and the commit are left to the caller.
"""
from __future__ import annotations

import argparse
import datetime
import re
import sys
from pathlib import Path

from km import KM_REF
from km.paths import TEMPLATES
from km.pins import resolve

PERSONAL = {                          # template -> path in the brain (repo-owned after init)
    "CONVENTIONS.template.md": "CONVENTIONS.md",
    "CLAUDE.template.md": "CLAUDE.md",
    "schema.local.template.yaml": "schema.local.yaml",
    "_index.inbox.template.md": "inbox/_index.md",
    "pre-commit-config.template.yaml": ".pre-commit-config.yaml",
}
TEAM = {
    "team/CONVENTIONS.team.template.md": "CONVENTIONS.md",
    "team/CLAUDE.team.template.md": "CLAUDE.md",
    "team/README.team.template.md": "README.md",
    "team/schema.local.team.template.yaml": "schema.local.yaml",
    "team/_index.root.template.md": "_index.md",
    "team/gitignore.template": ".gitignore",
    "team/ci.yml": ".github/workflows/ci.yml",
    "team/staleness.yml": ".github/workflows/staleness.yml",
    "team/dependabot.yml": ".github/dependabot.yml",
    "pre-commit-config.template.yaml": ".pre-commit-config.yaml",
}
PLACEHOLDERS = ("<BRAIN>", "<TEAM>", "<MAINTAINER>", "<profile>", "<date>", "<FOLDER_ROWS>",
                "<PLACEMENT_RULES>", "<folder>", "<purpose>", "<KM_SHA>", "<KM_VERSION>")


def pin_values(version: str) -> dict[str, str]:
    """The placeholders for the km release a brain pins: its version and the commit it tags."""
    sha = resolve(version)
    if not sha:
        sys.exit(f"km {version} has no release commit to pin (not released yet, or the km repository cannot "
                 f"be reached): pass --pin <released version>")
    return {"<KM_SHA>": sha, "<KM_VERSION>": version}


def template(name: str, values: dict[str, str]) -> str:
    """A template from km's templates/ with `values` filled in."""
    text = (TEMPLATES / name).read_text(encoding="utf-8")
    for k, v in values.items():
        text = text.replace(k, v)
    return text


def _plain(label: str, value: str) -> str:
    """A value that lands inside a double-quoted YAML string or a table cell must stay one clean line."""
    value = value.strip()
    if not value or re.search(r'["\\|\n]', value):
        sys.exit(f"{label} {value!r}: must be non-empty, one line, without \" \\ or |")
    return value


def _folders(specs: list[str]) -> list[tuple[str, str]]:
    folders = []
    for spec in specs:
        name, sep, purpose = spec.partition("=")
        name = name.strip().strip("/")
        if not sep or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
            sys.exit(f"--folder {spec!r}: expected DIR=PURPOSE with DIR a top-level kebab-case folder name")
        folders.append((name, _plain("--folder purpose", purpose)))
    return folders


def render(a: argparse.Namespace) -> dict[str, str]:
    """Every file init writes, keyed by its path in the brain."""
    folders = _folders(a.folder or [])
    values = {"<MAINTAINER>": _plain("--initials", a.initials), "<date>": datetime.date.today().isoformat(),
              "<FOLDER_ROWS>": "\n".join(f"| `{n}/` | {p} |" for n, p in folders), **pin_values(a.pin)}
    if not a.team:
        return {dst: template(tpl, values) for tpl, dst in PERSONAL.items()}
    if not (a.name and a.desc and folders):
        sys.exit("km init --team needs --name, --desc and at least one --folder")
    rules = a.rule or [f"{p}: `{n}/`" for n, p in folders]
    values |= {
        "<BRAIN>": _plain("--name", a.name), "<TEAM>": _plain("--desc", a.desc),
        "<profile>": a.profile or a.name.lower(),
        "<PLACEMENT_RULES>": "\n".join(f"- {r}" for r in rules),
    }
    out = {dst: template(tpl, values) for tpl, dst in TEAM.items()}
    for n, p in folders:
        out[f"{n}/_index.md"] = template("team/_index.folder.template.md", {**values, "<folder>": n, "<purpose>": p})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(prog="km init", description="Create a brain from km's templates.")
    ap.add_argument("repo")
    ap.add_argument("--team", action="store_true", help="a shared team brain (CI, served bundle, one writer)")
    ap.add_argument("--initials", required=True, help="the owner's or maintainer's initials")
    ap.add_argument("--folder", action="append", metavar="DIR=PURPOSE")
    ap.add_argument("--name", help="team brain: its name, e.g. QA-Brain")
    ap.add_argument("--desc", help="team brain: one line on whose brain it is, e.g. 'the QA team'")
    ap.add_argument("--rule", action="append", metavar="TEXT", help="team brain: a placement rule")
    ap.add_argument("--profile", help="team brain: meta.profile slug (default: the lowercased name)")
    ap.add_argument("--pin", metavar="VERSION", default=KM_REF, help="the km release to pin (default: this km, %(default)s)")
    a = ap.parse_args()
    repo = Path(a.repo)
    rendered = render(a)
    if not a.team and (repo / "CLAUDE.md").exists():
        del rendered["CLAUDE.md"]                 # a personal brain keeps a CLAUDE.md it already has
    existing = [p for p in rendered if (repo / p).exists()]
    if existing:
        sys.exit(f"{repo} already has {', '.join(existing)}: refusing to overwrite (start from an empty repo)")
    left = sorted({f"{dst}: {ph}" for dst, text in rendered.items() for ph in PLACEHOLDERS if ph in text})
    if left:                              # check everything before writing anything
        sys.exit(f"placeholder(s) left after rendering: {', '.join(left)}")
    for dst, text in rendered.items():
        (repo / dst).parent.mkdir(parents=True, exist_ok=True)
        (repo / dst).write_text(text, encoding="utf-8")
    print(f"km init: {'team' if a.team else 'personal'} brain in {repo}, pinned to km {a.pin}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
