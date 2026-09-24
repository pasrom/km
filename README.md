# km

Knowledge management for markdown knowledge bases ("brains"): a Claude Code skill, and the `km`
command and GitHub Action that keep a brain consistent.

- Answer a question from the brain, with sources.
- Save a note, decision or meeting transcript with validated frontmatter, in the right folder.
- Update or supersede a page, lint the brain, mount peer brains as submodules.
- Contribute to a brain you only read, as a pull request.
- Set up a shared **team brain**: one maintainer merges, the team reads the repo, CI validates
  every PR, keeps each folder's `_index.md` generated and reachable, builds a per-audience bundle
  for AI tools, and demotes accepted docs whose review date has lapsed.

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
/km help                                       # all commands
```

**Cross-repo brains:** other knowledge repos are mounted as git submodules under `brains/`. Each
brain keeps its own access permissions, brains update when queried (if older than 15 minutes), and
every answer cites `[brain@commit]`.

## The km command

```
km validate [FILE ...]      frontmatter, links, the gate, index completeness
km gen-index [--check]      regenerate every '## Documents' list in _index.md
km demote [--apply]         demote served docs past their review date
km serve                    build the per-audience bundle under dist/served/
km promote ...              move a note into the brain as a review doc
km init DIR [--team ...]    create a brain from the templates
km upgrade                  move a brain's km pins to this version
```

Every command takes `--root DIR`; the default is the git work tree around the current directory.
Install a release by its commit (`git ls-remote https://github.com/pasrom/km refs/tags/v1.0.1` shows
it), not by the tag: `pip install git+https://github.com/pasrom/km@<commit>  # v1.0.1`, or run it
without installing: `uvx --from git+https://github.com/pasrom/km@<commit> km validate  # v1.0.1`.

## What a brain gets

Brains carry no km code. `km init` writes `CONVENTIONS.md`, `CLAUDE.md`, `schema.local.yaml`,
`inbox/` and a pre-commit hook pinned to a km version. `km init --team` adds domain folders with
generated indexes, a README, and CI that installs km through this repository's GitHub Action:

```yaml
- uses: pasrom/km@<commit> # v1.0.1, installs the km CLI at that commit
- run: km validate
- run: km gen-index --check
```

The pre-commit hook works the same way (`repo: https://github.com/pasrom/km`,
`rev: <commit>  # frozen: v1.0.1`, `id: km-validate`). Every pin names a release by its commit, so a
tag moved later cannot change what a brain runs; the version rides along as a comment, and
`km upgrade` checks that the commit is that release's. km's own dependencies are pinned to exact
versions. `km init` and `km upgrade` look a release's commit up by its tag once, so a release tag here
must never be moved or deleted; a repository ruleset on `v*` makes sure of it. Dependabot
and `pre-commit autoupdate --freeze` propose newer versions; `/km upgrade` moves the pins and turns
a brain from the copy-in days into one that pins km.

## Layout

```
.claude-plugin/        plugin and marketplace manifests
action.yml             GitHub Action: installs km at the action's version
.pre-commit-hooks.yaml pre-commit hook km-validate
src/km/                the package: cli, validate, gen_index, demote, serve, promote, init, upgrade
src/km/templates/      what `km init` writes
skills/km/SKILL.md     the skill; skills/km/bin/km runs the package from the installed plugin
tests/                 smoke tests
```

## Development

The smoke tests need Python 3.11+, PyYAML and git: `bash tests/gate_smoke.sh`, `index_smoke.sh`,
`team_smoke.sh`. CI runs all three plus the GitHub Action on every pull request, and
`encoding_smoke.sh` on Windows (team_smoke runs it on macOS under non-UTF-8 locales). A release bumps
`__version__` in `src/km/__init__.py`, `version` in `.claude-plugin/plugin.json` and the version in
this README together; merging that to main is the release, CI tags `vX.Y.Z` once main is green.

km started inside [dotclaude](https://github.com/pasrom/dotclaude) and was moved here with its
history.

## License

MIT
