"""Create a brain from km's templates. km itself is not copied in: the brain pins a km release by
its commit (see km.pins) and runs `km` from there. The release is this km's own, or --pin VERSION.

  km init DIR --initials XX [--folder DIR=PURPOSE ...]
      A personal brain: CONVENTIONS.md, CLAUDE.md (kept if present), inbox/, schema.local.yaml,
      the pre-commit hook and a .gitattributes for LF (kept if present). Refuses a repo that already
      has a CONVENTIONS.md.

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

import yaml

from km import KM_REF
from km.paths import TEMPLATES, git, write_text
from km.pins import ITEM, resolve

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
    "team/main-guard.yml": ".github/workflows/main-guard.yml",
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


def _repos(config: str) -> list | None:
    """The `repos:` list of a pre-commit config, or None when the config does not parse as one."""
    try:
        d = yaml.safe_load(config)
    except yaml.YAMLError:
        return None
    repos = d.get("repos", []) if isinstance(d, dict) else None
    return repos if isinstance(repos, list) else None


def guards_main(config: str) -> bool:
    """Whether a pre-commit config has a no-commit-to-branch hook that covers main (with no branch
    argument the hook guards main and master)."""
    for r in _repos(config) or []:
        for h in (r.get("hooks") or []) if isinstance(r, dict) else []:
            if not isinstance(h, dict) or h.get("id") != "no-commit-to-branch":
                continue
            args, branches = [str(a) for a in h.get("args") or []], []
            for i, a in enumerate(args):
                if a in ("--branch", "-b") and i + 1 < len(args):
                    branches.append(args[i + 1])
                elif a.startswith("--branch="):
                    branches.append(a.split("=", 1)[1])
            if not branches or "main" in branches:
                return True
    return False


def with_main_hook(config: str) -> str | None:
    """The pre-commit config with the team hook that refuses a commit on main added at the end of its
    `repos:` list, at the list's own indent; unchanged when a hook already guards main. None when the
    hook cannot be added safely (a config that does not parse, or a layout this edit does not
    handle): the result must parse to the same config with exactly that hook more."""
    before = _repos(config)
    if before is None:
        return None
    if guards_main(config):
        return config
    lines = config.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    top = next((i for i, ln in enumerate(lines) if ln.startswith("repos:")), None)
    if top is None:
        lines, top = [*lines, "repos:\n"], len(lines)
    end, pad = len(lines), None          # the repos block ends at the next top-level key
    for i in range(top + 1, len(lines)):
        ln = lines[i]
        if pad is None and (m := ITEM.match(ln)):
            pad = m.group(1)
        if ln.strip() and not ln[0].isspace() and not ln.startswith(("#", "-")):
            end = i
            break
    while end > top + 1 and not lines[end - 1].strip():
        end -= 1                         # keep blank lines before the next key after the block
    hook = template("team/no-commit-hook.yaml", {})
    block = "".join((pad if pad is not None else "  ") + ln if ln.strip() else ln for ln in hook.splitlines(keepends=True))
    out = "".join(lines[:end]) + block + "".join(lines[end:])
    after, rest = _repos(out), lambda t: {k: v for k, v in (yaml.safe_load(t) or {}).items() if k != "repos"}
    if after != [*before, *yaml.safe_load(hook)] or rest(out) != rest(config):
        return None
    return out


def ensure_lf(repo: Path) -> str | None:
    """Have git keep the brain's text files LF on every platform: km's .gitattributes where there is
    none. One the brain has stays as it is; when git says it sets no line ending, a note says so.
    Returns that note, or None."""
    path = repo / ".gitattributes"
    if not path.exists():
        write_text(path, template("gitattributes.template", {}))
        return ("added .gitattributes: text files in LF on every platform "
                "(`git add --renormalize .` if the repo already holds CRLF files)")
    res = git("check-attr", "eol", "--", "any.md", cwd=repo)
    if res.returncode == 0 and res.stdout.strip().endswith(": unspecified"):
        return "kept .gitattributes, which sets no line ending: add `* text=auto eol=lf` for LF on every platform"
    return None


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
    hooked = with_main_hook(out[".pre-commit-config.yaml"])
    assert hooked, "km's own pre-commit template takes the main hook"
    out[".pre-commit-config.yaml"] = hooked
    for n, p in folders:
        out[f"{n}/_index.md"] = template("team/_index.folder.template.md", {**values, "<folder>": n, "<purpose>": p})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(prog="km init", description="Create a brain from km's templates.")
    ap.add_argument("repo")
    ap.add_argument("--team", action="store_true", help="a shared team brain (CI, served bundle, one merger)")
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
        write_text(repo / dst, text)
    print(f"km init: {'team' if a.team else 'personal'} brain in {repo}, pinned to km {a.pin}")
    if note := ensure_lf(repo):
        print(f"km init: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
