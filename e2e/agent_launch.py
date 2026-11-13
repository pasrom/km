"""The role launcher: one interactive `claude` session per role step, in tmux, in the clean profile.

A step names its role, its working directory (the role's sandbox clone) and its prompt. The launcher
writes the step folder outside every folder a session may read or write (a step file of paths and
plain values, never a token; the prompt; a git config for the role; the done file) and a trust record
for the working directory, then starts `agent_launch.py shell <step file>` in a tmux session on a socket of
its own. That shell builds the environment from an allowlist (agent_profile.base_env) and execs
`claude` with the prompt.

The token never enters the session: not its argv, prompt, environment, tmux command or tmux server.
GitHub access goes through two small wrappers the launcher writes outside the folders a session may
read (agent_profile.SESSIONS): a `gh` first on the session's PATH that reads the token for that one call
(and refuses `gh auth`), and git's credential helper. A session runs as the same OS user, so an agent
that goes looking can still read the token file with a shell command; the permission rules make that
harder, not impossible. That is accepted because the token is C's, whose account reaches nothing but
the sandbox (the preflight's 404 checks), and every transcript and everything a run writes to GitHub is
checked for the token in plain and encoded forms.

The profile's Stop hook writes the hook input to the step's done file at the end of every turn; the
driver reads the transcript by the session id from the profile's own projects folder. The driver waits, bounded, until the done file is there, the final assistant message
ends with the sentinel and the transcript has been quiet for a while: a turn can end while subagents
still run, and a session that stops to ask a question never writes the sentinel.

Roles: C is the contributor; S (the subject-matter colleague, who signs off through C's branch) and X
(the adversary, a behaviour of C's login) use C's token; J, the model judge, has no token. M, the
maintainer, stays the driver: no agent holds M's token.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent_judge as J            # noqa: E402
import agent_profile as P          # noqa: E402

TOKEN_ROLE = {"C": "C", "S": "C", "X": "C", "Q": "C", "J": None}
READ_ONLY = {"Q"}                      # the queue reader: gh reads only, git has no credentials
NO_MCP = '{"mcpServers":{}}'
# the gh subcommands the km skill uses (`auth` only as `auth status`, which the skill checks first);
# words that would let gh hand out the token or run other code with it are refused anywhere after it
GH_ALLOWED = "pr|issue|api|repo|run|label|search"
GH_REFUSED = "alias|extension|extensions|ext|config|auth|secret|ssh-key|gpg-key"
# a read-only role: these subcommands only, and `gh api` without a request body, method or GraphQL
GH_READ_ONLY = """case "$1 ${2:-}" in
  "auth status"|"pr list"|"pr view"|"pr checks"|"pr diff"|"pr status"|"issue list"|"issue view"|"repo view"|"run list"|"run view"|"label list"|"search "*) ;;
  "api graphql") refuse "api graphql";;
  "api "*) want=; first=1
    for a in "$@"; do
      [ -n "$first" ] && { first=; continue; }
      case "$want" in
        get) [ "$a" = GET ] || refuse "$a"; want=; continue;;
        accept) case "$a" in "Accept: application/vnd.github.raw"|"Accept: application/vnd.github+json") ;; *) refuse "-H $a";; esac
                want=; continue;;
        value) want=; continue;;
      esac
      case "$a" in
        -X|--method) want=get;;
        -H|--header) want=accept;;
        -q|--jq|-t|--template|--hostname) want=value;;
        -XGET|--method=GET|--paginate|--slurp|-i|--include|--silent|--jq=*|--hostname=*) ;;
        -*) refuse "$a";;
      esac
    done
    [ -z "$want" ] || refuse "an option without its value";;
  *) refuse "$1 ${2:-}";;
esac
"""
GH_WRAPPER = """#!/bin/sh
# gh for one e2e role: the token is read for this call only and never enters the session's environment
refuse() {{ echo "gh: '$1' is not available in an e2e session" >&2; exit 1; }}
case "$1" in
  auth) [ "${{2:-}}" = status ] || refuse "auth ${{2:-}}"
        for a in "$@"; do case "$a" in -t|--show-token) refuse "$a";; esac; done;;
  {allowed}) ;;
  *) refuse "$1";;
