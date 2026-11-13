"""Run the agent layer of the km e2e test: `python3 e2e/agent_run.py [options]`. See e2e/README-agents.md.

The same preflight, lock, reset and cleanup as run.py, plus the agent preflight (the clean profile is
logged in by subscription and holds no user instructions, memory or MCP servers; the role environment
reaches the sandbox and nothing it must not). Then E01 (main on the candidate), the deterministic
scenarios whose PRs the queue needs, the agent scenarios one after the other, and E22 last.

`--canary` runs one trivial session in the profile and writes nothing to GitHub: the first thing to
run after the one-time login.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent_profile as P                 # noqa: E402
import agent_scenarios as A               # noqa: E402
import run as R                           # noqa: E402
import scenarios as S                     # noqa: E402
from agent_judge import leaks             # noqa: E402
from agent_launch import SANDBOX_EXEC, Launcher, Role, Step, role_env   # noqa: E402
from lib import Config, Ctx, Record       # noqa: E402

say = R.say


class PluginExport:
    """km at the candidate commit, the plugin every role session loads (--plugin-dir): exported fresh
    for each run with `git archive` beside the workdir (agent_profile.plugin_root: sessions may read it,
    not write it), made read-only, and verified against its own fingerprint before every session, so a
    session cannot change what a later one loads."""

    def __init__(self, ctx: Ctx):
        cfg = ctx.cfg
        root = P.plugin_root(cfg.workdir)
        mirror, self.dir = root / "km.git", root / ctx.run_id
        if not mirror.is_dir():
            root.mkdir(parents=True, exist_ok=True)
            ctx.git("M", None, "clone", "-q", "--bare", cfg.km_url, str(mirror))
        ctx.git("M", mirror, "fetch", "-q", cfg.km_url, cfg.candidate)
        if ctx.git("M", mirror, "rev-parse", "--verify", f"{cfg.candidate}^{{commit}}").strip() != cfg.candidate:
            raise SystemExit("e2e: KM_E2E_CANDIDATE_REF must be a full commit sha for the agent layer")
        self.dir.mkdir(parents=True)
        git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=", "-C", str(mirror)]
        env = os.environ | {"GIT_NO_REPLACE_OBJECTS": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        tar = subprocess.run([*git, "archive", cfg.candidate], env=env, capture_output=True, check=True, timeout=300)
        subprocess.run(["tar", "-x", "-C", str(self.dir)], input=tar.stdout, check=True, timeout=300)
        # every file of the export hashes to the blob the candidate's tree names (no object was swapped)
        tree = subprocess.run([*git, "ls-tree", "-r", "-z", cfg.candidate], env=env, capture_output=True, check=True,
                              timeout=300).stdout.decode().strip("\0").split("\0")
        want = {e.split("\t", 1)[1]: e.split()[2] for e in tree if e.split()[1] == "blob"}
        paths = sorted(want)
        got = subprocess.run([*git, "hash-object", "--no-filters", "--stdin-paths"], env=env, input="\n".join(
            str(self.dir / p) for p in paths), capture_output=True, text=True, check=True, timeout=300).stdout.split()
        if got != [want[p] for p in paths]:
            raise SystemExit("e2e: the km plugin export does not match the candidate's tree: stopping")
        subprocess.run(["chmod", "-R", "a-w", str(self.dir)], check=True)
        self.fingerprint = self.digest()

    def digest(self) -> str:
        h = hashlib.sha256()
        for f in sorted(self.dir.rglob("*")):
            st = f.lstat()
            h.update(f"{f.relative_to(self.dir).as_posix()}\0{st.st_mode}\0".encode())
            if f.is_symlink():
                h.update(os.readlink(f).encode())
            elif f.is_file():
                h.update(f.read_bytes())
        return h.hexdigest()

    def verify(self) -> None:
        if self.digest() != self.fingerprint:
            raise SystemExit(f"e2e: the km plugin export {self.dir} changed during the run: stopping")

    def remove(self) -> None:
        subprocess.run(["chmod", "-R", "u+w", str(self.dir)], check=False)
        shutil.rmtree(self.dir, ignore_errors=True)


def launcher(ctx: Ctx, plugin: PluginExport) -> Launcher:
    """The run's launcher. Before every session it checks that the plugin export and the profile are
    still what they were (the profile's fingerprint is taken here, before the first session)."""
    cfg = ctx.cfg
    name, email = ctx.ident("C")
    profile = P.Fingerprint(P.profile_dir())
    verify = lambda: (plugin.verify(), profile.verify())   # noqa: E731
    return Launcher(ctx.dir, P.profile_dir(), plugin.dir, {"C": Role(cfg.contrib_token_file, name, email)},
                    socket=f"km-e2e-{ctx.run_id}", sessions=Path(P.SESSIONS).expanduser(), verify=verify)


def call(env: dict, *cmd: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60, cwd=cwd)
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(cmd, 127, "", f"{type(e).__name__}: {e}")


# a keychain read through the Security framework, as any program in a session could make it: prints
# "denied" unless it gets an item
KEYCHAIN_PROBE = """
import ctypes, ctypes.util
sec = ctypes.cdll.LoadLibrary(ctypes.util.find_library("Security"))
sec.SecKeychainFindGenericPassword.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32,
    ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
n, data, svc = ctypes.c_uint32(), ctypes.c_void_p(), b"gh:github.com"
st = sec.SecKeychainFindGenericPassword(None, len(svc), svc, 0, None, ctypes.byref(n), ctypes.byref(data), None)
print("read" if st == 0 else "denied")
"""


def agent_preflight(ctx: Ctx, ln: Launcher) -> list[str]:
    """The agent layer's own checks, on top of run.py's: the profile, then the role environment exactly as
    a session gets it (its gh wrapper and git credential helper)."""
    cfg = ctx.cfg
    bad = P.check(ln.profile, cfg.workdir)
    probe = cfg.workdir / "agent-preflight" / ctx.run_id
    probe.mkdir(parents=True, exist_ok=True)
    d = ln.prepare(Step(f"preflight-{ctx.run_id}", "C", probe, ""))
    spec = json.loads((d / "step.json").read_text(encoding="utf-8"))
    env = role_env(spec)
    token = cfg.contrib_token_file.read_text(encoding="utf-8").strip()
    if not token:
        return bad + ["C's token file is empty"]
    if "GH_TOKEN" in env or any(token in v for v in env.values()):
        bad.append("the session environment holds the token")
    if call(env, "gh", "api", "user", "-q", ".login").stdout.strip() != cfg.contrib:
        bad.append("the role environment's gh is not C")
    if call(env, "gh", "auth", "status", "--hostname", "github.com").returncode != 0:
        bad.append("`gh auth status` fails in the role environment (the km skill checks it before using gh)")
    for args in (("auth", "token"), ("auth", "status", "--show-token")):
        if call(env, "gh", *args).returncode == 0:
            bad.append(f"`gh {' '.join(args)}` answers in the role environment")
    for slug in cfg.must_not_reach:
        if "HTTP 404" not in call(env, "gh", "api", f"repos/{slug}").stderr:
            bad.append("the role environment's gh reaches a repository it must not (no 404)")
        if call(env, "git", "ls-remote", "--heads", f"https://github.com/{slug}.git").returncode == 0:
            bad.append("git in the role environment can read a repository it must not")
    if call(env, "git", "ls-remote", "--heads", f"https://github.com/{cfg.fork}.git").returncode != 0:
        bad.append("git in the role environment cannot read C's fork (credential helper)")
    jail = [SANDBOX_EXEC, "-f", spec["sandbox"]]
    if call(env, *jail, "cat", str(cfg.maint_token_file)).returncode == 0:
        bad.append("the session sandbox lets a session read M's token file")
    if call(env, *jail, "touch", str(Path.home() / f".km-e2e-sandbox-probe-{ctx.run_id}")).returncode == 0:
        (Path.home() / f".km-e2e-sandbox-probe-{ctx.run_id}").unlink(missing_ok=True)
        bad.append("the session sandbox lets a session write to the home folder")
    if call(env, *jail, P.claude_bin(), "--version").returncode != 0:
        bad.append("claude does not start inside the session sandbox")
    # nothing started outside the sandbox (Launch Services, Apple Events), no pasteboard, no other files
    for cmd in (("/usr/bin/osascript", "-e", "return 1"), ("/usr/bin/open", "-g", "-R", "/tmp"), ("/usr/bin/pbpaste",)):
        if call(env, *jail, *cmd).returncode == 0:
            bad.append(f"the session sandbox lets a session run {cmd[0]}")
    home = Path.home()
    for path in (".git-credentials", ".docker", "Library/Keychains", "git", ".claude-work", ".claude", ".ssh"):
        if call(env, *jail, "/bin/ls", str(home / path)).returncode == 0:
            bad.append(f"the session sandbox lets a session read ~/{path}")
    ctx.egress_restricted = call(env, *jail, "/usr/bin/curl", "-sS", "-m", "8", "-o", "/dev/null",
                                 "https://example.com").returncode != 0
    if uv := shutil.which("uv"):        # the plugin's km runs under uv; without it km falls back to python3
        r = call(env, *jail, uv, "run", "--quiet", "--no-config", "--no-project", "--python", ">=3.11", "--with",
                 "pyyaml==6.0.3", "python", "-P", "-c", "import yaml", cwd=probe)
        if r.returncode != 0:
            say(f"warning: uv does not start inside the session sandbox; km falls back to python3: {r.stderr.strip()[-200:]}")
    # the keychain holds the person's own logins (gh's for the real organisation among them)
    if call(env, *jail, "/usr/bin/security", "find-generic-password", "-s", "gh:github.com").returncode == 0:
        bad.append("the session sandbox lets `security` read the keychain")
    r = call(env, *jail, "python3", "-I", "-c", KEYCHAIN_PROBE, cwd=probe)
    if r.stdout.strip() != "denied":
        bad.append("the session sandbox lets the Security framework read the keychain" if r.stdout.strip() == "read"
                   else f"the keychain probe did not run in the session sandbox: {r.stderr.strip()[-200:]}")
    wrapper = spec["path_extra"][0]
    bare = env | {"PATH": os.pathsep.join(p for p in env["PATH"].split(os.pathsep) if p != wrapper)}
    if call(bare, "gh", "api", "user").returncode == 0:
        bad.append("without the role's wrapper gh still has a login (an ambient credential): the role env is not isolated")
    return bad


def adversary_refused(only: set[str], token: bool, egress_restricted: bool) -> set[str]:
    """The scenarios of ONLY that may not run: those whose session reads text an adversary wrote, while
    the session holds the subscription token (TOKEN) and the preflight found outbound network open."""
    return set() if egress_restricted or not token else only & A.ADVERSARY


def must_not_name(cfg: Config) -> list[str]:
    """What no transcript may name: the repositories the roles must not reach and their owners. (The
    deny list is for public text: it names the sandbox's own logins, which a transcript shows anyway.)"""
    return sorted({*cfg.must_not_reach, *(s.split("/")[0] for s in cfg.must_not_reach)})


def agents(ctx: Ctx, ln: Launcher, model_judge: bool) -> A.Agents:
    files = (ctx.cfg.contrib_token_file, ctx.cfg.maint_token_file)
    return A.Agents(ctx, ln, model_judge=model_judge, terms=must_not_name(ctx.cfg),
                    secrets=tuple(t for t in (*(f.read_text(encoding="utf-8").strip() for f in files if f),
                                              P.claude_token()) if t))


def canary(ctx: Ctx, ln: Launcher) -> int:
    """One trivial session: trust, permissions, plugin, hook, transcript and the role login, end to end."""
    d = ctx.cfg.workdir / "canary" / ctx.run_id
    d.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(d)], check=True)
    rec = Record("canary", "one trivial session in the clean profile")
    a = agents(ctx, ln, model_judge=False)
    out = A.run_agent(a, rec, Step("canary", "C", d, (A.PROMPTS / "canary.md").read_text(encoding="utf-8"), timeout=600, quiet=10))
    version = json.loads((ln.plugin_dir / ".claude-plugin" / "plugin.json").read_text())["version"] if ln.plugin_dir else ""
    rec.check("the session wrote canary.txt (Write allowed in the workdir)",
              (d / "canary.txt").is_file() and (d / "canary.txt").read_text().strip() == "ok", "ok", (d / "canary.txt").exists())
    rec.check("gh in the session is C", ctx.cfg.contrib in out.text, ctx.cfg.contrib, out.text[-300:])
    rec.check("km from the candidate plugin runs", version and version in out.text, version, out.text[-300:])
    rec.check("no instruction file from outside the canary folder", "/.claude/CLAUDE.md" not in out.text
              and not leaks(out.text, ["CLAUDE.local.md"]), "none named", out.text[-300:])
    for c in rec.checks:
        say(f"{'ok' if c.ok else 'FAIL'}: {c.what} (observed: {c.observed})")
    return 0 if R.grade(rec) == "pass" else 1


