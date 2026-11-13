"""Run the agent layer of the km e2e test: `python3 e2e/agent_run.py [options]`. See e2e/README-agents.md.

The same preflight, lock, reset and cleanup as run.py, plus the agent preflight (the image and the
subscription token; a container built as a session's: its egress probed against a control container
without the firewall, its mounts and capabilities, the role's GitHub access and Claude Code's login
from inside). Then E01 (main on the candidate), the deterministic scenarios whose PRs the queue needs,
the agent scenarios one after the other, each in a fresh container, and E22 last.

`--canary` runs one trivial session and writes nothing to GitHub: the first thing to run after
building the image.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent_profile as P                 # noqa: E402
import agent_scenarios as A               # noqa: E402
import run as R                           # noqa: E402
import scenarios as S                     # noqa: E402
from agent_judge import holds_secret, leaks   # noqa: E402
from agent_launch import CAPS, REAL_GH, Launcher, Role, Step, docker   # noqa: E402
from lib import ApiError, Config, Ctx, Record   # noqa: E402

say = R.say


class PluginExport:
    """km at the candidate commit, the plugin every role session loads (--plugin-dir): exported fresh
    for each run with `git archive` beside the workdir (agent_profile.plugin_root: sessions may read it,
    not write it), checked file by file against the candidate's tree, made read-only and mounted
    read-only into every session's container."""

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
        self.version = json.loads((self.dir / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))["version"]

    def remove(self) -> None:
        subprocess.run(["chmod", "-R", "u+w", str(self.dir)], check=False)
        shutil.rmtree(self.dir, ignore_errors=True)


# the names a session may reach (pinned in its /etc/hosts; GitHub's ranges come from api.github.com/meta)
ALLOWED_HOSTS = ("github.com", "api.github.com", "api.anthropic.com")


def firewall_input(ctx: Ctx) -> Path:
    """The firewall's input for every container of the run, read once per run: GitHub's web, api and git
    IPv4 ranges (api.github.com/meta) and an address for each allowed name, so a container needs no
    resolver at all."""
    net = ctx.dir / "net"
    net.mkdir(parents=True, exist_ok=True)
    meta = ctx.api("M", "meta")
    cidrs = sorted({c for k in ("web", "api", "git") for c in meta.get(k) or [] if ":" not in c})
    if not cidrs:
        raise SystemExit("e2e: api.github.com/meta names no IPv4 ranges for web, api and git")
    (net / "github-cidrs").write_text("\n".join(cidrs) + "\n", encoding="utf-8")
    pins = [f"{socket.getaddrinfo(h, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]} {h}" for h in ALLOWED_HOSTS]
    (net / "hosts").write_text("\n".join(pins) + "\n", encoding="utf-8")
    return net


def launcher(ctx: Ctx, plugin: PluginExport) -> Launcher:
    """The run's launcher."""
    cfg = ctx.cfg
    name, email = ctx.ident("C")
    return Launcher(ctx.dir, plugin.dir, {"C": Role(cfg.contrib_token_file, name, email, repos=(cfg.slug, cfg.fork))}, ctx.run_id,
                    sessions=Path(P.SESSIONS).expanduser(), net=firewall_input(ctx))


class Listener:
    """A TCP listener on the host's loopback for the probes: a container that reaches the host through
    host.docker.internal connects to it. It counts what it accepted."""

    def __init__(self):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.port, self.accepted = self.sock.getsockname()[1], 0
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            self.accepted += 1
            c.close()

    def settled(self, wait: float = 3) -> int:
        """The count once a connection made just before has had time to be accepted."""
        time.sleep(wait)
        return self.accepted

    def close(self) -> None:
        self.sock.close()


def lan_gateway() -> str:
    """The host's own default gateway (a LAN address a container must not reach)."""
    r = subprocess.run(["route", "-n", "get", "default"] if sys.platform == "darwin" else ["ip", "route", "show", "default"],
                       capture_output=True, text=True, timeout=30)
    m = re.search(r"(?:gateway:|via)\s+(\d+\.\d+\.\d+\.\d+)", r.stdout)
    return m.group(1) if m else ""


