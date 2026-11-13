# km end-to-end test on a sandbox team brain

The smoke tests in `tests/` run km on local repositories with a stand-in `gh`. What only GitHub can show (the shipped workflows `approve-fork-ci`, `review-request-guide` and `main-guard` running, a fork pull request waiting for approval, who applied `km:ready` on a real timeline, an upgrade running as an Action) is tested here, against a private sandbox team brain, with two real logins: a maintainer `M` and a contributor `C` who works from a fork.

This is phase 1: deterministic scenarios only, driven by the km CLI, `git` and `gh`. No Claude agent plays a role yet.

## Files

| File | What it does |
|---|---|
| `run.py` | The driver: preflight, lock, reset, scenarios, report |
| `scenarios.py` | One function per scenario, with its assertions |
| `lib.py` | Configuration, the roles' GitHub and git access, the write guard, waiting, records |
| `seed.py` | Writes the dummy brain (invented content) with the baseline km; `seed.py pages DIR` writes only the generated files, for review |
| `check_names.py` | Fails when `e2e/` names an organisation, account or repository other than `pasrom/km` (run by `tests/e2e_smoke.sh` in CI) |
| `env.example` | The environment variables, with placeholder values |

## Environment

Everything that names the sandbox comes from the environment; nothing here names it. Keep the values in a file outside any repository and `source` it.

