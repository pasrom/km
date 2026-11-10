# km

Knowledge management for markdown knowledge bases ("brains"): a Claude Code skill, and the `km` command and GitHub Action that keep a brain consistent.

- Answer a question from the brain, with sources, also from its open pull requests. GitHub reads use `gh`, or GitHub MCP tools where `gh` is not signed in.
- Save a note, decision or meeting transcript with validated frontmatter, in the right folder.
- Update or supersede a page, lint the brain, mount peer brains as submodules.
- Contribute to a brain you only read, as a pull request.
- Set up a shared **team brain**: one maintainer merges, the team reads the repo, CI validates every PR, keeps each folder's `_index.md` generated and reachable, builds a per-audience bundle for AI tools, and demotes accepted docs whose review date has lapsed.

## Install

As a Claude Code plugin:

```
/plugin marketplace add pasrom/km
/plugin install km@km
```

## Use

```bash
/km init                                       # bootstrap a personal knowledge repo
/km init --team                                # bootstrap a shared team brain
/km What do we know about thermal management?  # search and summarize
/km We decided to use LTC6813                  # save content (auto-detects type)
/km update sensor-fusion: add calibration      # modify a document
/km brain add https://github.com/org/team-brain.git   # mount another brain
/km @all Zephyr RTOS                           # search all mounted brains
/km upgrade                                    # move the brain to the installed km version
/km queue                                      # what waits for review: docs and open PRs
/km check my setup                             # what this computer still needs for the brain (km doctor)
/km sync                                       # bring this copy and a fork up to the upstream brain
/km help                                       # all commands
```

**Cross-repo brains:** other knowledge repos are mounted as git submodules under `brains/`. Each brain keeps its own access permissions, is read at the commit the brain pins (`km sync` keeps the checkout there; a pin moves only through a pull request), and every answer cites `[brain@commit]`.

## The km command

```
km validate [FILE ...]      frontmatter, links, the gate, index completeness
km gen-index [--check]      regenerate every '## Documents' list in _index.md
km demote [--apply]         demote served docs past their review date
km demote DOC...            send accepted docs back to review now, e.g. in the commit that changes them
km serve                    build the per-audience bundle under dist/served/
km promote ...              move a note into the brain as a review doc
km approve DOC... --by WHO  sign review docs off; ai:<model> where CONVENTIONS allow an AI sign-off
km repin DOC...             pin a doc's sources and translates to their current content
km repin --cites DOC... (--file URL=PATH ... | --dir LOCAL=URLPREFIX ...)
                            re-pin the external files a doc cites against local copies
km cite add DOC URL --file COPY [--title T] [--version V]
                            record an external file (SharePoint, OneDrive) by the sha256 of a local copy
km cites check [DOC...] (--file URL=PATH ... | --dir LOCAL=URLPREFIX ...)
                            compare cited files with local copies: current, stale, unchecked
km init DIR [--team ...]    create a brain from the templates
km upgrade                  move a brain's km pins to this version
km doctor [--offline]       check this computer is set up for the brain
km sync [--quiet] [--offline] [--max-age 15m]
                            bring this copy, a fork and the mounted brains up to the upstream brain
km list [PATH...] [filters] docs from their frontmatter: --status, --signoff, --due DATE, --json
```

`km sync` keeps a copy from going stale. Its upstream is the remote named `upstream` where one exists, else the parent of a fork (asked of `gh`), else origin. It fetches, and then only ever fast-forwards: the default branch when it is checked out and the tree has no uncommitted changes; a fork's default branch on the host (`gh repo sync`; a plain push, which git refuses unless it is a fast-forward, only where gh is not installed); the mounted brains, to the commit the brain pins when they are behind it (a pin never moves here, that stays with the host's automation and a reviewed pull request). A work branch, a dirty tree, a branch that diverged or a mount moved past its pin is reported with how far behind it is, never rebased, reset or moved back. `--quiet` prints only what changed or needs attention, `--max-age 15m` makes a repeated run free, and an unreachable remote is a note, not a failure. The plugin runs `km sync --quiet --max-age 15m` when a Claude Code session starts in a brain (`hooks/hooks.json`), so what it reports is in Claude's context from the first prompt; outside a brain, without network or without km the hook is silent.

