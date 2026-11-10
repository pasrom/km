"""`km <command> [--root DIR] [args]`: one entry point for the km tools.

Each command is a module whose main() the CLI calls; it keeps its own argument handling and exit code.
`--root DIR` names the brain (default: the git work tree containing the current directory).

A brain pins a km release by commit (see km.pins) for CI (its workflows) and its pre-commit hook.
When this km is another version, a brain command runs the commit CI runs instead (through uvx), so
local results match CI; `KM_LOCAL=1` keeps this km. When that is not possible (no uv, offline, a
movable tag instead of a commit, workflows that disagree) it runs this km and says so. A command,
option or positional argument the pinned km lacks (SINCE, OPTION_SINCE, ARGS_SINCE) stops with a
call to `km upgrade` instead. A hook pinned apart from CI gets a note. `init`, `upgrade`, `doctor`,
`list` and `sync` (NO_PIN_CHECK) always run this km: they write the pins, check the km that runs,
only read, or act on the clone.
"""
from __future__ import annotations

import argparse
import importlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

from km import KM_REF, __version__
from km.paths import repo_root
from km.pins import read_pins, repo_url, version_key

COMMANDS = {
    "validate": ("km.validate", "check frontmatter, links, the gate and index completeness"),
    "gen-index": ("km.gen_index", "regenerate the '## Documents' list in every _index.md (--check for CI)"),
    "demote": ("km.demote", "demote served docs past review_by (--apply to write)"),
    "serve": ("km.serve", "build the served bundle under dist/served/"),
    "promote": ("km.promote", "move a note into the brain as a review doc, or `promote stub`"),
    "approve": ("km.approve", "sign review docs off as accepted (--by WHO)"),
    "repin": ("km.repin", "pin a doc's sources and translates to their current content (--cites: its cited files)"),
    "cite": ("km.cite", "`cite add DOC URL --file COPY`: record an external file a doc cites, by its sha256"),
    "cites": ("km.cites", "`cites check`: compare the files docs cite with local copies (--file, --dir)"),
    "init": ("km.init", "create a brain: `init DIR --initials XX`, `--team ...` for a team brain"),
    "upgrade": ("km.upgrade", "move a brain's km pins to this version; drop km files copied in earlier"),
    "doctor": ("km.doctor", "check this computer is set up for the brain: git, access, plugins, km version"),
    "list": ("km.list_docs", "list docs from their frontmatter: by folder, status, approval, review date (--json)"),
    "sync": ("km.sync", "bring this copy, a fork and the mounted brains up to the upstream brain (fast-forward only)"),
}
# they write the pins, check the km that is running, only read, or act on the clone, not the content
NO_PIN_CHECK = {"init", "upgrade", "doctor", "list", "sync"}
SINCE = {"repin": "v1.4.0", "cite": "v1.8.0", "cites": "v1.8.0"}   # commands an older pinned km does not have
OPTION_SINCE = {("repin", "--cites"): "v1.8.0", ("validate", "--signoff-since"): "v1.12.0"}   # options it does not have
ARGS_SINCE = {"demote": "v1.11.0"}                                  # positional args it ignores (no option there takes a value)
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


def positional(args: list[str]) -> list[str]:
    """The positional arguments of a command none of whose options takes a value: after `--`, all."""
    end = args.index("--") if "--" in args else len(args)
    return [a for a in args[:end] if a == "-" or not a.startswith("-")] + args[end + 1:]


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
    need = max([v for (c, opt), v in OPTION_SINCE.items() if c == cmd and opt in rest]   # exact: no allow_abbrev
               + ([SINCE[cmd]] if cmd in SINCE else [])
               + ([ARGS_SINCE[cmd]] if cmd in ARGS_SINCE and positional(rest) else []), key=version_key, default=None)
    if not why and need and (have := version_key(pin.version)) and have < version_key(need):
        print(f"km: `km {cmd}` needs km {need}, the brain pins {_label(chosen)}; run `km upgrade` "
              f"first (KM_LOCAL=1 runs this km instead).", file=sys.stderr)
        return 2
    if not why:
        print(f"km: the brain pins km {_label(chosen)}; running that one (this is {KM_REF}; KM_LOCAL=1 keeps it)",
              file=sys.stderr)
        # --no-config: no uv.toml or [tool.uv] from the brain steers what the pinned km is fetched from
        env = {**os.environ, "KM_LOCAL": "1", "KM_ROOT": str(root)}
        code = subprocess.run([RUNNER, "--quiet", "--no-config", *source, cmd, *rest], env=env).returncode
        if code == 0 or subprocess.run([RUNNER, "--quiet", "--no-config", *source, "--version"], env=env,
                                       capture_output=True).returncode == 0:
            return code                   # the pinned km ran; its exit code stands
        why = f"km {_label(chosen)} could not be fetched (offline?)"
    print(f"km: the brain pins km {_label(chosen)}, this is {KM_REF}; running this km since {why}. "
          f"CI may disagree; `km upgrade` moves the pins.", file=sys.stderr)
    return None


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):   # a non-UTF-8 console or pipe (Windows) must not crash on a file name
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
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
        return importlib.import_module(COMMANDS[cmd][0]).main() or 0
    except SystemExit as exc:   # argparse, and a fail-fast config check at import
        code = exc.code
        if code is None or isinstance(code, int):
            return code or 0
        print(code, file=sys.stderr)
        return 1
