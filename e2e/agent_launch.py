"""The role launcher: one interactive `claude` session per role step, in a fresh container.

A step names its role, its clone on the host (copied into the container, never mounted), its prompt and
any extra folders. The launcher writes a staging folder on the host (owner only): the role's gh wrapper
and git credential helper, its git config, the Stop hook, the firewall's input, the managed settings and
the config folder's .claude.json. Then it creates a container from the agent image (agent_profile.image)
with exactly two read-only mounts, the km plugin export and the role's token file; copies the staging
folder, the clone and the extra folders in; and starts it. The entrypoint sets up the egress firewall as
root (container/init-firewall.sh), hands the copied files to the session user and drops to it with no
capability left. The session sees nothing of the host: not the home folder, keychain, terminals,
launchd, local sockets, the host network or the LAN.

The subscription token reaches the container as an environment variable passed by name (`-e NAME`, its
value in the docker client's environment, never on a command line). C's GitHub token is the mounted
file; the gh wrapper and git's credential helper read it per call, so it is in no environment. Both are
in the agent's reach: accepted, since the firewall lets nothing out but to Anthropic and GitHub, C's
account reaches only the sandbox, and every transcript and PR is checked for both tokens.

The driver reads the session's state with `docker cp` out of the container (a tar stream of regular files
only, size-capped; nothing a session writes lands on the host as a link or under a path it chose): the
Stop hook's file and the transcripts. It waits until the transcript of its own session id ends with the
sentinel and has been quiet for a while (a turn can end while subagents still run), keeps the transcripts
in the run folder, and removes the container by its id.

Roles: C is the contributor; S (the subject-matter colleague, who signs off through C's branch) and X
(the adversary, a behaviour of C's login) use C's token; Q reads with C's token, read-only by its gh
wrapper; J, the model judge, has no token. M, the maintainer, stays the driver: no agent holds M's token.
"""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import uuid
from collections.abc import Callable, Mapping
from dataclasses import asdict, dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent_judge as J            # noqa: E402
import agent_profile as P          # noqa: E402