esac
first=1
for a in "$@"; do
  [ -n "$first" ] && {{ first=; continue; }}
  [ "$1" = auth ] && [ "$a" = status ] && continue
  case "$a" in {refused}) refuse "$a";; esac
done
{read_only}GH_TOKEN="$(cat {token})" exec {gh} "$@"
"""
GIT_HELPER = """#!/bin/sh
# git's credential helper for one e2e role (github.com only, see the git config that names it)
test "$1" = get || exit 0
echo username=x-access-token
printf 'password=%s\\n' "$(cat {token})"
"""


@dataclass
class Step:
    name: str                          # unique in the run, also the tmux session's name
    role: str                          # C, S, X, Q (C read-only) or J
    cwd: Path
    prompt: str
    add_dirs: list[Path] = field(default_factory=list)
    tools: str | None = None           # --tools; "" disables every tool (the judge)
    deny: list[str] = field(default_factory=list)     # extra --disallowedTools for this step
    timeout: float = 2400              # seconds until the driver gives up on the session
    quiet: float = 45                  # seconds the transcript must stay unchanged after the sentinel


@dataclass
class Outcome:
    finished: bool                     # the sentinel came, the transcript went quiet
    text: str                          # the final assistant message
    transcript: str | None
    seconds: float
    note: str = ""


@dataclass
class Role:
    """A role's token file (its path; the wrappers read it) and git's identity."""
    token_file: Path | None
    name: str = ""
    email: str = ""


class Launcher:
    def __init__(self, rundir: Path, profile: Path, plugin_dir: Path | None, roles: dict[str, Role], socket: str,
                 sessions: Path, verify: Callable[[], None] | None = None):
        """RUNDIR: where each step's outcome is kept after its session. SESSIONS: the step folders while a
        session runs (wrappers, step file, prompt, git config, done file), outside every folder a session
        may read or write, removed by close(). VERIFY: called before each session starts; raises when the
        plugin export or the profile is no longer what was checked."""
        self.rundir, self.profile, self.plugin_dir, self.roles, self.socket = rundir, profile, plugin_dir, roles, socket
        self.sessions, self.verify = sessions / socket, verify
        self.claude = P.claude_bin()
        self.session_ids: dict[str, str] = {}
        self._tmux_env = {k: v for k, v in P.base_env(profile).items() if k in ("HOME", "USER", "LANG", "TERM", "PATH", "TMPDIR")}

    # --- step files ----------------------------------------------------------------------------
    def prepare(self, step: Step) -> Path:
        """The step folder: the role's gh wrapper (bin/) and git credential helper, an empty read-only gh
        config, the git config, the prompt and the step file. Owner only, never a token."""
        if step.role not in TOKEN_ROLE:
            raise SystemExit(f"e2e: no agent plays role {step.role!r} (M stays the driver)")
        d = self.sessions / step.name
        d.mkdir(parents=True, exist_ok=False, mode=0o700)
        os.chmod(self.sessions, 0o700)
        role = self.roles.get(TOKEN_ROLE[step.role] or "", Role(None))
        path = []
        # no excludes or attributes file from the home folder (the sandbox denies reading ~/.config)
        git = "[credential]\n\thelper =\n[commit]\n\tgpgsign = false\n[core]\n\texcludesFile = /dev/null\n\tattributesFile = /dev/null\n"
        git += f"[user]\n\tname = {json.dumps(role.name or 'km-e2e')}\n\temail = {json.dumps(role.email or 'km-e2e@invalid')}\n"
        if role.token_file:
            token = shlex.quote(str(role.token_file))
            (d / "bin").mkdir(mode=0o700)
            ro = GH_READ_ONLY if step.role in READ_ONLY else ""
            for f, text in ((d / "bin" / "gh", GH_WRAPPER.format(token=token, gh=shlex.quote(real_gh()), allowed=GH_ALLOWED,
                                                                 refused=GH_REFUSED, read_only=ro)),
                            (d / "git-credential", GIT_HELPER.format(token=token))):
                f.write_text(text, encoding="utf-8")
                f.chmod(0o700)
            path.append(str(d / "bin"))
            if step.role in READ_ONLY:         # no credentials for git at all: the driver prepares the clone
                (d / "git-credential").unlink()
            else:
                git += f'[credential "https://github.com"]\n\thelper = {json.dumps("!" + shlex.quote(str(d / "git-credential")))}\n'
        (d / "gitconfig").write_text(git, encoding="utf-8")
        (d / "gh-config").mkdir(mode=0o500)    # empty and read-only: no login, alias or extension
        (d / "prompt.md").write_text(step.prompt, encoding="utf-8")
        # user settings only (the profile's): project settings in a clone (hooks, permissions) never load
        session_id = str(uuid.uuid4())     # the driver's: the transcript is looked up by it, nothing else
        argv = [self.claude, "--session-id", session_id, "--setting-sources", "user", "--strict-mcp-config",
                "--mcp-config", NO_MCP, "--permission-mode", "dontAsk", "-n", f"km-e2e {step.name}"]
        if self.plugin_dir and step.role != "J":
            argv += ["--plugin-dir", str(self.plugin_dir)]
            path.append(str(self.plugin_dir / "skills" / "km" / "bin"))
        for a in step.add_dirs:
            argv += ["--add-dir", str(a)]
        if step.tools is not None:
            argv += ["--tools", step.tools]
        if step.deny:
            argv += ["--disallowedTools", *step.deny]
        sandbox = None
        if SANDBOX_EXEC:
            sandbox = d / "sandbox.sb"
            sandbox.write_text(sandbox_profile(step, d, self.profile, self.plugin_dir, role.token_file, session_id),
                               encoding="utf-8")
        spec = {"name": step.name, "role": step.role, "cwd": str(step.cwd), "profile": str(self.profile),
                "argv": argv, "prompt_file": str(d / "prompt.md"), "done_file": str(d / "done" / "done.json"),
                "rw": str(d / "rw"),
                "gitconfig": str(d / "gitconfig"), "gh_config_dir": str(d / "gh-config"), "path_extra": path,
                "sandbox": str(sandbox) if sandbox else None}
        self.session_ids[step.name] = session_id      # kept here: nothing a session can write names it
        for sub in ("rw", "done"):                       # the only parts of the step folder a session may write
            (d / sub).mkdir(mode=0o700)
        (d / "step.json").write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")
        P.trust(self.profile, step.cwd, *step.add_dirs)
        return d

    # --- tmux ----------------------------------------------------------------------------------
    def tmux(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        # a minimal environment: the tmux server started here passes nothing of the caller's on
        # the server's socket lives in the owner-only sessions folder, which no session can reach
        return subprocess.run(["tmux", "-S", str(self.sessions / "tmux.sock"), *args], env=self._tmux_env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, check=check, timeout=30)

    def start(self, step: Step) -> Path:
        if self.verify:
            self.verify()
        if found := agent_config_in(step.cwd, *step.add_dirs):
            raise SystemExit(f"e2e: {found[0]} would steer the session (agent configuration in a folder it opens): stopping")
        d = self.prepare(step)
        shell = [sys.executable, "-I", str(Path(__file__).resolve()), "shell", str(d / "step.json")]
        self.tmux("new-session", "-d", "-s", step.name, "-x", "220", "-y", "60", *shell)
        return d

    def end(self, step: Step) -> None:
        """Stop the session: its whole process group (the pane's process leads one, so background work
        the agent started goes too), by the pane's PID, then the tmux session."""
        r = self.tmux("display-message", "-p", "-t", step.name, "#{pane_pid}", check=False)
        if r.returncode == 0 and r.stdout.strip().isdigit():
            pid = int(r.stdout.strip())
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(pid, sig)
                except (ProcessLookupError, PermissionError):
                    break
                time.sleep(3)
        self.tmux("kill-session", "-t", step.name, check=False)

    def close(self) -> None:
        """End this run's tmux server (its own socket: no other session is touched), drop the step folders."""
        self.tmux("kill-server", check=False)
        for d in self.sessions.glob("*/gh-config"):
            if not d.is_symlink():             # never follow a link a session could have planted
                os.chmod(d, 0o700, follow_symlinks=False)
        shutil.rmtree(self.sessions, ignore_errors=True)

    def run(self, step: Step) -> Outcome:
        d = self.start(step)
        alive = lambda: self.tmux("has-session", "-t", step.name, check=False).returncode == 0   # noqa: E731
        try:
            screen = lambda: self.tmux("capture-pane", "-p", "-t", step.name, check=False).stdout   # noqa: E731
            out = wait_done(d / "done" / "done.json", self.profile / "projects", step.timeout, step.quiet, alive=alive,
                            screen=screen, session_id=self.session_ids[step.name])
        finally:
            self.end(step)
        keep = self.rundir / "agents" / step.name
        keep.mkdir(parents=True, exist_ok=True)
        (keep / "outcome.json").write_text(json.dumps(asdict(out), indent=2) + "\n", encoding="utf-8")
        if self.verify:                    # what the session may have changed for the next one
            self.verify()
        return out