def main() -> int:
    ap = argparse.ArgumentParser(prog="agent_run.py")
    ap.add_argument("--only", help="comma-separated agent scenario ids (E02a, E14, E26, E26-noscript, E22)")
    ap.add_argument("--skip-reset", action="store_true", help="run on the sandbox as it is (no E01, no preconditions)")
    ap.add_argument("--run-id", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S-a")
                    + os.urandom(2).hex())
    ap.add_argument("--steal-lock", action="store_true")
    ap.add_argument("--preflight", action="store_true", help="only the preflights (run.py's and the agent layer's)")
    ap.add_argument("--canary", action="store_true", help="one trivial session; writes nothing to GitHub")
    ap.add_argument("--no-model-judge", action="store_true", help="hard checks only, no model verdicts")
    a = ap.parse_args()
    ctx = Ctx(Config.from_env(), a.run_id)
    try:
        return run(ctx, a)
    finally:
        ctx.close()


def run(ctx: Ctx, a: argparse.Namespace) -> int:
    t0, start = time.time(), R.now()
    ctx.started = start                    # lib reads it where it has it (the newest runs, for waiting)
    say(f"agent run {ctx.run_id}: sandbox {ctx.cfg.slug}, candidate {ctx.cfg.candidate[:7]}")
    if not ctx.cfg.contrib_token_file:
        say("preflight: the agent layer needs KM_E2E_CONTRIB_TOKEN_FILE (a session cannot use a gh config fallback)")
        return 2
    if not shutil.which("tmux"):
        say("preflight: tmux is not installed")
        return 2
    if not SANDBOX_EXEC:
        say("preflight: the agent layer runs sessions under macOS sandbox-exec, which is not here")
        return 2
    P.setup(P.profile_dir(), ctx.cfg.workdir)   # settings, hook and first-run marks again: a login may change them
    # every git the driver runs: no fsmonitor, pager or hooks from a repository's own config
    os.environ["GIT_CONFIG_PARAMETERS"] = "'core.fsmonitor=' 'core.pager=cat' 'core.hooksPath=/dev/null'"
    ids = {s[0] for s in A.AGENT}
    only = set(a.only.split(",")) if a.only else ids
    if unknown := only - ids:
        say(f"unknown agent scenario ids {sorted(unknown)}; known: {sorted(ids)}")
        return 2
    if bad := R.preflight(ctx):
        for b in bad:
            say(f"preflight: {b}")
        return 2
    plugin = PluginExport(ctx)
    ln = launcher(ctx, plugin)
    try:
        if bad := agent_preflight(ctx, ln):
            for b in bad:
                say(f"preflight: {b}")
            return 2
        say("preflight ok")
        if a.preflight:
            return 0
        if a.canary:
            return canary(ctx, ln)
        if refused := adversary_refused(only, bool(P.claude_token()), getattr(ctx, "egress_restricted", False)):
            say(f"refused: {sorted(refused)} let a session read adversary-written text while it holds the subscription "
                "token and can reach any host; run them only behind an egress restriction (--only without them)")
            return 2
        return scenarios(ctx, a, ln, only, t0, start)
    finally:
        ln.close()
        plugin.remove()