# The egress probe, the same in the firewalled container and in the control container without the
# firewall: each target answers reach or blocked, all at once; the control proves each deny probe can bite.
DENY = {   # name: (address, port), as shell words ({host}, {port}, {lan} filled in)
    "public_ip": ("1.1.1.1", "443"), "host_loopback": ("{host}", "{port}"),
    "docker_gateway": ('"$(ip route | awk \'/^default/ {{print $3}}\')"', "443"),
    "lan_gateway_http": ("{lan}", "80"), "lan_gateway_https": ("{lan}", "443"), "metadata": ("169.254.169.254", "80"),
    "ssh_github": ('"$(getent hosts github.com | awk \'{{print $1}}\' | head -1)"', "22"), "name_example": ("example.com", "443")}
ALLOW = ("https://api.github.com/zen", "https://github.com", "https://api.anthropic.com")
EGRESS = (r"""t() {{ if timeout 6 bash -c "exec 3<>/dev/tcp/$2/$3" 2>/dev/null; then echo "$1=reach"; else echo "$1=blocked"; fi; }}
""" + "".join(f"t {k} {h} {p} &\n" for k, (h, p) in DENY.items()) + r"""
{{ timeout 6 dig +short +time=2 +tries=1 @1.1.1.1 example.com 2>/dev/null | grep -Eq '^[0-9.]+$' && echo dns_direct=reach || echo dns_direct=blocked; }} &
{{ timeout 6 getent hosts example.com >/dev/null 2>&1 && echo dns_lookup=reach || echo dns_lookup=blocked; }} &
{{ timeout 6 bash -c 'exec 3<>/dev/tcp/2606:4700:4700::1111/443' 2>/dev/null && echo ipv6=reach || echo ipv6=blocked; }} &
""" + "".join(f'{{{{ curl -sS -m 15 -o /dev/null {u} 2>/dev/null && echo "allowed {u}=reach" || echo "allowed {u}=blocked"; }}}} &\n'
              for u in ALLOW) + "wait\n")
DENIED = (*DENY, "dns_direct", "dns_lookup", "ipv6")
# the deny probes the control must find open (the others have nothing to answer on this machine)
CONTROLLED = ("public_ip", "host_loopback", "name_example", "dns_direct", "dns_lookup")
ALLOWED = tuple(f"allowed {u}" for u in ALLOW)
# the session's own environment: the user, its capabilities, the role's GitHub access, Claude Code and km
SESSION = r"""
echo "uid=$(id -u)"
awk '/^(CapEff|CapBnd|NoNewPrivs):/ {{sub(":", "", $1); print $1 "=" $2}}' /proc/self/status
if iptables -S >/dev/null 2>&1; then echo iptables=changeable; else echo iptables=denied; fi
if touch /etc/claude-code/x 2>/dev/null || touch /opt/km/x 2>/dev/null || touch /opt/km-e2e/x 2>/dev/null; then echo protected=writable; else echo protected=readonly; fi
echo "gh_login=$(gh api user -q .login 2>/dev/null)"
gh auth status --hostname github.com >/dev/null 2>&1; echo "gh_auth_status=$?"
gh auth token >/dev/null 2>&1; echo "gh_auth_token=$?"
gh auth status --show-token >/dev/null 2>&1; echo "gh_show_token=$?"
for s in {must_not}; do
  GH_TOKEN="$(cat {token})" {gh} api "repos/$s" 2>&1 | grep -q "HTTP 404" && echo "must_not_gh=404" || echo "must_not_gh=reached"
  gh api "repos/$s" >/dev/null 2>&1 && echo "must_not_wrapper=passed" || echo "must_not_wrapper=refused"
  git ls-remote --heads "https://github.com/$s.git" >/dev/null 2>&1 && echo "must_not_git=read" || echo "must_not_git=refused"
done
git ls-remote --heads "https://github.com/{fork}.git" >/dev/null 2>&1; echo "fork_git=$?"
env PATH="${{PATH#*:}}" gh api user >/dev/null 2>&1; echo "bare_gh=$?"
echo "uv_gh=$(cd /tmp && uv run --quiet --no-config --no-project --python '>=3.11' python -c 'import shutil; print(shutil.which("gh"))' 2>&1)"
echo "claude_auth=$(claude auth status --json 2>/dev/null | tr -d '\n')"
echo "km=$(km --version 2>&1 | tail -1)"
"""