AGENT_CONFIG = (".claude", ".mcp.json", "CLAUDE.local.md")


def agent_config_in(*folders: Path) -> list[Path]:
    """Files or folders in FOLDERS (outside .git) that configure Claude Code for a session opened there:
    an adversary could commit them to the sandbox. A brain's CLAUDE.md is content and is left to the
    prompt, which treats it as data."""
    found = []
    for top in folders:
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            found += [Path(dirpath) / n for n in (*dirnames, *filenames) if n in AGENT_CONFIG]
    return found


SANDBOX_EXEC = "/usr/bin/sandbox-exec" if sys.platform == "darwin" and Path("/usr/bin/sandbox-exec").exists() else None


def sb(path: Path | str) -> str:
    return json.dumps(str(Path(path).resolve()))      # a quoted SBPL string


def sandbox_profile(step: Step, stepdir: Path, profile: Path, plugin: Path | None, token: Path | None,
                    session_id: str = "") -> str:
    """The macOS sandbox a session runs in (sandbox-exec).

    Reads: nothing in the home folder (other repositories, the person's own Claude profiles, keys, the
    maintainer's token) except the clone and the folders the step adds, the clean profile, the step
    folder, the role's token file (its gh wrapper reads it), the plugin export and Claude Code itself;
    of the folders above those only their metadata. Writes: only the clone (not its .git config, hooks
    or info), the step folder's rw/ (the session's own temp folder and tool caches, see role_env) and
    done/, the profile (not its settings, hook, or another session's transcript) and Claude Code's shell
    state for the clone. No keychain, no Launch Services, Apple Events or pasteboard (nothing started
    outside the sandbox), no unix socket but the system's and rw/'s (no tmux, cmux or askpass socket)."""
    home = Path.home().resolve()
    claude = Path(P.claude_bin())
    reads = [step.cwd, *step.add_dirs, profile, stepdir, *([token] if token else []), *([plugin] if plugin else []),
             claude.resolve().parent.parent]        # Claude Code's versions folder
    # Claude Code's shell tool keeps its state under /private/tmp/claude-<uid>/<folder>, whatever TMPDIR says
    shell_state = Path(f"/private/tmp/claude-{os.getuid()}") / re.sub(r"[^A-Za-z0-9]", "-", str(step.cwd.resolve()))
    writes = [sb(step.cwd), sb(stepdir / "rw"), sb(stepdir / "done"), sb(profile), sb(shell_state), '"/dev"']
    frozen = [f"(subpath {sb(plugin)})"] if plugin else []
    frozen += [f"(literal {sb(profile / 'settings.json')})", f"(subpath {sb(profile / 'hooks')})"]
    return "\n".join([
        "(version 1)",
        "(allow default)",
        f"(deny file-read* (subpath {sb(home)}))",
        # the claude command itself, a link into that folder (not resolved, unlike sb())
        "(allow file-read* " + " ".join(f"(subpath {sb(r)})" for r in reads) + f" (literal {json.dumps(str(claude.absolute()))}))",
        # the folders above those: their metadata only (a path is resolved through them), not their listing
        "(allow file-read-metadata " + " ".join(f"(literal {sb(a)})" for a in [home, *ancestors([*reads, claude], home)]) + ")",
        "(deny file-write* (require-not (require-any " + " ".join(f"(subpath {w})" for w in writes) + ")))",
        "(deny file-write* " + " ".join(frozen) + ")",
        # nothing in a clone that would run code for the next git there: config, hooks, info
        '(deny file-write* (regex #"/\\.git/(config|hooks/|info/)"))',
        # the keychain (the person's own gh login, other credentials): neither the security tool nor the
        # Security framework's daemons; Claude Code takes its subscription token from the environment
        '(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd") '
        '(global-name "com.apple.securityd.xpc") (global-name "com.apple.security.agent") (global-name "com.apple.secd"))',
        # nothing that starts a program outside the sandbox or reads what the person copied
        '(deny process-exec (literal "/usr/bin/security") (literal "/usr/bin/open") (literal "/usr/bin/osascript") '
        '(literal "/usr/bin/pbpaste") (literal "/usr/bin/pbcopy"))',
        '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd") (global-name-regex #"^com\\.apple\\.lsd\\.") '
        '(global-name "com.apple.coreservices.appleevents") (global-name "com.apple.pasteboard.1"))',
        "(deny appleevent-send)",
        # the profile's transcripts: only this session's own
        f"(deny file-write* (subpath {sb(profile / 'projects')}))",
        *([f'(allow file-write* (regex #"^{re.escape(str((profile / "projects").resolve()))}/[^/]+(/{re.escape(session_id)}(\\.jsonl|/.*))?$"))']
          if session_id else []),
        "(deny network-outbound (remote unix-socket))",
        f'(allow network-outbound (remote unix-socket (subpath "/private/var/run")) (remote unix-socket (subpath {sb(stepdir / "rw")})))',
        ""])