TOKEN_ROLE = {"C": "C", "S": "C", "X": "C", "Q": "C", "J": None}
READ_ONLY = {"Q"}                      # the queue reader: gh reads only, git has no credentials
NO_MCP = '{"mcpServers":{}}'
# the entrypoint's needs, nothing more: the firewall (NET_ADMIN, NET_RAW), handing the copied files to
# the session user (CHOWN), and dropping to it with an empty bounding set (SETUID, SETGID, SETPCAP)
CAPS = ("NET_ADMIN", "NET_RAW", "CHOWN", "SETUID", "SETGID", "SETPCAP")
MAX_FILE = 64 << 20                    # bytes read out of a container per file
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
{scope}{read_only}GH_TOKEN="$(cat {token})" exec {gh} "$@"
"""
# where a role's gh may write: its own repositories only (the sandbox, C's fork); no gist, no new or
# forked repository, no API path into another repository. A speed bump, not the boundary: the token file
# is in the session's reach, and the driver's sweep after the run (agent_run.exfil_sweep) is the check.
GH_SCOPE = """case "$1 ${{2:-}}" in "repo create"|"repo fork"|"repo delete"|"repo rename"|"repo archive"|"repo edit"|"repo sync") refuse "$1 $2";; esac
ours() {{ r=$(printf %s "$1" | tr 'A-Z' 'a-z'); case " {repos} " in *" $r "*) return 0;; esac; return 1; }}
# a GraphQL write: only the two the skill uses (reply to a review thread, resolve it); no query from a file
graphql_ok() {{ case "$1" in query=@*) return 1;; *mutation*)
  printf %s "$1" | sed -E 's/(addPullRequestReviewThreadReply|resolveReviewThread)[[:space:]]*\\(/ok[/g' \
    | grep -qE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\\([[:space:]]*input' && return 1;; esac; return 0; }}
want=
for a in "$@"; do
  if [ -n "$want" ]; then ours "$a" || refuse "--repo $a"; want=; continue; fi
  [ "$1 ${{2:-}}" = "api graphql" ] && {{ graphql_ok "$a" || refuse "a GraphQL write other than a thread reply or resolve"; }}
  case "$a" in
    *[[:space:]]*) continue;;           # prose (a title, a body), not a target
    *://*|*github.com/*) refuse "$a";;  # a URL names its own repository: refused, whatever it is
    *"{{owner}}"*|*"{{repo}}"*) refuse "$a";;   # gh fills these from the clone's remotes, which a session can change
    -R|--repo) want=1;;
    --repo=*) ours "${{a#--repo=}}" || refuse "$a";;
    gists|gists/*|/gists|/gists/*|*/gists|*/gists/*|user/repos*|/user/repos*|orgs/*/repos*|/orgs/*/repos*|repos/*/forks*|/repos/*/forks*) refuse "$a";;
    repos/*|/repos/*) p=${{a#/}}; p=${{p#repos/}}; ours "$(printf %s "$p" | cut -d/ -f1-2 | cut -d'?' -f1)" || refuse "$a";;
  esac
done
"""
GIT_HELPER = """#!/bin/sh
# git's credential helper for one e2e role (github.com only, see the git config that names it)
test "$1" = get || exit 0
echo username=x-access-token
printf 'password=%s\\n' "$(cat {token})"
"""
REAL_GH = "/opt/gh/bin/gh"             # in the image, off every PATH: only the role's wrapper runs it


@dataclass
class Step:
    name: str                          # unique in the run, also part of the container's name
    role: str                          # C, S, X, Q (C read-only) or J
    cwd: Path                          # the host clone, copied to P.CLONE
    prompt: str
    add_dirs: list[Path] = field(default_factory=list)   # copied to P.INPUTS/<name> (see inside())
    tools: str | None = None           # --tools; "" disables every tool (the judge)
    deny: list[str] = field(default_factory=list)     # extra --disallowedTools for this step
    timeout: float = 2400              # seconds until the driver gives up on the session
    quiet: float = 45                  # seconds the transcript must stay unchanged after the sentinel
    collect: list[str] = field(default_factory=list)  # files of the clone to keep after the session


@dataclass
class Outcome:
    finished: bool                     # the sentinel came, the transcript went quiet
    text: str                          # the final assistant message
    transcript: str | None             # the kept copy of the session's own transcript
    seconds: float
    note: str = ""
    transcripts: list[str] = field(default_factory=list)   # every kept transcript (subagents' too)
    rejected: int = -1                 # outbound connections the firewall refused during the session


@dataclass
class Role:
    """A role's token file (mounted read-only; the wrappers read it) and git's identity."""
    token_file: Path | None
    name: str = ""
    email: str = ""
    repos: tuple[str, ...] = ()        # owner/name the role's gh may address (empty: no restriction)


def inside(path: Path) -> str:
    """Where an extra folder of a step is inside the container."""
    return f"{P.INPUTS}/{path.name}"


def docker(*args: str, timeout: float = 120, check: bool = True, env: Mapping[str, str] | None = None,
           input: bytes | None = None) -> subprocess.CompletedProcess:
    try:
        r = subprocess.run(["docker", *args], capture_output=True, timeout=timeout, env=env, input=input,
                           stdin=None if input is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        r = subprocess.CompletedProcess(["docker", *args], 124, b"", f"no answer in {timeout:.0f} s".encode())
    if check and r.returncode != 0:
        raise RuntimeError(f"docker {args[0]} failed: {r.stderr.decode(errors='replace').strip()[-400:]}")
    return r


def regular_files(tar_bytes: bytes, limit: int = MAX_FILE) -> dict[str, tuple[float, bytes]]:
    """The regular files of a tar stream (`docker cp ... -`): {path: (mtime, content)}. Links, devices,
    absolute or `..` paths and files above LIMIT are left out: what a session wrote is data only."""
    out: dict[str, tuple[float, bytes]] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as tf:
            for m in tf:
                parts = Path(m.name).parts
                if not m.isreg() or m.size > limit or m.name.startswith("/") or ".." in parts:
                    continue
                f = tf.extractfile(m)
                if f is not None:
                    out["/".join(parts)] = (float(m.mtime), f.read())
    except tarfile.TarError:
        pass
    return out


def safe_name(rel: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", rel)[-180:]


class Launcher:
    def __init__(self, rundir: Path, plugin_dir: Path | None, roles: dict[str, Role], run_id: str,
                 sessions: Path, net: Path):
        """RUNDIR: where each step's outcome is kept. SESSIONS: the host staging folders while a run lasts,
        removed by close(). NET: the firewall's input (github-cidrs, hosts), copied into every container."""
        self.rundir, self.plugin_dir, self.roles, self.run_id = rundir, plugin_dir, roles, run_id
        self.sessions, self.net = sessions / f"km-e2e-{run_id}", net
        self.image = P.image()
        self.version = P.image_version(self.image)
        self.session_ids: dict[str, str] = {}

    def uses_plugin(self, step: Step) -> bool:
        return bool(self.plugin_dir) and step.role != "J"

    # --- the staging folder and the container --------------------------------------------------
    def prepare(self, step: Step, command: list[str] | None = None) -> Path:
        """The step's staging folder: opt/ (copied to P.STEP: the gh wrapper, git's credential helper and
        config, an empty gh config, the Stop hook, the firewall's input), config/ (copied to P.CONFIG),
        managed-settings.json, and step.json with the container's command. Owner only, never a token."""
        if step.role not in TOKEN_ROLE:
            raise SystemExit(f"e2e: no agent plays role {step.role!r} (M stays the driver)")
        d = self.sessions / step.name
        d.mkdir(parents=True, exist_ok=False, mode=0o700)
        os.chmod(self.sessions, 0o700)
        opt = d / "opt"
        (opt / "gh-config").mkdir(parents=True)        # empty, root-owned in the container: no login, alias, extension
        shutil.copytree(self.net, opt / "net")
        role = self.roles.get(TOKEN_ROLE[step.role] or "", Role(None))
        path = []
        git = "[credential]\n\thelper =\n[commit]\n\tgpgsign = false\n[core]\n\texcludesFile = /dev/null\n\tattributesFile = /dev/null\n"
        git += f"[user]\n\tname = {json.dumps(role.name or 'km-e2e')}\n\temail = {json.dumps(role.email or 'km-e2e@invalid')}\n"
        if role.token_file:
            (opt / "bin").mkdir()
            ro = GH_READ_ONLY if step.role in READ_ONLY else ""
            scope = GH_SCOPE.format(repos=" ".join(r.lower() for r in role.repos)) if role.repos else ""
            files = [(opt / "bin" / "gh", GH_WRAPPER.format(token=P.GH_TOKEN, gh=REAL_GH, allowed=GH_ALLOWED,
                                                             refused=GH_REFUSED, read_only=ro, scope=scope))]
            if step.role not in READ_ONLY:     # a read-only role's git has no credentials: the driver clones for it
                files.append((opt / "git-credential", GIT_HELPER.format(token=P.GH_TOKEN)))
                git += f'[credential "https://github.com"]\n\thelper = {json.dumps("!" + P.STEP + "/git-credential")}\n'
            for f, text in files:
                f.write_text(text, encoding="utf-8")
                f.chmod(0o755)
            path.append(f"{P.STEP}/bin")
        (opt / "gitconfig").write_text(git, encoding="utf-8")
        (opt / "done.sh").write_text(P.HOOK, encoding="utf-8")
        (opt / "done.sh").chmod(0o755)
        (d / "managed-settings.json").write_text(json.dumps(P.settings(), indent=2) + "\n", encoding="utf-8")
        (d / "config").mkdir()
        trusted = [P.CLONE, *(inside(a) for a in step.add_dirs)]
        (d / "config" / ".claude.json").write_text(json.dumps(P.claude_json(self.version, trusted), indent=2) + "\n",
                                                   encoding="utf-8")
        session_id = str(uuid.uuid4())     # the driver's: the transcript is looked up by it, nothing else
        if command is None:
            command = ["claude", "--session-id", session_id, "--setting-sources", "user", "--strict-mcp-config",
                       "--mcp-config", NO_MCP, "--permission-mode", "dontAsk", "-n", f"km-e2e {step.name}"]
            command += ["--model", P.model()]
            if self.uses_plugin(step):
                command += ["--plugin-dir", P.PLUGIN]
            for a in step.add_dirs:
                command += ["--add-dir", inside(a)]
            if step.tools is not None:
                command += ["--tools", step.tools]
            if step.deny:
                command += ["--disallowedTools", *step.deny]
            command += ["--", step.prompt]
        if self.uses_plugin(step):
            path.append(f"{P.PLUGIN}/skills/km/bin")
        self.session_ids[step.name] = session_id      # kept here: nothing a session can write names it
        spec = {"name": step.name, "role": step.role, "env": P.session_env(path), "command": command,
                "token_file": str(role.token_file) if role.token_file else None}
        (d / "step.json").write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")
        return d

    def create_args(self, step: Step, spec: dict) -> list[str]:
        """`docker create`'s arguments: a TTY for the interactive session, the capabilities the entrypoint
        needs and no others, no new privileges, IPv6 off, exactly two read-only mounts, the environment
        (the subscription token by name only), a label for cleanup."""
        args = ["create", "-t", "-i", "--name", f"km-e2e-{self.run_id}-{step.name}",
                "--label", f"km-e2e.run={self.run_id}", "--cap-drop", "ALL", *(a for c in CAPS for a in ("--cap-add", c)),
                "--security-opt", "no-new-privileges", "--sysctl", "net.ipv6.conf.all.disable_ipv6=1",
                "--pids-limit", "2048", "--memory", "6g", "-w", P.CLONE]
        if self.plugin_dir and self.uses_plugin(step):
            args += ["-v", f"{self.plugin_dir.resolve()}:{P.PLUGIN}:ro"]
        if spec.get("token_file"):
            args += ["-v", f"{Path(spec['token_file']).resolve()}:{P.GH_TOKEN}:ro"]
        for k, v in spec["env"].items():
            args += ["-e", f"{k}={v}"]
        args += ["-e", "CLAUDE_CODE_OAUTH_TOKEN"]
        return [*args, self.image, *spec["command"]]

    def create(self, step: Step, d: Path) -> str:
        """Create the container and copy the staging folder, the clone and the extra folders in."""
        spec = json.loads((d / "step.json").read_text(encoding="utf-8"))
        env = os.environ | {"CLAUDE_CODE_OAUTH_TOKEN": P.claude_token()}
        cid = docker(*self.create_args(step, spec), env=env).stdout.decode().strip()
        try:
            docker("cp", f"{d / 'opt'}/.", f"{cid}:{P.STEP}")
            docker("cp", str(d / "managed-settings.json"), f"{cid}:{P.MANAGED}")
            docker("cp", f"{d / 'config'}/.", f"{cid}:{P.CONFIG}")
            docker("cp", f"{step.cwd}/.", f"{cid}:{P.CLONE}", timeout=600)
            for a in step.add_dirs:
                docker("cp", f"{a}/.", f"{cid}:{inside(a)}", timeout=600)
        except BaseException:
            self.remove(cid)
            raise
        return cid

    def remove(self, cid: str) -> None:
        docker("rm", "-f", cid, check=False, timeout=60)

    def pull(self, cid: str, path: str) -> dict[str, tuple[float, bytes]]:
        """The regular files under PATH in the container (running or stopped), relative to PATH's parent.
        The tar stream is read only up to MAX_FILE and a little more: past that the copy is stopped and
        nothing is returned, so a file a session grew (a sparse one, say) never reaches the driver's memory."""
        p = subprocess.Popen(["docker", "cp", f"{cid}:{path}", "-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL)
        buf, end = bytearray(), time.time() + 120
        assert p.stdout is not None
        while len(buf) <= MAX_FILE + (1 << 20) and time.time() < end and (chunk := p.stdout.read(1 << 16)):
            buf += chunk
        over = len(buf) > MAX_FILE + (1 << 20) or time.time() >= end
        if over:
            p.kill()                       # our own child, by its handle
        p.stdout.close()
        rc = p.wait()
        return {} if over or rc != 0 else regular_files(bytes(buf))

    def listing(self, cid: str) -> dict[str, tuple[float, int]]:
        """The Stop hook's file (key "done") and every transcript of the running container's config folder
        (relative to it), with mtime and size: one `find` as the session user, NUL-separated, so no file
        name a session chose can split an entry. Empty when the container does not answer."""
        r = docker("exec", "-u", "node", cid, "/usr/bin/find", P.DONE, f"{P.CONFIG}/projects", "-type", "f",
                   "-printf", "%T@ %s %p\\0", check=False, timeout=30)
        out: dict[str, tuple[float, int]] = {}
        for entry in r.stdout.decode(errors="replace").split("\0"):
            stamp, size, path = (entry.split(" ", 2) + ["", ""])[:3]
            try:
                meta = (float(stamp), int(size))
            except ValueError:
                continue
            rel = path.removeprefix(f"{P.CONFIG}/")
            if path == P.DONE:
                out["done"] = meta
            elif rel.startswith("projects/") and rel.endswith(".jsonl"):
                out[rel] = meta
        return out

    def fetch(self, cid: str, rel: str, size: int) -> bytes:
        """One transcript's content (up to MAX_FILE: a larger file is left out, never read)."""
        return b"" if size > MAX_FILE else self.pull(cid, f"{P.CONFIG}/{rel}").get(Path(rel).name, (0.0, b""))[1]

    def watch(self, cid: str, session_id: str) -> Callable[[], tuple]:
        """The polling state for wait_done: every transcript's mtime from listing(), and content only for
        the session's own transcript, once the Stop hook has written and the transcript changed."""
        main, cache = f"/{session_id}.jsonl", {}

        def state() -> tuple:
            got = self.listing(cid)
            done = (got.pop("done")[0], b"") if "done" in got else None
            files = {rel: (mtime, b"") for rel, (mtime, _) in got.items()}
            for rel, (mtime, size) in got.items():
                if done and rel.endswith(main) and rel.count("/") == 2:
                    if cache.get(rel, (None,))[0] != mtime:
                        cache[rel] = (mtime, self.fetch(cid, rel, size))
                    files[rel] = cache[rel]
            return done, files
        return state

    def alive(self, cid: str) -> bool:
        r = docker("inspect", "-f", "{{.State.Running}}", cid, check=False, timeout=30)
        return r.stdout.decode().strip() == "true"

    def screen(self, cid: str) -> str:
        r = docker("logs", "--tail", "80", cid, check=False, timeout=30)
        return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07", "", (r.stdout + r.stderr).decode(errors="replace"))

    def rejected(self, cid: str) -> int:
        """Outbound connections the firewall refused: the packet counter of its own reject chain, read as root."""
        r = docker("exec", "-u", "0", "-e", "PATH=/usr/sbin:/usr/bin:/sbin:/bin", cid, "/usr/sbin/iptables", "-nvxL", "KM_REJECT",
                   check=False, timeout=30)
        rows = [ln.split() for ln in r.stdout.decode(errors="replace").splitlines()[2:] if ln.split()[2:3] == ["REJECT"]]
        return int(rows[0][0]) if r.returncode == 0 and len(rows) == 1 and rows[0][0].isdigit() else -1

    # --- a session ---------------------------------------------------------------------------------
    def run(self, step: Step) -> Outcome:
        if found := agent_config_in(step.cwd, *step.add_dirs):
            raise SystemExit(f"e2e: {found[0]} would steer the session (agent configuration in a folder it opens): stopping")
        d = self.prepare(step)
        cid = self.create(step, d)
        keep = self.rundir / "agents" / step.name
        keep.mkdir(parents=True, exist_ok=True)
        try:
            docker("start", cid)
            sid = self.session_ids[step.name]
            out = wait_done(self.watch(cid, sid), sid, step.timeout, step.quiet, alive=lambda: self.alive(cid),
                            screen=lambda: self.screen(cid))
            rejected, listed = self.rejected(cid), self.listing(cid)
            listed.pop("done", None)
            docker("stop", "-t", "5", cid, check=False, timeout=60)
            kept = []                              # the authoritative copies, after the session ended
            for rel, (_, size) in sorted(listed.items()):
                data = self.fetch(cid, rel, size)
                f = keep / "transcripts" / safe_name(rel)
                f.parent.mkdir(exist_ok=True)
                f.write_bytes(data)
                kept.append(str(f))
                if rel.endswith(f"/{sid}.jsonl") and rel.count("/") == 2:
                    out.transcript = str(f)
                    out.text = J.final_text_of(data.decode("utf-8", errors="replace")) or out.text
            for rel in step.collect:
                got = self.pull(cid, f"{P.CLONE}/{rel}").get(Path(rel).name)
                if got is not None:
                    (keep / "files").mkdir(exist_ok=True)
                    (keep / "files" / safe_name(rel)).write_bytes(got[1])
            out.transcripts, out.rejected = kept, rejected
        finally:
            self.remove(cid)
        (keep / "outcome.json").write_text(json.dumps(asdict(out), indent=2) + "\n", encoding="utf-8")
        return out

    def close(self) -> None:
        """Remove every container of this run (by id) and the staging folders."""
        r = docker("ps", "-aq", "--filter", f"label=km-e2e.run={self.run_id}", check=False, timeout=60)
        for cid in r.stdout.decode().split():
            self.remove(cid)
        shutil.rmtree(self.sessions, ignore_errors=True)


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


def session_files(files: dict[str, tuple[float, bytes]], session_id: str) -> tuple[bytes | None, float]:
    """The session's own transcript (`<project>/<id>.jsonl`, found by the driver's id, not by a path a
    hook input names) and the newest change to it or its subagents' transcripts (`<project>/<id>/...`)."""
    main = [v for k, v in files.items() if k.count("/") == 2 and k.endswith(f"/{session_id}.jsonl")]
    side = [v[0] for k, v in files.items() if f"/{session_id}/" in k]
    if len(main) != 1:
        return None, max(side, default=0.0)
    return main[0][1], max([main[0][0], *side])


def wait_done(state: Callable[[], tuple], session_id: str, timeout: float, quiet: float, alive=lambda: True,
              every: float = 5, grace: float = 120, screen=lambda: "") -> Outcome:
    """Wait until the Stop hook's file exists, the session's transcript ends with an assistant message
    whose last line is the sentinel, and neither changed for QUIET seconds (by their own mtimes, so a
    slow read does not count as quiet); or until TIMEOUT, or the session is gone. A session that has
    written no transcript after GRACE seconds sits on a dialog: stop with SCREEN's text. STATE returns
    (done, transcripts) as Launcher.state does."""
    t0, text, seen = time.time(), "", None
    quiet_since = t0
    while True:
        done, files = state()
        raw, newest = session_files(files, session_id)
        if raw is not None:
            text = J.final_text_of(raw.decode("utf-8", errors="replace"))
        stamp = (done[0] if done else None, newest)
        if stamp != seen:
            seen, quiet_since = stamp, time.time()
        if done and raw is not None and J.finished(text) and time.time() - quiet_since >= quiet:
            return Outcome(True, text, None, time.time() - t0)
        if raw is None and not done and time.time() - t0 > grace:
            shown = " | ".join(ln.strip() for ln in screen().splitlines() if ln.strip())[-600:]
            return Outcome(False, text, None, time.time() - t0, f"no transcript after {grace:.0f} s; the screen shows: {shown}")
        if time.time() - t0 > timeout:
            return Outcome(False, text, None, time.time() - t0, f"no finished session after {timeout:.0f} s")
        if not alive():
            return Outcome(False, text, None, time.time() - t0, "the session ended without the sentinel")
        time.sleep(every)