def parse(out: str) -> dict[str, list[str]]:
    got: dict[str, list[str]] = {}
    for ln in out.splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            got.setdefault(k.strip(), []).append(v.strip())
    return got


def control(ln: Launcher, port: int, lan: str) -> tuple[dict[str, list[str]], str]:
    """The egress probe in a container of the same image without the firewall (its entrypoint skipped,
    the session user, no extra capability): what each deny probe would reach if the firewall failed. Also
    returns the address host.docker.internal stands for."""
    script = "host=$(getent hosts host.docker.internal | awk '{print $1}'); echo hdi=$host\n" + \
        EGRESS.format(host="$host", port=port, lan=lan)
    r = docker("run", "--rm", "--label", f"km-e2e.run={ln.run_id}", "--entrypoint", "/bin/bash", "-u", "node",
               "--cap-drop", "ALL", ln.image, "-c", script, check=False, timeout=300)
    got = parse(r.stdout.decode(errors="replace"))
    return got, (got.get("hdi") or [""])[0]


def inspect_ok(info: dict, plugin_dir: Path, token_file: Path) -> list[str]:
    """The probe container as Docker sees it: exactly the two read-only mounts, the entrypoint's
    capabilities and no others, nothing shared with the host."""
    bad, hc = [], info["HostConfig"]
    want = {(P.PLUGIN, False), (P.GH_TOKEN, False)}
    mounts = {(m["Destination"], bool(m["RW"])) for m in info.get("Mounts") or []}
    if mounts != want:
        bad.append(f"the session container's mounts are {sorted(mounts)}, not the plugin and the token file read-only")
    srcs = {m["Destination"]: m["Source"] for m in info.get("Mounts") or []}
    if not (srcs.get(P.PLUGIN, "").endswith(str(plugin_dir.resolve())) and srcs.get(P.GH_TOKEN, "").endswith(str(token_file.resolve()))):
        bad.append("a session container mount comes from another host path than the plugin export or C's token file")
    norm = lambda caps: {c.upper().removeprefix("CAP_") for c in caps or []}   # noqa: E731
    if norm(hc.get("CapAdd")) != set(CAPS) or norm(hc.get("CapDrop")) != {"ALL"}:
        bad.append(f"the session container's capabilities are not exactly the entrypoint's: {hc.get('CapAdd')} / {hc.get('CapDrop')}")
    if hc.get("Privileged") or hc.get("PidMode") or hc.get("IpcMode") == "host" or hc.get("UTSMode") or hc.get("Devices") \
            or hc.get("NetworkMode") not in ("default", "bridge") or hc.get("PortBindings") or hc.get("VolumesFrom"):
        bad.append("the session container shares something with the host (privileged, pid, ipc, network, devices or ports)")
    if "no-new-privileges" not in (hc.get("SecurityOpt") or []):
        bad.append("the session container lacks no-new-privileges")
    return bad