| Variable | Meaning |
|---|---|
| `KM_E2E_ORG` | The sandbox organisation: owner of the sandbox brain. The driver refuses a brain owned by anyone else |
| `KM_E2E_REPO` | The sandbox brain's repository name |
| `KM_E2E_MOUNT_REPO` | Optional: a repository in the same organisation mounted at `mounted/notes`, pinned one commit behind its head. Only read |
| `KM_E2E_MAINT_LOGIN` | `M`'s login; also the login in the brain's `KM_MAINTAINERS` variable |
| `KM_E2E_MAINT_TOKEN_FILE` | A file holding `M`'s fine-grained token. Resource owner: the sandbox organisation only. Repository permissions: administration, actions, contents, issues, pull requests, variables, workflows (read and write), metadata (read) |
| `KM_E2E_CONTRIB_LOGIN` | `C`'s login. `C` has triage on the sandbox brain and a fork of it named like the brain |
| `KM_E2E_CONTRIB_TOKEN_FILE` | A file holding `C`'s token (for example from `gh auth token` under `C`'s gh config, `chmod 600`). Used like `M`'s |
| `KM_E2E_CONTRIB_GH_CONFIG_DIR` | Fallback when there is no token file: a gh config folder holding `C`'s login. Its git credential helper (`gh auth git-credential`) can hand out another stored login, so the preflight warns |
| `KM_E2E_MUST_NOT_REACH` | Comma-separated `owner/repo` slugs both identities must get HTTP 404 on (the real brains). The run stops otherwise |
| `KM_E2E_BASELINE_REF` | The km commit that seeds the brain (the previous release) |
| `KM_E2E_CANDIDATE_REF` | The km commit under test (a release commit, or a candidate pushed to km's repository) |
| `KM_E2E_WORKDIR` | Clones, seed and reports (default `~/.cache/km-e2e`); never inside a repository |
| `KM_E2E_KM_URL` | Where km is fetched from (default km's GitHub repository) |
| `KM_E2E_DENY_FILE` | Optional, for `check_names.py`: a file outside the repository with terms `e2e/` must not contain |

Isolation: each role's API calls run with `GH_TOKEN` read from its token file, and its git pushes with a credential helper that reads the same file, for `https://github.com` only. An empty `GH_CONFIG_DIR` keeps gh from reading a stored login, but gh still prefers `GH_TOKEN`, so the token file is what fixes the identity. The preflight then checks the login each token belongs to. Git runs with `GIT_CONFIG_GLOBAL=/dev/null`, no system config, no SSH and no hooks. Every write goes through one function that refuses any repository but the sandbox brain and `C`'s fork. Tokens are never put in argv or printed. Every gh, git and km call has a time limit.

## Sandbox set-up (once)

Done by hand, checked by the preflight on every run: a free organisation with "members can fork private repositories" on; the private brain with rebase merge only and forking allowed; fork pull request workflows run, with approval required, no write token, no secrets; default workflow permissions write with "Allow GitHub Actions to create and approve pull requests"; the variable `KM_MAINTAINERS`; the variable `KM_E2E_SANDBOX=1`; the labels `km:ready`, `km:needs-human`, `km:blocked`; `C` at triage with its fork. Branch protection is not available on the free plan for a private repository; main-guard is what reports a direct push.

## Run

```sh
source /path/outside/the/repo/km-e2e.env
python3 e2e/run.py --preflight       # identities, 404 on the real repositories, sandbox owner, labels, variable
python3 e2e/run.py                   # reset, all scenarios, report
python3 e2e/run.py --only E05,E06    # a subset (on main as it is after the reset; E01 and E24 only when named)
```

`--skip-reset` runs on the sandbox as it is; `--workers N` sets how many pull request scenarios run at once (default 4); `--steal-lock` takes over a lock a crashed run left (the repository variable `KM_E2E_LOCK`).

A run:

1. Preflight. Before any call: every `KM_E2E_MUST_NOT_REACH` entry is `owner/repo`, and `M`'s token is fine-grained (`github_pat_`). Then: both logins are the configured ones; both get 404 on every `KM_E2E_MUST_NOT_REACH` repository; the brain is owned by `KM_E2E_ORG`, private, `M` is admin, `C`'s fork exists, `C` is at triage, `KM_MAINTAINERS` names `M`, the labels exist, and the brain carries the repository variable `KM_E2E_SANDBOX=1`, which marks it as a repository the run may reset. The Actions usage summary of the organisation is printed when the token can read it, otherwise a warning.
2. Lock (`KM_E2E_LOCK`).
3. Reset R1: Actions off; open pull requests and issues closed; every branch but `main` deleted in the brain and in the fork; a freshly seeded `main` force-pushed to both and tagged `e2e-baseline/<run id>`. With Actions off, these pushes start no workflow.
4. Actions on; E01 (merges to `main`), the fork synced; the pull request scenarios in parallel; E24 last.
5. Wait (bounded) for runs to finish; Actions off; lock released; report. This also runs on Ctrl-C and SIGTERM. A run that does not hold the lock at this point (it never got it, or another run took it over with `--steal-lock`) leaves the sandbox as it is and writes no report. A hard kill (`kill -9`, a crash of the machine) skips it: Actions may then stay on and the lock stay set. Switch Actions off by hand and use `--steal-lock` on the next run.

The report (`report.json`, `report.md`) is written to `$KM_E2E_WORKDIR/runs/<run id>/`, with the Actions minutes the run used (each job rounded up to a minute, as billed). It names the sandbox, so it stays outside the repository. Pull requests and issues of a run stay until the next reset closes them, for inspection.

## Seed

`seed.py build` runs the baseline km: `km init --team`, then 20 invented pages (concept data set: plain served pages, a human-level page, a verbatim block, customer pages, lapsed and old `review_by`, a summary and a spec with source pins, a generated plot with its script and data, a superseded page, a draft, a page without `audience`), then the sign-offs by `km approve` in link order (a served page cannot link to a page still in review), the source pins by `km repin`, and the mount as a gitlink. Commits have fixed identities and dates: the same km, date and mount give the same commit. The result passes `km validate` and `km gen-index --check`.

## Scenarios (phase 1)

| Id | What it asserts |
|---|---|
| E01 | `M` upgrades the baseline to the candidate by PR: every km pin moves to the candidate commit, the shipped main-guard is replaced, `ci` green and running the candidate as an Action; `M`'s own `km:ready` on a change to `.github/` does not count; rebase merge; `ci` on `main` green with the `served-bundle` artifact; main-guard accepts the merge. Observed: a fresh candidate `km init` against the upgraded tree |
| E02 | `C` adds an AI-level page and signs it off as its own commit (the CLI stand-in for `/km pr`), PR body with a table and `Last reviewed`: `ci` green after approve-fork-ci, `C`'s own `km:ready` counts |
| E03 | A customer page in review without an AI review: `ci` red with a `signoff` finding naming it |
| E03b | The same with an AI review recorded: `ci` green, the page waits for a person |
| E04 | On E03's PR, a person's `km approve --by BBB` commit: `ci` green; `C`'s `km:ready` does not count (level human), `M`'s does |
| E05 | Fork PR with a page and an SVG: approve-fork-ci approves the run, `ci` runs as attempt 2 by `github-actions[bot]`, `C`'s own label counts |
| E05-ctl | Fork PR with an AI-level page and a change to `CLAUDE.md`: approve-fork-ci names the control file and approves nothing; `ci` waits; `M` approves the run by API; `ci` green; `C`'s own label does not count |
| E06 | Fork PR with a generator script beside a page: approve-fork-ci approves the run (a script in a doc folder is no control file), `ci` green, `C`'s own label counts |
| E08 | review-request-guide: one comment by `github-actions[bot]` listing the page under both lists, still one after a second request, switched by `km:ready` set and removed |
| E08-draft | The guide is silent on a draft PR (skipped where the plan does not offer draft pull requests) |
| E24 | A direct push and then a force push to `main`: main-guard red, an issue for each |

Later phases add the rest of the concept's catalogue and the agent layer (role agents running the skill, `/km queue`).
