# km reference: Setup, init and upgrade

## Contents

- Setup check (`/km doctor`, "check my setup")
- Init (`/km init`)
- Team brain init (`/km init --team`)
- Upgrade (`/km upgrade`)

## Setup check (`/km doctor`, "check my setup")

For someone who just set up a computer for the brain, often not a developer. Answer in their
language and in plain words, one line per problem, the fix first; no git jargon they did not use.

1. Before km: `git --version`. Without git, nothing else works: say so and stop; the brain's own
   setup guide (README or CLAUDE.md) says how to install it.
2. `km doctor` in the brain (`--offline` when they say they have no network). Where `km` itself
   cannot start, its message names uv and the one-line command that installs it (no administrator
   rights needed): offer to run that command for their system, then run `km doctor` again. km finds
   uv where the installer puts it, so the app need not be restarted first.
3. Each `FAIL` comes with a fix. Offer to run the ones that change only this computer and are safe
   (`git submodule update --init`, the `km sync` or `git pull --rebase` it names on a clean tree,
   `git config --global user.name` after asking for the value, `pre-commit install`); hand over the
   ones they must do themselves (signing in, `gh auth login`, installing a plugin or adding a
   marketplace with `/plugin`, asking for access). The re-checkout that fixes CRLF files discards
   uncommitted changes: run it only on a clean tree and after they agree. A `note` needs nothing; mention it only if it
   explains something they asked about.
4. Run `km doctor` again after fixes and end with what still fails, or that the setup is complete.

## Init (`/km init`)

When the user runs `/km init` (or confirms after "CONVENTIONS.md missing" prompt):

1. Ask for the user's author initials (e.g. `ABC`) and, optionally, domain folders with a one-line
   purpose each (without any, `inbox/` alone).
2. `km init . --initials <XX> [--folder <dir>="<purpose>" ...]`: writes `CONVENTIONS.md`,
   `CLAUDE.md` (kept if one exists), `inbox/_index.md`, a minimal `schema.local.yaml`, a
   `.gitattributes` that keeps text files LF (kept if one exists) and the pre-commit hook pinned to this km's release commit (`--pin <version>` for another release; a km that
   is not released yet cannot be pinned). It refuses a repo that already has a `CONVENTIONS.md`.
3. Commit: `chore: initialize knowledge base conventions`

## Team brain init (`/km init --team`)

A **team brain** is a shared, served knowledge base: one maintainer merges, the team reads the repo,
everyone else contributes by pull request or promotes from a personal brain. On top of a personal brain
it adds CI (validation, a generated `_index.md` Documents list, a served bundle, weekly staleness
demotion), domain folders instead of `inbox/`, and the one-merger rules.

1. Ask for: the brain's name (e.g. `QA-Brain`), a one-line description of the team (e.g. `the QA
   team`), the maintainer's initials, and the top-level folders with a one-line purpose each
   (suggest `process/`, `projects/`, `reference/` plus the team's own domains). Optionally one or
   two placement rules that decide which folder a doc goes to; without them each folder's purpose
   becomes its rule.
2. In the empty repo (or an empty clone of a fresh remote):
   `km init . --team --name <name> --desc "<desc>" --initials <XX> --folder process="<purpose>"
   --folder ... [--rule "<rule>" ...]`. It writes the docs, indexes, `schema.local.yaml`, the ci and
   staleness workflows, the pre-commit hook, a Dependabot config and a `.gitattributes` for LF, all pinned by commit to this km's
   release (or `--pin <version>`), and
   refuses to run if any file it would write already exists, such as a README the host created with
   the repo: delete that first.
3. `git add -A`, then `km gen-index` (it reads tracked files only, so add first; it fills the root
   and folder lists), `git add -A` and `km validate`: expect **0 errors / 0 warnings**.
4. Commit: `chore: initialize <name> (team served knowledge base)`.
5. Tell the user what km does not do: create the repo (private), push `main`, give the team **read**
   access and the maintainer write, and ask members to add the brain to their personal brain with
   `/km brain add <url>`. Branch protection on a private repo needs a paid GitHub plan; without it
   the one-merger rule is held by the permission model alone. Members with read access contribute by fork PR,
   and GitHub does not run Actions on fork PRs of a private repo until "Run workflows from fork pull
   requests" is enabled (repository or organization settings, Actions): without it those PRs get
   no CI. Dependabot then proposes a PR whenever a newer km is released.

## Upgrade (`/km upgrade`)

Move a brain to the km you run, without touching repo-specific files:

1. `km upgrade` moves the brain's km pins to this km's release commit (`--pin <version>` for another),
   turns a pin to a movable tag into a commit pin, and on a brain from the copy-in days drops the
   copied `scripts/*.py` and `schema.base.yaml` and rewrites its hook and km workflows. It refuses to
   move a pin to a newer km back (`--force` overrides).
2. Show `git diff`. `CONVENTIONS.md`, `CLAUDE.md`, `README.md` and every `_index.md` are repo-owned
   and stay (in `schema.local.yaml` only an obsolete `team_brain:` line goes); point out prose that
   still mentions `scripts/`.
3. Run `km validate` (expect **0 errors**); on a team brain also `km gen-index` (a newer km may list
   more, e.g. subfolder indexes) and stage what it changed.
4. Commit: `chore(km): upgrade to km <version>`