`km doctor` reads what to expect from the brain alone: its origin and upstream (the same upstream `km sync` follows: on a fork, both the checked-out branch and the fork's default branch on the host must have everything the upstream brain has), the brains it mounts (`.gitmodules`), the km version it pins, and the plugins its `.claude/settings.json` enables (`enabledPlugins`, with the marketplaces in `extraKnownMarketplaces`). A brain lists its plugins there for Claude Code anyway, which offers to add the marketplace when the folder is trusted. It also checks that the pre-commit hook is installed, that text files keep LF line endings, and, for a brain on GitHub, that `gh` is signed in, that git pushes to an https origin with gh's login (`gh auth setup-git`), and whether you push to the brain or through a fork. A brain may mount a repository some of its readers cannot read: a mount this computer leaves out (`git config submodule.<name>.update none`, or set inactive) is then a note, not a failure, and `km sync` does not check it out; one never initialised that cannot be read is a note too, which names that setting (`km sync` would try to check it out). Each check that fails names its fix; it needs no PyYAML, so it also runs on a computer that is half set up.

Every command takes `--root DIR`; the default is the git work tree around the current directory. Install a release by its commit (`git ls-remote https://github.com/pasrom/km refs/tags/v1.11.0` shows it), not by the tag: `pip install git+https://github.com/pasrom/km@<commit>  # v1.11.0`, or run it without installing: `uvx --from git+https://github.com/pasrom/km@<commit> km validate  # v1.11.0`.

## What a brain gets

Brains carry no km code (the one exception, the script of the mounted-pins workflow, is below; the approve-fork-ci workflow is km's shell, kept up to date the same way). `km init` writes `CONVENTIONS.md`, `CLAUDE.md`, `schema.local.yaml`, `inbox/`, a `.gitattributes` that keeps text files LF, and a pre-commit hook pinned to a km version. `km init --team` adds domain folders with generated indexes, a README, and CI that installs km through this repository's GitHub Action:

```yaml
- uses: pasrom/km@<commit> # v1.11.0, installs the km CLI at that commit
- run: km validate
- run: km gen-index --check
```

The team brain's ci workflow also runs on `workflow_dispatch`: a pull request that a workflow opens with `GITHUB_TOKEN` starts no `pull_request` run, so such a workflow (a pin bump, say) dispatches ci on its branch and the pull request gets its check. `km upgrade` adds the trigger to a km ci workflow that lacks it.

A team brain also gets `approve-fork-ci`. A fork pull request from a member with read access waits for "Approve and run" before ci starts; this workflow, on `pull_request_target` and without checking out the fork's code, approves that run when every changed file is data (an allowlist of endings, only Markdown at the top, nothing under `.github/`, no symlink or submodule). Every pull request from the branch must target the default branch and never have changed its base, with exactly one open. It approves only a ci run made for this event, since a fork's run names no pull request and a closed one or an older base could share it. Anything else waits for a person. `km upgrade` adds it only to a team brain whose `ci.yml` is km's as YAML reads it, but for its action pins and branch name (a ci with steps of the brain's own would run fork code unreviewed: it gets a note instead). Like bump-mounted-pins it replaces a copy that is still a version km shipped, so security fixes reach the brain, and leaves one the brain changed with a note; to take km's version, delete the copy and run `km upgrade`. It also notes a copy that sits beside a `ci.yml` that is not km's.

A team brain also gets `bump-mounted-pins`, a workflow that moves the pins of the mounted brains (submodules) by pull request, in place of Dependabot's submodule updates, which need an organisation-wide grant for private submodules and stop every submodule of a group on one refusal. On weekday mornings it walks each mount's tracked branch (its `branch =`, else the repository's default branch) back from the tip to the newest commit whose CI on that branch did not fail (runs of a side branch or a tag do not count; a commit without a run of its own, such as a bot's, inherits the state of the nearest older commit that has runs; a pin never moves backwards), sets the gitlinks without cloning, force-pushes `chore/bump-mounted-pins` with a lease and opens or updates the pull request, which lists short shas only, and dispatches ci on it. A brain without mounts stops after reading `.gitmodules`. It reads the mounts with a GitHub App (Contents and Actions: read) whose secrets `CI_APP_CLIENT_ID` and `CI_APP_PRIVATE_KEY` live in an environment `mounted-pins` restricted to `main`; the workflow's header says how to set it up, and `km doctor` notes a missing or unrestricted environment. Its script, `.github/scripts/bump-mounted-pins.py`, is the one piece of km code a brain carries: the job that holds the app token installs nothing, so it cannot run the km package. `km upgrade` adds both files when missing and replaces a copy that is still a version km shipped, unchanged but for the action pins its Dependabot moves (a pin moved past the template's version is kept), so later fixes reach the brain; a copy the brain edited is its own, left alone with a note.

