# km end-to-end test on a sandbox team brain

The smoke tests in `tests/` run km on local repositories with a stand-in `gh`. What only GitHub can show (the shipped workflows `approve-fork-ci`, `review-request-guide` and `main-guard` running, a fork pull request waiting for approval, who applied `km:ready` on a real timeline, an upgrade running as an Action) is tested here, against a private sandbox team brain, with two real logins: a maintainer `M` and a contributor `C` who works from a fork.

Phases 1 and 2: the deterministic scenarios, driven by the km CLI, `git` and `gh`. No Claude agent plays a role yet.

## Files

| File | What it does |
|---|---|
| `run.py` | The driver: preflight, lock, reset, scenarios, report |
| `scenarios.py` | One function per scenario of phase 1, with its assertions |
| `catalogue.py` | The scenarios of phase 2, the rest of the deterministic catalogue |
| `oracle.py` | The queue oracle: what `/km queue` must list, computed from GitHub state, `km ready`, `gh pr checks` and `km list` |
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
| `KM_E2E_CANDIDATE_REF` | The km commit under test (a release commit, or a candidate pushed to km's repository; E01 pins it by `--pin <commit>`) |
| `KM_E2E_WORKDIR` | Clones, seed and reports (default `~/.cache/km-e2e`); never inside a repository |
| `KM_E2E_KM_URL` | Where km is fetched from (default km's GitHub repository) |
| `KM_E2E_DENY_FILE` | Optional, for `check_names.py`: a file outside the repository with terms `e2e/` must not contain |

Isolation: each role's API calls run with `GH_TOKEN` read from its token file, and its git pushes with a credential helper that reads the same file, for `https://github.com` only. An empty `GH_CONFIG_DIR` keeps gh from reading a stored login, but gh still prefers `GH_TOKEN`, so the token file is what fixes the identity. The preflight then checks the login each token belongs to. Git runs with `GIT_CONFIG_GLOBAL=/dev/null`, no system config, no SSH and no hooks. Every write the driver makes goes through one function that refuses any repository but the sandbox brain and `C`'s fork; the one write km makes itself, `gh repo sync` in E27's `km sync`, runs only in a clone whose `origin` is `C`'s fork. Tokens are never put in argv or printed. Every gh, git and km call has a time limit.

## Sandbox set-up (once)

Done by hand, checked by the preflight on every run: a free organisation with "members can fork private repositories" on; the private brain with rebase merge only and forking allowed; fork pull request workflows run, with approval required, no write token, no secrets; default workflow permissions write with "Allow GitHub Actions to create and approve pull requests"; the variable `KM_MAINTAINERS`; the variable `KM_E2E_SANDBOX=1`; the labels `km:ready`, `km:needs-human`, `km:blocked`; `C` at triage with its fork. Branch protection is not available on the free plan for a private repository; main-guard is what reports a direct push.

## Run

```sh
source /path/outside/the/repo/km-e2e.env
python3 e2e/run.py --preflight       # identities, 404 on the real repositories, sandbox owner, labels, variable
python3 e2e/run.py                   # reset, all scenarios, report
python3 e2e/run.py --only E05,E06    # a subset (only the named scenarios run, on main as it is after the reset)
```

`--skip-reset` runs on the sandbox as it is; `--workers N` sets how many pull request scenarios run at once (default 4); `--steal-lock` takes over a lock a crashed run left (the repository variable `KM_E2E_LOCK`).

A run:

1. Preflight. Before any call: every `KM_E2E_MUST_NOT_REACH` entry is `owner/repo`, and `M`'s token is fine-grained (`github_pat_`). Then: both logins are the configured ones; both get 404 on every `KM_E2E_MUST_NOT_REACH` repository; the brain is owned by `KM_E2E_ORG`, private, `M` is admin, `C`'s fork exists, `C` is at triage, `KM_MAINTAINERS` names `M`, the labels exist, and the brain carries the repository variable `KM_E2E_SANDBOX=1`, which marks it as a repository the run may reset. The Actions usage summary of the organisation is printed when the token can read it, otherwise a warning.
2. Lock (`KM_E2E_LOCK`).
3. Reset R1: Actions off; open pull requests and issues closed; every branch but `main` deleted in the brain and in the fork; a freshly seeded `main` force-pushed to both and tagged `e2e-baseline/<run id>`. With Actions off, these pushes start no workflow.
4. Actions on; E01 (merges to `main`); E27 (`km doctor` and `km sync` bring the fork up to it), the fork synced if it is still behind; the pull request scenarios in parallel; E17 (staleness pushes to `main`); E24 last. E17 leaves an accepted page linking to a demoted one, so a `--skip-reset` run after it has every pull request's ci red.
5. Wait (bounded) for runs to finish; Actions off; lock released; report. This also runs on Ctrl-C and SIGTERM. A run that does not hold the lock at this point (it never got it, or another run took it over with `--steal-lock`) leaves the sandbox as it is and writes no report. A hard kill (`kill -9`, a crash of the machine) skips it: Actions may then stay on and the lock stay set. Switch Actions off by hand and use `--steal-lock` on the next run.

The report (`report.json`, `report.md`) is written to `$KM_E2E_WORKDIR/runs/<run id>/`, with the Actions minutes the run used (each job rounded up to a minute, as billed). It names the sandbox, so it stays outside the repository. Pull requests and issues of a run stay until the next reset closes them, for inspection.

## Seed

`seed.py build` runs the baseline km: `km init --team`, then 20 invented pages (concept data set: plain served pages, a human-level page, a verbatim block, customer pages, lapsed and old `review_by`, a summary and a spec with source pins, a generated plot with its script and data, a superseded page, a draft, a page without `audience`), then the sign-offs by `km approve` in link order (a served page cannot link to a page still in review), the source pins by `km repin`, and the mount as a gitlink. Commits have fixed identities and dates: the same km, date and mount give the same commit. The result passes `km validate` and `km gen-index --check`.

## Scenarios

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
| E07-github, E07-schema, E07-symlink, E07-scripts | Fork PRs with a file under `.github/`, a change to `schema.local.yaml`, a symlink named `*.md`, a script under `scripts/`: approve-fork-ci approves none, each with its notice (control files, or symlinks) and the file JSON-quoted; ci waits |
| E07-base | Two PRs from one fork branch, the first against another base: approve-fork-ci approves neither ("not exactly one open pull request ...") |
| E09 | A comment by `C` that starts with the guide's marker: the bot posts its own and leaves `C`'s alone; a file name with Markdown and a mention appears JSON-quoted in a code block |
| E10 | Removing `approval: human` from a person-approved page: red (level lowered), still red after `km demote` and an AI sign-off, green after `km demote` and a person's |
| E11 | The same for a customer page made internal (also `approval-stale`: `audience` is a digest field) |
| E12 | A copy of a person-approved page lowered to level ai: red ("copied with the doc?"). Observed: a verbatim copy of a customer page at level human |
| E13 | A fork PR whose `skip_prefixes` hides a doc it changes and that drops a status rule: not auto-approved; after `M` approves the run, red with both `signoff` findings |
| E16 | An edited accepted page: `km validate <file>` (what the pre-commit hook runs; the driver's git runs no hooks) refuses it, ci red with `approval-stale`, green after `km demote` and `km approve` as commits of their own |
| E19, E19-roster | A page owned by `ZZZ`: red with `owner-roster`. `M` drops `DDD` from the roster: red, naming the page `DDD` owns |
| E21 | A signed-off page left out of `_index.md`: red in the step "_index Documents list up to date", green after `km gen-index` |
| E23 | Four PRs against the queue oracle: a merge candidate (positive control), a `km:ready` claimed only in the body (no label group), a `Last reviewed` that is not the head, a ci that waits for approval (a change to `CLAUDE.md`, labelled by `M` so the label counts); each negative case fails exactly one merge-candidate condition. The docs groups are checked against the seed |
| E25 | A verbatim block: `km approve --by ai:...` refuses it; a hand-typed approval without digest is red |
| E28 | A fork branch cut from the main commit before E01's upgrade, changing only a page: the ci run downloads the km that main's `ci.yml` pins, so a fork's `pull_request` run uses the merge commit's workflow, not the fork head's |
| E27 | Right after E01, in a clone of `C`'s fork: `km doctor` reports the fork behind, `km sync` fast-forwards the fork on GitHub and the clone, `km doctor` then finds it current |
| E17 | `staleness` dispatched: one commit by `brain-ci` demoting exactly the two lapsed pages, no `ci` or `main-guard` run for that push, the served bundle without them, and the run red only in "validate after demotion" with the accepted page that now links to a demoted one |

The agent layer (role agents running the skill, `/km queue` itself compared with the oracle) is a later phase.
