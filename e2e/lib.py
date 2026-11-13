"""Shared parts of the e2e driver: configuration, the two roles' GitHub and git access, the write
guard, waiting, and the per-scenario record. Standard library only; GitHub through the `gh` CLI.

Roles: M, the maintainer, and C, the contributor, each use a token read from a file (never from argv,
never printed) with an empty gh config, so no stored login on the machine stands in; C may instead
fall back to its own gh config folder. Every write goes through `Ctx.api` or `Ctx.push`, which refuse
any repository but the sandbox brain and C's fork of it (the mount is only read).
"""
from __future__ import annotations

import datetime
import email.utils
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

KM_URL = "https://github.com/pasrom/km"
TIMEOUT = {"api": 60, "gh": 120, "git": 300, "km": 600}   # seconds per subprocess (km: uvx may fetch km first)


class Fail(Exception):
    """A scenario cannot go on (an assertion it depends on failed, or a wait ran out)."""


class ApiError(Exception):
    def __init__(self, status: int, body: str):
        super().__init__(f"HTTP {status}: {body[:300]}")
        self.status, self.body = status, body


def need(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        raise SystemExit(f"e2e: set {name} (see e2e/README.md)")
    return v


def optional_path(name: str) -> Path | None:
    v = os.environ.get(name, "").strip()
    return Path(v).expanduser() if v else None


@dataclass
class Config:
    org: str
    repo: str
    mount: str
    maint: str
    maint_token_file: Path
    contrib: str
    contrib_token_file: Path | None
    contrib_gh_dir: Path | None
    must_not_reach: list[str]
    workdir: Path
    baseline: str
    candidate: str
    km_url: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            org=need("KM_E2E_ORG"), repo=need("KM_E2E_REPO"), mount=os.environ.get("KM_E2E_MOUNT_REPO", ""),
            maint=need("KM_E2E_MAINT_LOGIN"), maint_token_file=Path(need("KM_E2E_MAINT_TOKEN_FILE")).expanduser(),
            contrib=need("KM_E2E_CONTRIB_LOGIN"), contrib_token_file=optional_path("KM_E2E_CONTRIB_TOKEN_FILE"),
            contrib_gh_dir=optional_path("KM_E2E_CONTRIB_GH_CONFIG_DIR"),
            must_not_reach=[s.strip() for s in need("KM_E2E_MUST_NOT_REACH").split(",") if s.strip()],
            workdir=Path(os.environ.get("KM_E2E_WORKDIR", "~/.cache/km-e2e")).expanduser(),
            baseline=need("KM_E2E_BASELINE_REF"), candidate=need("KM_E2E_CANDIDATE_REF"),
            km_url=os.environ.get("KM_E2E_KM_URL", KM_URL))

    @property
    def slug(self) -> str:
        return f"{self.org}/{self.repo}"

    @property
    def fork(self) -> str:
        return f"{self.contrib}/{self.repo}"

    def writable(self) -> set[str]:
        return {self.slug, self.fork}     # the mount is only read

    def token_file(self, role: str) -> Path | None:
        return self.maint_token_file if role == "M" else self.contrib_token_file


@dataclass
class Check:
    what: str
    ok: bool
    expected: str
    observed: str


@dataclass
class Record:
    """One scenario's result: its assertions, the objects it made, its timing."""
    id: str
    title: str
    result: str = "pending"          # pass, fail, error, skip
    checks: list[Check] = field(default_factory=list)
    links: dict[str, str] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)
    children: list["Record"] = field(default_factory=list)   # a scenario that continues on this one's PR
    started: float = 0.0
    seconds: float = 0.0

    def check(self, what: str, ok: object, expected: object, observed: object) -> bool:
        self.checks.append(Check(what, bool(ok), str(expected), str(observed)[:500]))
        return bool(ok)

    def must(self, what: str, ok: object, expected: object, observed: object) -> None:
        if not self.check(what, ok, expected, observed):
            raise Fail(what)


def clean_env() -> dict[str, str]:
    """os.environ without any GitHub login or credential prompt of the machine's user."""
    drop = {"GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GH_CONFIG_DIR", "GH_HOST", "GIT_ASKPASS", "SSH_ASKPASS"}
    return {k: v for k, v in os.environ.items() if k not in drop}


SKEW = [0.0]                     # GitHub's clock minus ours, set from the first response's Date header


