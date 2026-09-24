"""The km version a brain pins, in its workflows and its pre-commit config, always by commit:

    uses: pasrom/km@<sha> # v1.2.3                 (workflows; Dependabot's format)
    rev: <sha>  # frozen: v1.2.3                   (pre-commit; `pre-commit autoupdate --freeze`)

A commit cannot be moved the way a tag can, so a brain keeps running the km it was reviewed with even
if a tag is later pointed elsewhere. The comment carries the version. `km init` and `km upgrade` write
these pins; every other command compares them with the km that is running.
"""
from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

KM_REPO = "https://github.com/pasrom/km"
SHA = re.compile(r"[0-9a-f]{40}")
VERSION = r"v\d[\w.\-]*"
PIN = re.compile(rf"(pasrom/km@)([\w.\-]+)(?:[ \t]*#[ \t]*({VERSION}))?")
USES = re.compile(r"(?m)^\s*-?\s*uses:\s*['\"]?([\w.\-]+/[\w.\-/]+)@([\w.\-]+)")   # any action a workflow runs
# In .pre-commit-config.yaml: a repo entry (a list item at the indent of the first one), the km repo
# line inside it (quoted or not, with or without .git), and its rev line wherever it sits in the entry.
ITEM = re.compile(r"^(\s*)-\s")
KM_REPO_LINE = re.compile(rf"^\s*-?\s*repo:\s*['\"]?{re.escape(KM_REPO)}(?:\.git)?/?['\"]?\s*(?:#.*)?$")
REV_LINE = re.compile(rf"^(\s*-?\s*rev:\s*)(['\"]?)([\w.\-]+)\2(?:[ \t]*#[ \t]*(?:frozen:[ \t]*)?({VERSION}))?.*$")


def repo_url() -> str:
    """Where km releases are looked up and fetched from. KM_REPO_URL overrides it (tests use a local
    repository); whoever controls the environment is trusted to run code anyway."""
    return os.environ.get("KM_REPO_URL", KM_REPO)


def uses_ref(sha: str, version: str) -> str:
    return f"{sha} # {version}"


def hook_rev(sha: str, version: str) -> str:
    return f"{sha}  # frozen: {version}"


@dataclass(frozen=True)
class Pin:
    ref: str                # what the brain fetches: a commit, or a movable tag from before km pinned commits
    version: str | None     # the km version: the tag itself, or the comment next to a commit

    @property
    def is_commit(self) -> bool:
        return bool(SHA.fullmatch(self.ref))

    def __str__(self) -> str:
        if not self.is_commit:
            return f"tag {self.ref}"
        return f"{self.version} ({self.ref[:7]})" if self.version else self.ref[:12]


def _pin(ref: str, comment: str | None) -> Pin:
    return Pin(ref, comment if SHA.fullmatch(ref) else ref)


def _km_rev_lines(lines: list[str]) -> list[int]:
    """Indexes of the rev lines of km's repo entries in a pre-commit config."""
    items = [(i, len(m.group(1))) for i, ln in enumerate(lines) if (m := ITEM.match(ln))]
    if not items:
        return []
    top = min(indent for _, indent in items)                  # repo entries; deeper ones are hooks
    starts = [i for i, indent in items if indent == top] + [len(lines)]
    out = []
    for s, e in zip(starts, starts[1:]):
        if any(KM_REPO_LINE.match(ln) for ln in lines[s:e]):
            out += [i for i in range(s, e) if REV_LINE.match(lines[i])]
    return out


def workflow_files(root: Path) -> list[Path]:
    return sorted((root / ".github/workflows").glob("*.y*ml"))


def pinned_files(root: Path) -> list[Path]:
    return [*workflow_files(root), root / ".pre-commit-config.yaml"]


def read_pins(root: Path) -> dict[str, set[Pin]]:
    """{file relative to root: the km pins in it}, only for files that pin km."""
    out: dict[str, set[Pin]] = {}
    for p in pinned_files(root):
        if p.is_file():
            text = p.read_text(encoding="utf-8")
            if p.name == ".pre-commit-config.yaml":
                lines = text.splitlines()
                pins = {_pin(m.group(3), m.group(4)) for i in _km_rev_lines(lines) if (m := REV_LINE.match(lines[i]))}
            else:
                pins = {_pin(m.group(2), m.group(3)) for m in PIN.finditer(text)}
            if pins:
                out[str(p.relative_to(root))] = pins
    return out


def set_pins(root: Path, sha: str, version: str) -> list[str]:
    """Point every km pin at `sha`, commented with `version`; returns the files that changed."""
    changed = []
    for p in pinned_files(root):
        if p.is_file():
            text = p.read_text(encoding="utf-8")
            if p.name == ".pre-commit-config.yaml":
                lines = text.splitlines(keepends=True)
                for i in _km_rev_lines(lines):
                    end = "\n" if lines[i].endswith("\n") else ""
                    lines[i] = REV_LINE.sub(lambda m: m.group(1) + hook_rev(sha, version), lines[i].rstrip("\n")) + end
                new = "".join(lines)
            else:
                new = PIN.sub(lambda m: m.group(1) + uses_ref(sha, version), text)
            if new != text:
                p.write_text(new, encoding="utf-8")
                changed.append(str(p.relative_to(root)))
    return changed


def movable_refs(root: Path) -> list[tuple[str, str]]:
    """(file, what) for everything a brain runs from a movable ref instead of a commit: actions in its
    workflows, and a km hook pinned to a tag."""
    out = [(str(p.relative_to(root)), f"{m.group(1)}@{m.group(2)}") for p in workflow_files(root)
           for m in USES.finditer(p.read_text(encoding="utf-8")) if not SHA.fullmatch(m.group(2))]
    out += [(f, f"the km hook at {pin.ref}") for f, ps in read_pins(root).items() if f == ".pre-commit-config.yaml"
            for pin in ps if not pin.is_commit]
    return out


def resolve(version: str) -> str | None:
    """The commit a km release tag points at; None when the tag does not exist or the repository
    cannot be reached."""
    tag = f"refs/tags/{version}"
    out = subprocess.run(["git", "ls-remote", repo_url(), tag, tag + "^{}"], capture_output=True, text=True).stdout
    refs = {name: sha for sha, _, name in (line.partition("\t") for line in out.splitlines())}
    return refs.get(tag + "^{}") or refs.get(tag)   # an annotated tag: the commit it points at


def version_key(version: str | None) -> tuple[int, ...] | None:
    """(1, 2, 3) for v1.2.3; None for anything that has no order."""
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", version or "")
    return tuple(int(x) for x in m.groups()) if m else None