def agent_preflight(ctx: Ctx, ln: Launcher, version: str) -> tuple[list[str], bool]:
    """The agent layer's own checks, on top of run.py's: the image and the token, then a container built
    exactly as a session's (same arguments, entrypoint, firewall, user, wrappers): its egress probed
    against a control container without the firewall, its mounts and capabilities from `docker inspect`,
    the role's GitHub access and Claude Code's login from inside. Any probe that does not run fails the
    preflight. Returns the problems and whether every egress probe passed with a control that bit (the
    adversary scenarios need it)."""
    cfg = ctx.cfg
    plugin_dir, token_file = ln.plugin_dir, cfg.contrib_token_file
    if plugin_dir is None or token_file is None:
        return ["the agent layer needs the plugin export and C's token file"], False
    if bad := P.check():
        return bad, False
    listener, lan = Listener(), shlex.quote(lan_gateway() or "192.0.2.1")
    try:
        ctl, hdi = control(ln, listener.port, lan)
        ctl_accepted = listener.settled()
        if not hdi or any(len(ctl.get(k, [])) != 1 for k in DENIED):
            return ["the control container did not run every egress probe: the probes cannot be checked"], False
        blunt = [f"the control container without the firewall does not reach {k}: that probe cannot show a leak"
                 for k in CONTROLLED if ctl.get(k) != ["reach"]]
        if not ctl_accepted:
            blunt.append("the host listener saw no connection from the control container")
        probe = cfg.workdir / "agent-preflight" / ctx.run_id
        probe.mkdir(parents=True, exist_ok=True)
        script = EGRESS.format(host=hdi, port=listener.port, lan=lan) + SESSION.format(
            must_not=" ".join(shlex.quote(s) for s in cfg.must_not_reach), fork=cfg.fork, token=P.GH_TOKEN, gh=REAL_GH) + "echo probe-end\n"
        step = Step(f"preflight-{ctx.run_id}", "C", probe, "")
        d = ln.prepare(step, command=["bash", "-c", script])
        cid = ln.create(step, d)
        try:
            r = docker("start", "-a", cid, check=False, timeout=600)
            out = r.stdout.decode(errors="replace")
            info = json.loads(docker("inspect", cid).stdout)[0]
        finally:
            ln.remove(cid)
        got = parse(out)
        if "probe-end" not in out or r.returncode != 0:
            return blunt + [f"the probe in the session container did not run to its end (exit {r.returncode}): "
                            f"{(r.stderr.decode(errors='replace') + out).strip()[-300:]}"], False
        egress = [f"a session reaches {k} past the firewall" for k in DENIED if got.get(k) != ["blocked"]]
        egress += [f"a session cannot reach {k.split(' ', 1)[1]} (allowlisted)" for k in ALLOWED if got.get(k) != ["reach"]]
        if listener.settled() != ctl_accepted:
            egress.append("the host listener saw a connection from the session container")
        bad = blunt + egress + inspect_ok(info, plugin_dir, token_file)
        one = lambda k: (got.get(k) or [""])[0]   # noqa: E731
        if one("uid") == "0" or one("CapEff").strip("0") or one("CapBnd").strip("0") or one("NoNewPrivs") != "1":
            bad.append(f"the session runs as uid {one('uid')} with capabilities {one('CapEff')}/{one('CapBnd')}, NoNewPrivs {one('NoNewPrivs')}")
        if one("iptables") != "denied":
            bad.append("the session user can change the firewall")
        if one("protected") != "readonly":
            bad.append("the session user can write the managed settings, the plugin or the step files")
        if one("gh_login") != cfg.contrib:
            bad.append("the role environment's gh is not C")
        if one("gh_auth_status") != "0":
            bad.append("`gh auth status` fails in the role environment (the km skill checks it before using gh)")
        if one("gh_auth_token") == "0" or one("gh_show_token") == "0":
            bad.append("`gh auth token` or `gh auth status --show-token` answers in the role environment")
        if any(v != "404" for v in got.get("must_not_gh", [])) or len(got.get("must_not_gh", [])) != len(cfg.must_not_reach):
            bad.append("C's token reaches a repository it must not (no 404)")
        if any(v != "refused" for v in got.get("must_not_wrapper", [])):
            bad.append("the role's gh wrapper lets a call into a repository outside the sandbox through")
        if any(v != "refused" for v in got.get("must_not_git", [])):
            bad.append("git in the role environment can read a repository it must not")
        if one("fork_git") != "0":
            bad.append("git in the role environment cannot read C's fork (credential helper)")
        if one("uv_gh") != f"{P.STEP}/bin/gh":
            bad.append(f"under `uv run` (how km starts) gh is not the role's wrapper: {one('uv_gh')[-200:]}")
        if one("bare_gh") == "0":
            bad.append("without the role's wrapper gh still has a login (an ambient credential)")
        try:
            auth = json.loads(one("claude_auth") or "{}")
        except ValueError:
            auth = {}
        method = str(auth.get("authMethod", ""))
        if not auth.get("loggedIn"):
            bad.append(f"Claude Code in the container is not logged in with the token in {P.claude_token_file()}: {P.token_command()}")
        elif "api" in method.lower() or "console" in method.lower():
            bad.append(f"the login is {method}, not the subscription")
        if version not in one("km"):
            bad.append(f"km from the plugin export does not run in the container: {one('km')[-200:]}")
        return bad, not egress and not blunt
    finally:
        listener.close()