def now() -> str:
    """The current time on GitHub's clock: compared with created_at of runs and issues."""
    t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=SKEW[0])
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


class Ctx:
    """One run: configuration, run id, role environments, and the guard on every write."""

    def __init__(self, cfg: Config, run_id: str):
        self.cfg, self.run_id = cfg, run_id
        self.dir = cfg.workdir / "runs" / run_id
        self.dir.mkdir(parents=True, exist_ok=True)
        self._empty_gh = Path(tempfile.mkdtemp(prefix="km-e2e-gh-"))   # M's gh sees no stored login
        self.idents: dict[str, tuple[str, str]] = {}
        self._envs: dict[str, dict[str, str]] = {}
        self.lock = threading.Lock()          # guards the shared run list below (scenarios run in threads)
        self._runs: tuple[float, list[dict]] = (0.0, [])

    def close(self) -> None:
        shutil.rmtree(self._empty_gh, ignore_errors=True)

    # --- process environments -------------------------------------------------------------------
    def env(self, role: str) -> dict[str, str]:
        """ROLE's process environment (built once; a copy each call)."""
        if role not in self._envs:
            self._envs[role] = self._env(role)
        return dict(self._envs[role])

    def _env(self, role: str) -> dict[str, str]:
        """A role with a token file: GH_TOKEN from it and an empty gh config, so no stored login can stand
        in. C without one (KM_E2E_CONTRIB_GH_CONFIG_DIR, a fallback): its own gh config folder."""
        if role not in ("M", "C"):
            raise ValueError(role)
        base = clean_env()
        base |= {"GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1", "GIT_TERMINAL_PROMPT": "0",
                 "GIT_SSH_COMMAND": "false", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        if tf := self.cfg.token_file(role):
            base |= {"GH_TOKEN": tf.read_text().strip(), "GH_CONFIG_DIR": str(self._empty_gh), "KM_E2E_TOKEN_FILE": str(tf)}
        else:
            base |= {"GH_CONFIG_DIR": str(self.cfg.contrib_gh_dir)}
        return base

    def login(self, role: str) -> str:
        return self.cfg.maint if role == "M" else self.cfg.contrib

    # --- GitHub API ----------------------------------------------------------------------------
    def api(self, role: str, path: str, method: str = "GET", data: dict | None = None) -> Any:
        """One REST call as ROLE. A write to any repository but the sandbox's is refused here."""
        path = path.lstrip("/")
        if method != "GET":
            m = re.match(r"repos/([^/]+/[^/?]+)", path)
            if not m or m.group(1) not in self.cfg.writable():
                raise SystemExit(f"e2e guard: refused {method} {path}: not a sandbox repository")
        cmd = ["gh", "api", "--include", "-X", method, path]
        if data is not None:
            cmd += ["--input", "-"]
        try:
            r = subprocess.run(cmd, input=json.dumps(data) if data is not None else "", env=self.env(role),
                               capture_output=True, text=True, timeout=TIMEOUT["api"])
        except subprocess.TimeoutExpired:
            raise ApiError(0, f"gh api {method} {path}: no answer in {TIMEOUT['api']} s") from None
        head, _, body = r.stdout.replace("\r\n", "\n").partition("\n\n")
        while head.startswith("HTTP/") and body.startswith("HTTP/"):   # a redirect: the last response counts
            head, _, body = body.partition("\n\n")
        if not SKEW[0] and (dm := re.search(r"(?im)^date: (.+)$", head)):
            SKEW[0] = email.utils.parsedate_to_datetime(dm.group(1).strip()).timestamp() - time.time() or 1e-9
        m = re.match(r"HTTP/\S+ (\d+)", head)
        status = int(m.group(1)) if m else 0
        if r.returncode != 0 or not 200 <= status < 300:
            raise ApiError(status, body or r.stderr)
        return json.loads(body) if body.strip() else None

    def status(self, role: str, path: str) -> int:
        try:
            self.api(role, path)
            return 200
        except ApiError as e:
            return e.status

    def repo_api(self, role: str, sub: str, **kw):
        return self.api(role, f"repos/{self.cfg.slug}/{sub}", **kw)

    def gh(self, role: str, *args: str) -> subprocess.CompletedProcess:
        """A gh subcommand as ROLE, read-only uses only (run view, ...)."""
        try:
            return subprocess.run(["gh", *args], env=self.env(role), capture_output=True, text=True,
                                  stdin=subprocess.DEVNULL, timeout=TIMEOUT["gh"])
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(["gh", *args], 124, "", "timed out")

    def ident(self, role: str) -> tuple[str, str]:
        if role not in self.idents:
            u = self.api(role, "user")
            self.idents[role] = (u["login"], f"{u['id']}+{u['login']}@users.noreply.github.com")
        return self.idents[role]

    # --- git ----------------------------------------------------------------------------------
    # the role's token from its file (KM_E2E_TOKEN_FILE in the role's environment), for github.com only
    FILE_HELPER = ('!f(){ test "$1" = get || exit 0; echo username=x-access-token; '
                   'printf "password=%s\\n" "$(cat "$KM_E2E_TOKEN_FILE")"; }; f')
    GH_HELPER = "!gh auth git-credential"   # C's fallback: GH_CONFIG_DIR in its environment names the login

    def helper(self, role: str) -> str:
        return self.FILE_HELPER if self.cfg.token_file(role) else self.GH_HELPER

    def git(self, role: str, cwd: Path | None, *args: str, check: bool = True, date: str | None = None) -> str:
        name, email = self.ident(role)
        env = self.env(role) | {"GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
                                "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email}
        if date:
            env |= {"GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date}
        cmd = ["git", "-c", "credential.helper=", "-c", f"credential.https://github.com.helper={self.helper(role)}",
               "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args]
        try:
            r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                               timeout=TIMEOUT["git"])
        except subprocess.TimeoutExpired:
            raise Fail(f"git {' '.join(args[:3])}: no answer in {TIMEOUT['git']} s") from None
        if check and r.returncode != 0:
            raise Fail(f"git {' '.join(args[:3])} failed: {r.stderr.strip()[-400:]}")
        return r.stdout

    def url(self, slug: str) -> str:
        return f"https://github.com/{slug}.git"

    def push(self, role: str, cwd: Path, remote_slug: str, *refspecs: str, force: bool = False) -> None:
        if remote_slug not in self.cfg.writable():
            raise SystemExit(f"e2e guard: refused a push to {remote_slug}: not a sandbox repository")
        self.git(role, cwd, "push", "-q", *(["--force"] if force else []), self.url(remote_slug), *refspecs)

    def clone(self, role: str, slug: str, dest: Path, branch: str = "main") -> Path:
        if dest.exists():
            raise Fail(f"{dest} exists")
        self.git(role, None, "clone", "-q", "--branch", branch, self.url(slug), str(dest))
        return dest

    # --- km ------------------------------------------------------------------------------------
    def km_cmd(self, ref: str) -> list[str]:
        return ["uvx", "--quiet", "--no-config", "--from", f"git+{self.cfg.km_url}@{ref}", "km"]

    def km(self, cwd: Path, *args: str, ref: str | None = None, role: str = "M") -> subprocess.CompletedProcess:
        """The candidate km (or REF) in CWD, as itself (KM_LOCAL), with ROLE's GitHub access (km ready)."""
        env = self.env(role) | {"KM_LOCAL": "1", "KM_REPO_URL": self.cfg.km_url}   # --pin reads the candidate there
        cmd = [*self.km_cmd(ref or self.cfg.candidate), *args]
        try:
            return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                                  timeout=TIMEOUT["km"])
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(cmd, 124, "", f"no answer in {TIMEOUT['km']} s")

    # --- waiting -------------------------------------------------------------------------------
    def poll(self, what: str, fn, timeout: float = 300, every: float = 10):
        """Call fn until it returns something truthy; Fail after TIMEOUT seconds."""
        end = time.time() + timeout
        while True:
            v = fn()
            if v:
                return v
            if time.time() > end:
                raise Fail(f"timed out after {timeout:.0f} s waiting for {what}")
            time.sleep(every)

    def runs(self, sha: str, workflow: str | None = None, event: str | None = None) -> list[dict]:
        """The runs for SHA. The API's head_sha and event filters leave out a fork's run that waits for
        approval (observed for minutes), so the newest runs are also read unfiltered."""
        with self.lock:                   # one read of the newest runs serves every waiting thread for 8 s
            if time.time() - self._runs[0] > 8:
                self._runs = (time.time(), self.repo_api("M", "actions/runs?per_page=100&exclude_pull_requests=true")["workflow_runs"])
            newest = self._runs[1]
        found = {r["id"]: r for r in newest if r["head_sha"] == sha}
        if not found:                     # older than the newest 100
            found = {r["id"]: r for r in self.repo_api("M", f"actions/runs?head_sha={sha}&per_page=100")["workflow_runs"]}
        return [r for r in found.values() if (workflow is None or r["name"] == workflow) and (event is None or r["event"] == event)]

    def wait_run(self, sha: str, workflow: str, event: str | None = None, *, settled: bool = True,
                 timeout: float = 420, after: str | None = None) -> dict:
        """The newest run of WORKFLOW for SHA (created at or after AFTER), once it exists and, with
        SETTLED, once it completed or waits for approval."""
        def look():
            rs = [r for r in self.runs(sha, workflow, event) if not after or r["created_at"] >= after]
            if not rs:
                return None
            r = max(rs, key=lambda r: r["id"])
            return r if not settled or r["status"] in ("completed", "action_required") else None
        return self.poll(f"{workflow} on {sha[:7]}", look, timeout)

    def run_log(self, run_id: int) -> str:
        args = ["run", "view", str(run_id), "-R", self.cfg.slug, "--log"]
        for _ in range(6):            # the log can lag the run's completion
            r = self.gh("M", *args)
            if r.returncode == 0 and r.stdout.strip():
                # without the step scripts the log echoes (colour 36;1): their text names every message
                return "\n".join(ln for ln in r.stdout.splitlines() if "[36;1m" not in ln)
            time.sleep(10)
        return ""

    # --- pull requests -------------------------------------------------------------------------
    def branch(self, scenario: str) -> str:
        return f"e2e/{self.run_id}/{scenario}"

    def open_pr(self, role: str, head: str, title: str, body: str, draft: bool = False) -> dict:
        owner = self.cfg.contrib if role == "C" else self.cfg.org
        return self.repo_api(role, "pulls", method="POST", data={
            "title": f"[e2e {self.run_id}] {title}", "head": f"{owner}:{head}", "base": "main", "body": body,
            "draft": draft})

    def label(self, role: str, n: int, add: bool = True, name: str = "km:ready") -> None:
        if add:
            self.repo_api(role, f"issues/{n}/labels", method="POST", data={"labels": [name]})
        else:
            self.repo_api(role, f"issues/{n}/labels/{name}", method="DELETE")

    def head(self, role: str, d: Path) -> str:
        return self.git(role, d, "rev-parse", "HEAD").strip()

    def last_label_actor(self, n: int) -> str | None:
        evs = self.repo_api("M", f"issues/{n}/events?per_page=100")
        ev = [e for e in evs if e["event"] in ("labeled", "unlabeled") and e.get("label", {}).get("name") == "km:ready"]
        return ev[-1]["actor"]["login"] if ev and ev[-1]["event"] == "labeled" else None

    def km_ready(self, n: int, head: str, cwd: Path) -> tuple[int, str]:
        r = self.km(cwd, "ready", self.cfg.slug, str(n), "--head", head)
        return r.returncode, (r.stdout + r.stderr).strip()

    # --- cost ----------------------------------------------------------------------------------
    def billed_minutes(self, since: str) -> tuple[int, int, int]:
        """(runs, jobs, minutes) of the sandbox brain's runs created since SINCE: each job that ran is
        rounded up to a whole minute, as GitHub bills it."""
        runs, page = [], 1
        while True:
            got = self.repo_api("M", f"actions/runs?created=%3E%3D{since}&per_page=100&page={page}")["workflow_runs"]
            runs += got
            if len(got) < 100:
                break
            page += 1
        jobs = minutes = 0
        for r in runs:
            for j in self.repo_api("M", f"actions/runs/{r['id']}/jobs?filter=all&per_page=100")["jobs"]:
                if j.get("started_at") and j.get("completed_at") and j.get("conclusion") != "skipped":
                    t0, t1 = (datetime.datetime.fromisoformat(j[k].replace("Z", "+00:00")) for k in ("started_at", "completed_at"))
                    jobs += 1
                    minutes += max(1, math.ceil((t1 - t0).total_seconds() / 60))
        return len(runs), jobs, minutes

