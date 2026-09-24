"""`km <command> [--root DIR] [args]`: one entry point for the km tools.

Each command is a module run as a script, so it keeps its own argument handling and exit code.
`--root DIR` names the brain (default: the git work tree containing the current directory).

A brain pins a km release by commit (see km.pins) for CI (its workflows) and its pre-commit hook.
When this km is another version, a brain command runs the commit CI runs instead (through uvx), so
local results match CI; `KM_LOCAL=1` keeps this km. When that is not possible (no uv, offline, a
movable tag instead of a commit, workflows that disagree) it runs this km and says so. A hook pinned
apart from CI gets a note.
"""
from __future__ import annotations

import argparse
import os
import runpy
import shutil
import subprocess
import sys
from pathlib import Path

from km import KM_REF, __version__
from km.paths import repo_root
from km.pins import read_pins, repo_url

COMMANDS = {
    "validate": ("km.validate", "check frontmatter, links, the gate and index completeness"),
    "gen-index": ("km.gen_index", "regenerate the '## Documents' list in every _index.md (--check for CI)"),
    "demote": ("km.demote", "demote served docs past review_by (--apply to write)"),
    "serve": ("km.serve", "build the served bundle under dist/served/"),
    "promote": ("km.promote", "move a note into the brain as a review doc, or `promote stub`"),
    "init": ("km.init", "create a brain: `init DIR --initials XX`, `--team ...` for a team brain"),
    "upgrade": ("km.upgrade", "move a brain's km pins to this version; drop km files copied in earlier"),
}
NO_PIN_CHECK = {"init", "upgrade"}    # they write the pins, with the km that is running
RUNNER = os.environ.get("KM_PINNED_RUNNER", "uvx")


def usage() -> str:
    lines = [f"km {__version__}", "", "usage: km <command> [--root DIR] [args]", ""]
    lines += [f"  {name:<10} {help_}" for name, (_, help_) in COMMANDS.items()]
    return "\n".join(lines)


def take_root(args: list[str]) -> tuple[str | None, list[str]]:
    """Pull `--root DIR` or `--root=DIR` out of args, wherever it stands."""
    ap = argparse.ArgumentParser(prog="km", add_help=False, allow_abbrev=False)
    ap.add_argument("--root")
    ns, rest = ap.parse_known_args(args)
    return ns.root, rest


def _label(pins) -> str:
    return ", ".join(sorted(map(str, pins)))


def run_pinned(root: Path, cmd: str, rest: list[str]) -> int | None:
    """Run the km commit CI runs for this brain. None: run this km instead."""
    if os.environ.get("KM_LOCAL"):
        return None
    pins = read_pins(root)
    hook = pins.pop(".pre-commit-config.yaml", set())
    ci = set().union(*pins.values()) if pins else set()
    chosen = ci or hook               # a brain without CI: the hook's pin
    if ci and hook and hook != ci:
        print(f"km: the pre-commit hook pins km {_label(hook)}, CI pins {_label(ci)}; "
              f"`km upgrade` or `pre-commit autoupdate --freeze` aligns them.", file=sys.stderr)
    if not chosen or all(p.version == KM_REF for p in chosen):
        return None
    pin = next(iter(chosen))
    why = ("the workflows pin different km versions" if len(chosen) > 1 else
           f"{pin.ref} is a movable tag, not a commit (`km upgrade` pins the commit)" if not pin.is_commit else
           f"{RUNNER} is not installed" if not shutil.which(RUNNER) else None)
    source = ["--from", f"git+{repo_url()}@{pin.ref}", "km"]
    if not why:
        print(f"km: the brain pins km {_label(chosen)}; running that one (this is {KM_REF}; KM_LOCAL=1 keeps it)",
              file=sys.stderr)
        env = {**os.environ, "KM_LOCAL": "1", "KM_ROOT": str(root)}
        code = subprocess.run([RUNNER, "--quiet", *source, cmd, *rest], env=env).returncode
        if code == 0 or subprocess.run([RUNNER, "--quiet", *source, "--version"], env=env,
                                       capture_output=True).returncode == 0:
            return code                   # the pinned km ran; its exit code stands
        why = f"km {_label(chosen)} could not be fetched (offline?)"
    print(f"km: the brain pins km {_label(chosen)}, this is {KM_REF}; running this km since {why}. "
          f"CI may disagree; `km upgrade` moves the pins.", file=sys.stderr)
    return None


def main(argv: list[str] | None = None) -> int:
    root, args = take_root(list(sys.argv[1:] if argv is None else argv))
    if root is not None and not Path(root).is_dir():
        print(f"km: --root {root}: no such directory", file=sys.stderr)
        return 2
    if not args or args[0] in ("-h", "--help", "help"):
        print(usage())
        return 0
    if args[0] in ("-V", "--version", "version"):
        print(__version__)
        return 0
    cmd, rest = args[0], args[1:]
    if cmd not in COMMANDS:
        print(f"km: unknown command {cmd!r}\n\n{usage()}", file=sys.stderr)
        return 2
    brain = Path(root).resolve() if root else repo_root()
    os.environ["KM_ROOT"] = str(brain)            # resolved once, for every module
    if cmd not in NO_PIN_CHECK and (code := run_pinned(brain, cmd, rest)) is not None:
        return code
    sys.argv = [f"km {cmd}", *rest]           # argparse shows "km <cmd>" in its usage lines
    try:
        runpy.run_module(COMMANDS[cmd][0], run_name="__main__")
    except SystemExit as exc:
        code = exc.code
        if code is None or isinstance(code, int):
            return code or 0
        print(code, file=sys.stderr)
        return 1
    return 0