The pre-commit hook works the same way (`repo: https://github.com/pasrom/km`, `rev: <commit>  # frozen: v1.11.0`, `id: km-validate`); a team brain's km entry also lists `id: km-gen-index`, which rewrites a stale `_index.md` list and so fails the commit (stage the index and commit again) instead of CI's `km gen-index --check` later. `km upgrade` adds it to a team brain once its pin moves to a km that has the hook. Every pin names a release by its commit, so a tag moved later cannot change what a brain runs; the version rides along as a comment, and `km upgrade` checks that the commit is that release's. km's own dependencies are pinned to exact versions. `km init` and `km upgrade` look a release's commit up by its tag once, so a release tag here must never be moved or deleted; a repository ruleset on `v*` makes sure of it. Dependabot and `pre-commit autoupdate --freeze` propose newer versions; `/km upgrade` moves the pins and turns a brain from the copy-in days into one that pins km.

A team brain also keeps direct pushes off `main`, which the host may not enforce for a private repository on a free plan: its pre-commit config adds `no-commit-to-branch` for `main` from `pre-commit/pre-commit-hooks` and a pre-push hook that refuses `git push origin main` (`pre-commit install` installs both, the config names both hook types and needs pre-commit 3.2 or newer; pre-commit checks the first ref of a push only and skips a push whose commits the remote already has on another ref, so a push of several refs at once or a first push of `main` gets past it), and a `main-guard` workflow fails and opens an issue when a commit reaches `main` without a merged pull request. `km upgrade` adds whichever a team brain lacks. The plugin itself refuses the file-edit tools (Edit, Write, MultiEdit, NotebookEdit) inside a mounted brain (a brain checked out as a submodule of a brain, found through git, not by path) and in a mount that is not checked out yet: a correction goes through a pull request against that brain, in a throwaway clone, as the skill describes; a shell edit is not caught.

## Layout

```
.claude-plugin/        plugin and marketplace manifests
hooks/                 the plugin's hooks: km sync when a session starts in a brain, no edit in a mounted brain
action.yml             GitHub Action: installs km at the action's version
.pre-commit-hooks.yaml pre-commit hooks km-validate and km-gen-index
src/km/                the package: cli, validate, gen_index, demote, serve, promote, approve, repin, cite, cites, init, upgrade, doctor, sync, list_docs
src/km/templates/      what `km init` writes
skills/km/SKILL.md     the skill's core: rules, a dispatch table, what every flow shares
skills/km/reference/   the flows the core dispatches to, read on demand; skills/km/bin/km runs the package from the installed plugin
tests/                 smoke tests
evals/                 plugin evals for the skill (evals/README.md)
```

## Development

The smoke tests need Python 3.11+, PyYAML and git: `bash tests/gate_smoke.sh`, `index_smoke.sh`, `team_smoke.sh`, `doctor_smoke.sh`, `sync_smoke.sh`, `list_smoke.sh`, `pins_smoke.sh`, `cites_smoke.sh`, `mounted_pins_smoke.sh` (the mounted-pins workflow and script a team brain gets, against a stand-in GitHub API), `skill_smoke.sh` (the skill's core keeps its size limit, no Markdown line under `skills/` is long enough for the Read tool to cut, its reference paths resolve, every `/km` verb has a dispatch row) and `hook_smoke.sh` (the plugin's edit guard; the pre-push hook too where pre-commit is installed). CI runs them plus the GitHub Action on every pull request, and `encoding_smoke.sh`, `doctor_smoke.sh`, `sync_smoke.sh` and `hook_smoke.sh` on Windows (team_smoke runs the encoding test on macOS under non-UTF-8 locales). A release bumps `__version__` in `src/km/__init__.py`, `version` in `.claude-plugin/plugin.json` and the version in this README together; merging that to main is the release, CI tags `vX.Y.Z` once main is green.

km started inside [dotclaude](https://github.com/pasrom/dotclaude) and was moved here with its history.

## License

MIT