def ancestors(paths: list[Path], home: Path) -> list[Path]:
    """The folders between HOME and each of PATHS (HOME excluded, PATHS excluded)."""
    out: set[Path] = set()
    for p in paths:
        p = p.resolve()
        out |= {a for a in p.parents if a != home and a.is_relative_to(home)}
    return sorted(out)


def transcript_of(projects: Path, session_id: str) -> Path | None:
    """The session's transcript, found in the profile's own projects folder by the session id; a path
    the hook input names is not trusted."""
    if not session_id or not all(c.isalnum() or c == "-" for c in session_id):
        return None
    found = [t for t in projects.glob(f"*/{session_id}.jsonl") if t.resolve().is_relative_to(projects.resolve())]
    return found[0] if len(found) == 1 else None


def activity(tp: Path) -> float:
    """The newest change to the transcript or to the transcripts of its subagents (in the folder named
    after the session), which keep working after a turn ended."""
    side = tp.with_suffix("")
    return max([tp.stat().st_mtime, *(f.stat().st_mtime for f in side.rglob("*.jsonl"))] if side.is_dir() else [tp.stat().st_mtime])


def wait_done(done: Path, projects: Path, timeout: float, quiet: float, alive=lambda: True, every: float = 5,
              grace: float = 120, screen=lambda: "", session_id: str = "") -> Outcome:
    """Wait until DONE exists, the session's transcript (in PROJECTS, by the session id DONE names) ends
    with an assistant message whose last line is the sentinel, and neither DONE nor the transcript nor its
    subagents' transcripts changed for QUIET seconds; or until TIMEOUT, or the session is gone. A session
    that has written no transcript after GRACE seconds sits on a dialog: stop with SCREEN's text.
    SESSION_ID, the driver's own, overrides the one DONE names."""
    t0, seen = time.time(), None
    tp, text, last = None, "", 0.0
    while True:
        if done.is_file():
            stamp = (done.stat().st_mtime, activity(tp) if tp else 0.0)
            if stamp != seen:
                seen = stamp
                try:
                    info = json.loads(done.read_text(encoding="utf-8"))
                except ValueError:
                    info = {}
                tp = transcript_of(projects, session_id or str(info.get("session_id", ""))) or tp
                text = J.final_text(tp) if tp else ""
                last = max(done.stat().st_mtime, activity(tp) if tp else 0.0)
            if tp and J.finished(text) and time.time() - last >= quiet:
                return Outcome(True, text, str(tp), time.time() - t0)
        if not done.is_file() and time.time() - t0 > grace and not any(
                t.stat().st_mtime >= t0 for t in projects.glob("*/*.jsonl")):
            shown = " | ".join(ln.strip() for ln in screen().splitlines() if ln.strip())[:600]
            return Outcome(False, text, None, time.time() - t0, f"no transcript after {grace:.0f} s; the screen shows: {shown}")
        if time.time() - t0 > timeout:
            return Outcome(False, text, str(tp) if tp else None, time.time() - t0, f"no finished session after {timeout:.0f} s")
        if not alive():
            return Outcome(False, text, str(tp) if tp else None, time.time() - t0, "the session ended without the sentinel")
        time.sleep(every)


