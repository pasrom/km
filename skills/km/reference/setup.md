# km reference: Setup, init and upgrade

## Contents

- Running km and keeping the copy current
- Setup check (`/km doctor`, "check my setup")
- Init (`/km init`)
- Team brain init (`/km init --team`)
- Upgrade (`/km upgrade`)

## Running km and keeping the copy current

**Running km.** `${CLAUDE_SKILL_DIR}/bin/km` (next to SKILL.md) runs km from this installed plugin, written `km` below; `km --help` lists the commands, and all take `--root DIR`. Brains carry no km code: CI and the pre-commit hook install the km release the brain pins, by its commit (`pasrom/km@<sha> # vX.Y.Z`, so a moved tag cannot change what runs), and so does `km` here: in a brain that pins another version it runs that commit through `uvx`, so results match CI (`KM_LOCAL=1` keeps the plugin's; `init`, `upgrade`, `doctor`, `list` and `sync` always run the plugin's km, so `km upgrade` needs no `KM_LOCAL`). Without uv, offline, for a pin to a movable tag, or when the workflows disagree, it runs the plugin's km and warns; `/km upgrade` the brain then.

**Keeping the copy current.** A copy of the brain goes stale: answers then come from old knowledge and new work starts on an old base. `km sync` fetches the upstream brain (the remote `upstream`, else a fork's parent, else origin) and only ever fast-forwards: the checked-out default branch on a clean tree, a fork's default branch on the host, and the mounted brains to the commit the brain pins (a pin moves only through the host's automation and a reviewed PR). Everything else it only reports, with how far behind. The plugin runs it when a session starts in a brain, and its lines are then in your context. Before answering a question from the brain, run `km sync --quiet --max-age 15m` (nothing happens within 15 minutes of the last run; it prints only what changed or needs attention). Before creating a page or a branch, run `km sync`, so the work starts from the current upstream. When it reports `branch <X> is <N> commits behind upstream
<default>; rebase it when you are ready`, tell the user and offer the rebase; run
`git rebase upstream/<default>` (`origin/<default>` without a fork) only on their OK and on a clean tree (`git status --porcelain --ignore-submodules=all` prints nothing), never a reset or a force. A default branch with commits of its own, a dirty tree, a mount with changes of its own or a diverged fork are the user's call too: pass the note on and do nothing else.

## Setup check (`/km doctor`, "check my setup")

For someone who just set up a computer for the brain, often not a developer. Answer in their language and in plain words, one line per problem, the fix first; no git jargon they did not use.

1. Before km: `git --version`. Without git, nothing else works: say so and stop; the brain's own setup guide (README or CLAUDE.md) says how to install it.
2. `km doctor` in the brain (`--offline` when they say they have no network). Where `km` itself cannot start, its message names uv and the one-line command that installs it (no administrator rights needed): offer to run that command for their system, then run `km doctor` again. km finds uv where the installer puts it, so the app need not be restarted first.
3. Each `FAIL` comes with a fix. Offer to run the ones that change only this computer and are safe (`git submodule update --init`, the `km sync` or `git pull --rebase` it names on a clean tree, `git config --global user.name` after asking for the value, `pre-commit install`); hand over the ones they must do themselves (signing in, `gh auth login`, installing a plugin or adding a marketplace with `/plugin`, asking for access). The re-checkout that fixes CRLF files discards uncommitted changes: run it only on a clean tree and after they agree. A `note` needs nothing; mention it only if it explains something they asked about.
4. Run `km doctor` again after fixes and end with what still fails, or that the setup is complete.

## Init (`/km init`)

When the user runs `/km init` (or confirms after "CONVENTIONS.md missing" prompt):

1. Ask for the user's author initials (e.g. `ABC`) and, optionally, domain folders with a one-line purpose each (without any, `inbox/` alone).
2. `km init . --initials <XX> [--folder <dir>="<purpose>" ...]`: writes `CONVENTIONS.md`, `CLAUDE.md` (kept if one exists), `inbox/_index.md`, a minimal `schema.local.yaml`, a `.gitattributes` that keeps text files LF (kept if one exists) and the pre-commit hook pinned to this km's release commit (`--pin <version>` for another release; a km that is not released yet cannot be pinned). It refuses a repo that already has a `CONVENTIONS.md`.
3. Commit: `chore: initialize knowledge base conventions`

## Team brain init (`/km init --team`)

A **team brain** is a shared, served knowledge base: one maintainer merges, the team reads the repo, everyone else contributes by pull request or promotes from a personal brain. On top of a personal brain it adds CI (validation, a generated `_index.md` Documents list, a served bundle, weekly staleness demotion), domain folders instead of `inbox/`, and the one-merger rules.

1. Ask for: the brain's name (e.g. `QA-Brain`), a one-line description of the team (e.g. `the QA team`), the maintainer's initials, and the top-level folders with a one-line purpose each (suggest `process/`, `projects/`, `reference/` plus the team's own domains). Optionally one or two placement rules that decide which folder a doc goes to; without them each folder's purpose becomes its rule.
2. In the empty repo (or an empty clone of a fresh remote): `km init . --team --name <name> --desc "<desc>" --initials <XX> --folder process="<purpose>" --folder ... [--rule "<rule>" ...]`. It writes the docs, indexes, `schema.local.yaml`, the ci and staleness workflows, the pre-commit hook, a Dependabot config and a `.gitattributes` for LF, all pinned by commit to this km's release (or `--pin <version>`), and refuses to run if any file it would write already exists, such as a README the host created with the repo: delete that first.
3. `git add -A`, then `km gen-index` (it reads tracked files only, so add first; it fills the root and folder lists), `git add -A` and `km validate`: expect **0 errors / 0 warnings**.
4. Commit: `chore: initialize <name> (team served knowledge base)`.
5. Tell the user what km does not do: create the repo (private), push `main` (after `pre-commit install` the pre-push hook refuses a push to `main`: the first push of the fresh brain takes `--no-verify`, once), give the team **read** access and the maintainer write, and ask members to add the brain to their personal brain with `/km brain add <url>`. Branch protection on a private repo needs a paid GitHub plan; without it the one-merger rule is held by the permission model alone. Members with read access contribute by fork PR, and GitHub does not run Actions on fork PRs of a private repo until "Run workflows from fork pull requests" is enabled (repository or organization settings, Actions): without it those PRs get no CI. Dependabot then proposes a PR whenever a newer km is released.

## Upgrade (`/km upgrade`)

Move a brain to the km you run, without touching repo-specific files:

1. `km upgrade` moves the brain's km pins to this km's release commit (`--pin <version>` for another), turns a pin to a movable tag into a commit pin, and on a brain from the copy-in days drops the copied `scripts/*.py` and `schema.base.yaml` and rewrites its hook and km workflows. It refuses to move a pin to a newer km back (`--force` overrides).
2. Show `git diff`. `CONVENTIONS.md`, `CLAUDE.md`, `README.md` and every `_index.md` are repo-owned and stay (in `schema.local.yaml` only an obsolete `team_brain:` line goes); point out prose that still mentions `scripts/`.
3. Run `km validate` (expect **0 errors**); on a team brain also `km gen-index` (a newer km may list more, e.g. subfolder indexes) and stage what it changed.
4. Commit: `chore(km): upgrade to km <version>`
