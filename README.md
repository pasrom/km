# km

Knowledge management for markdown knowledge bases ("brains"), as a Claude Code skill plus the
scripts and CI that keep a brain consistent.

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
/km upgrade                                    # refresh the km-owned files in a brain
/km help                                       # all commands
```

**Cross-repo brains:** other knowledge repos are mounted as git submodules under `brains/`. Each
brain keeps its own access permissions, brains update when queried (if older than 15 minutes), and
every answer cites `[brain@commit]`.

## What a brain gets

`/km init` writes `CONVENTIONS.md`, `CLAUDE.md`, `schema.base.yaml` and `schema.local.yaml`, and
copies `scripts/validate.py` (frontmatter and index lint) and `scripts/km_promote.py` (move a note
into the served set). `/km init --team` adds `scripts/gen_index.py`, `demote_stale.py`,
`build_served.py`, two GitHub workflows and domain folders. Files marked km-owned are refreshed by
`/km upgrade`; change them here, not in a brain.

## Layout

```
.claude-plugin/        plugin and marketplace manifests
skills/km/SKILL.md     the skill
skills/km/*.py         validate.py, km_promote.py (copied into every brain)
skills/km/team/        team-brain templates, scripts, workflows and km_team.py (init/upgrade)
skills/km/tests/       smoke tests: bash skills/km/tests/<name>.sh
```

## Development

The smoke tests need Python 3.11+, PyYAML and git: `bash skills/km/tests/gate_smoke.sh`,
`index_smoke.sh`, `team_smoke.sh`. CI runs all three on every pull request.

km started inside [dotclaude](https://github.com/pasrom/dotclaude) and was moved here with its
history.

## License

MIT