def real_gh() -> str:
    """The gh binary itself: the first `gh` on the PATH that is not a script. A wrapper script in front
    of gh (a text guard, say) that looks gh up on the PATH again would find the role's wrapper and loop.
    KM_E2E_GH overrides."""
    if v := os.environ.get("KM_E2E_GH"):
        return v
    for d in os.environ.get("PATH", "").split(os.pathsep):
        f = Path(d) / "gh"
        if f.is_file() and os.access(f, os.X_OK):
            with f.open("rb") as fh:
                if fh.read(2) != b"#!":
                    return str(f)
    return shutil.which("gh") or "gh"


# --- the shell inside tmux -------------------------------------------------------------------------
def role_env(spec: dict) -> dict[str, str]:
    """The session's environment: the profile's base, the role's wrappers and git config, the done file.
    No token."""
    env = P.base_env(Path(spec["profile"]))
    env["PATH"] = os.pathsep.join([*spec["path_extra"], env["PATH"]])
    env |= {"GH_CONFIG_DIR": spec["gh_config_dir"], "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
            "GIT_CONFIG_GLOBAL": spec["gitconfig"], "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_SSH_COMMAND": "false", "KM_E2E_DONE_FILE": spec["done_file"]}
    # the session's own temp folder and tool caches, in its step folder: nothing it writes there is read
    # by the driver or another session
    own = Path(spec["rw"])
    for k, sub in (("TMPDIR", "tmp"), ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                   ("UV_CACHE_DIR", "cache/uv"), ("UV_TOOL_DIR", "data/uv-tools"), ("UV_PYTHON_INSTALL_DIR", "data/uv-python"),
                   ("PRE_COMMIT_HOME", "cache/pre-commit")):
        (own / sub).mkdir(parents=True, exist_ok=True)
        env[k] = str(own / sub)
    return env


def shell(step_file: Path) -> int:
    spec = json.loads(step_file.read_text(encoding="utf-8"))
    prompt = Path(spec["prompt_file"]).read_text(encoding="utf-8")
    os.chdir(spec["cwd"])
    env = role_env(spec)
    if token := P.claude_token():      # read here, outside the sandbox, which keeps the session off the keychain
        env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    argv = [*spec["argv"], "--", prompt]
    if spec.get("sandbox"):
        argv = [SANDBOX_EXEC, "-f", spec["sandbox"], *argv]
    os.execve(argv[0], argv, env)
    return 127                         # not reached


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "shell":
        return shell(Path(argv[1]))
    print("usage: agent_launch.py shell <step.json> (started by the launcher inside tmux)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