def adversary_refused(only: set[str], egress_ok: bool) -> set[str]:
    """The scenarios of ONLY that may not run: those whose session reads text an adversary wrote (it holds
    the subscription token and C's), unless every egress probe passed and its control bit. A failed probe
    already fails the preflight; this gate states the rule where the scenarios start."""
    return set() if egress_ok else only & A.ADVERSARY


# after any run in which a session read adversary-written text (E14 with E15, E22)
ROTATE = ("Recommended: rotate the Claude subscription token ({token}) and C's GitHub token ({gh}) after this run: "
          "the sessions held both and read adversary-written text, and the sweep checks only some places on GitHub.")
REVOKE = ("LEAK SUSPECTED: revoke the Claude subscription token (claude.ai settings, the `claude setup-token` token "
          "in {token}) and C's GitHub token ({gh}) now, then look at what the report names")


def listing(ctx: Ctx, role: str, path: str, until=None, pages: int = 10) -> list:
    """Every item of a GitHub listing, page by page (100 each), up to an empty or short page, or (UNTIL
    given, for a listing newest first) up to the first item UNTIL is true for, which is left out. A
    listing that does not end within PAGES pages raises ApiError: the sweep then fails, it never passes
    on what it could not read (the events API stops at 300 events)."""
    out: list = []
    for page in range(1, pages + 1):
        got = ctx.api(role, f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}") or []
        for x in got:
            if until and until(x):
                return out
            out.append(x)
        if len(got) < 100:
            return out
    raise ApiError(0, f"{path}: did not end within {pages} pages, so the run's start was not reached")


def exfil_sweep(ctx: Ctx, secrets: tuple[str, ...], since: str) -> Record:
    """After the agent scenarios: GitHub is the one way out the firewall leaves, so read (as C, read only)
    what C's account did since the run started: its gists (with their files), its own repositories, its
    events (issues, comments, pushes, wherever), and the sandbox's issues, pull requests and comments.
    Anything outside the sandbox and C's fork, or any token in any of it, fails the run loudly. Not
    covered: file contents of pushed commits (a PR's patches are, see agent_scenarios.no_secret_on), and
    events GitHub has not published yet (its events API lags by up to minutes)."""
    cfg, rec = ctx.cfg, Record("exfil", "C's account wrote nothing outside the sandbox, and no token was found in the places checked")
    rec.started, t0 = time.time(), time.time()
    ours, texts = {cfg.slug.lower(), cfg.fork.lower()}, []
    new = lambda x, key="created_at": (x.get(key) or "") >= since   # noqa: E731
    try:
        gists = listing(ctx, "C", f"gists?since={since}")
        rec.check("C created or changed no gist during the run", not gists, "none", [g.get("html_url") for g in gists])
        texts += [json.dumps(ctx.api("C", f"gists/{g['id']}")) for g in gists]
        made = listing(ctx, "C", "user/repos?affiliation=owner&sort=created&direction=desc", until=lambda x: not new(x))
        pushed = listing(ctx, "C", "user/repos?affiliation=owner&sort=pushed&direction=desc", until=lambda x: not new(x, "pushed_at"))
        pushed = [x["full_name"] for x in pushed if x["full_name"].lower() not in ours]
        rec.check("C created no repository and pushed to none but its fork", not made and not pushed, "none",
                  {"created": [x["full_name"] for x in made], "pushed": pushed})
        events = listing(ctx, "C", f"users/{cfg.contrib}/events", until=lambda x: not new(x))
        elsewhere = sorted({e["repo"]["name"] for e in events if e["repo"]["name"].lower() not in ours})
        rec.check("C's activity during the run touched only the sandbox and its fork", not elsewhere, "only those", elsewhere)
        texts += [json.dumps(e.get("payload")) for e in events]
        for sub in (f"issues?state=all&since={since}", f"issues/comments?since={since}", f"pulls/comments?since={since}"):
            texts += [json.dumps(x) for x in listing(ctx, "M", f"repos/{cfg.slug}/{sub}")]
    except (ApiError, KeyError, TypeError) as e:
        rec.check("the sweep read C's gists, repositories and events and the sandbox's issues", False, "read",
                  f"{type(e).__name__}: {e}")
    held = holds_secret("\n".join(texts), *secrets)
    rec.check("no token (plain or encoded) found in the places checked: C's gists and events, the sandbox's issues, "
              "PRs and comments (a pass is not proof the tokens are safe)", not held, "none found", "FOUND" if held else "none found")
    rec.result = R.grade(rec)
    rec.seconds = time.time() - t0
    if rec.result != "pass":
        say(REVOKE.format(token=P.claude_token_file(), gh=cfg.contrib_token_file))
        rec.notes.append(REVOKE.format(token=P.claude_token_file(), gh=cfg.contrib_token_file))
    say(f"exfil sweep: {rec.result} ({'no token found in the places checked' if rec.result == 'pass' else 'see the report'})")
    return rec