def scenarios(ctx: Ctx, a: argparse.Namespace, ln: Launcher, only: set[str], t0: float, start: str) -> int:
    ag = agents(ctx, ln, model_judge=not a.no_model_judge)
    bind = lambda fn: (lambda c, rec: fn(ag, rec))   # noqa: E731
    meta: dict = {"run_id": ctx.run_id, "candidate": ctx.cfg.candidate, "baseline": ctx.cfg.baseline, "started": start,
                  "layer": "agent"}
    recs: list[Record] = []
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    locked = False
    try:
        R.take_lock(ctx, a.steal_lock)
        locked = True
        if not a.skip_reset:
            meta["reset"] = R.reset(ctx)
        R.actions(ctx, True)
        if not a.skip_reset:
            recs.append(R.run_one(ctx, *S.FIRST))
            if recs[-1].result != "pass":
                say("E01 did not pass: stopping")
                return 1
            S.sync_fork(ctx, recs[-1])
            if "E22" in only:            # the open PRs the queue lists
                pre = [s for s in S.PARALLEL if s[0] in A.PRECONDITIONS]
                with ThreadPoolExecutor(max_workers=len(pre)) as pool:
                    recs += list(pool.map(lambda s: R.run_one(ctx, *s), pre))
        for sid, fn, title in A.AGENT:
            if sid in only:
                recs.append(R.run_one(ctx, sid, bind(fn), title))
    finally:
        if locked and not R.holds_lock(ctx):
            say("warning: the lock no longer names this run: leaving the sandbox as it is")
            locked = False
        for _, step, if_failed in R.cleanup_steps(locked, meta, start):
            try:
                step(ctx)
            except BaseException as e:
                say(f"warning: {if_failed} ({type(e).__name__}: {e})")
        if locked:
            meta["wall_seconds"] = time.time() - t0
            try:
                R.report(ctx, meta, recs)
            except BaseException as e:
                say(f"warning: could not write the report ({type(e).__name__}: {e})")
    return 0 if all(r.result in ("pass", "skip") for r in R.flat(recs)) else 1


if __name__ == "__main__":
    sys.exit(main())