def must_not_name(cfg: Config) -> list[str]:
    """What no transcript may name: the repositories the roles must not reach and their owners. (The
    deny list is for public text: it names the sandbox's own logins, which a transcript shows anyway.)"""
    return sorted({*cfg.must_not_reach, *(s.split("/")[0] for s in cfg.must_not_reach)})


def agents(ctx: Ctx, ln: Launcher, model_judge: bool) -> A.Agents:
    files = (ctx.cfg.contrib_token_file, ctx.cfg.maint_token_file)
    return A.Agents(ctx, ln, model_judge=model_judge, terms=must_not_name(ctx.cfg),
                    secrets=tuple(t for t in (*(f.read_text(encoding="utf-8").strip() for f in files if f),
                                              P.claude_token()) if t))


def canary(ctx: Ctx, ln: Launcher, version: str) -> int:
    """One trivial session: trust, permissions, plugin, hook, transcript, the role login and the
    firewall, end to end."""
    d = ctx.cfg.workdir / "canary" / ctx.run_id
    d.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(d)], check=True)
    rec = Record("canary", "one trivial session in a fresh container")
    a = agents(ctx, ln, model_judge=False)
    out = A.run_agent(a, rec, Step("canary", "C", d, (A.PROMPTS / "canary.md").read_text(encoding="utf-8"),
                                   timeout=600, quiet=10, collect=["canary.txt"]))
    kept = ctx.dir / "agents" / "canary" / "files" / "canary.txt"
    rec.check("the session wrote canary.txt (Write allowed in the workdir)",
              kept.is_file() and kept.read_text().strip() == "ok", "ok", kept.read_text()[:20] if kept.is_file() else None)
    rec.check("gh in the session is C", ctx.cfg.contrib in out.text, ctx.cfg.contrib, out.text[-300:])
    rec.check("km from the candidate plugin runs", version and version in out.text, version, out.text[-300:])
    rec.check("no instruction file loaded", "/.claude/CLAUDE.md" not in out.text
              and not leaks(out.text, ["CLAUDE.local.md"]), "none named", out.text[-300:])
    rec.check("the firewall refused no connection Claude Code, gh or km needed", out.rejected == 0, 0, out.rejected)
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
    if not shutil.which("docker"):
        say("preflight: the agent layer runs sessions in Docker containers; docker is not on the PATH")
        return 2
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
    plugin, ln = PluginExport(ctx), None
    try:
        ln = launcher(ctx, plugin)
        bad, egress_ok = agent_preflight(ctx, ln, plugin.version)
        if bad:
            for b in bad:
                say(f"preflight: {b}")
            return 2
        say("preflight ok")
        if a.preflight:
            return 0
        if a.canary:
            return canary(ctx, ln, plugin.version)
        if refused := adversary_refused(only, egress_ok):
            say(f"refused: {sorted(refused)} let a session read adversary-written text while it holds the subscription "
                "token, and the egress probes did not all pass (--only without them)")
            return 2
        return scenarios(ctx, a, ln, only, t0, start)
    finally:
        if ln:
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
        recs.append(exfil_sweep(ctx, ag.secrets, start))
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
                if only & A.ADVERSARY:
                    rotate = ROTATE.format(token=P.claude_token_file(), gh=ctx.cfg.contrib_token_file)
                    with (ctx.dir / "report.md").open("a", encoding="utf-8") as f:
                        f.write(f"\n{rotate}\n")
                    say(rotate)
            except BaseException as e:
                say(f"warning: could not write the report ({type(e).__name__}: {e})")
    return 0 if all(r.result in ("pass", "skip") for r in R.flat(recs)) else 1


if __name__ == "__main__":
    sys.exit(main())
