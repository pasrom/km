# km

The km knowledge-management skill for Claude Code, plus the scripts and workflows it copies into brains. See README.md for the layout.

## Conventions

- Language: English for code, comments, documentation and commit messages.
- Public repository: no employer, customer, host or ticket names in code, examples, tests or history.
- Conventional Commits `type(scope): description`; one logical change per commit.
- Python 3.11+, only PyYAML as a dependency. The package lives in `src/km/`; each command is a module with a `main()` that `km.cli` calls.
- Shell scripts: `bash`, portable (macOS + Linux).
- Brains pin a km version and never carry km code, but their `schema.local.yaml`, docs and templates from earlier versions stay: keep new versions working on them, and keep `km upgrade` able to move an older brain forward.
- The one exception is the team template `bump-mounted-pins.py` (with its workflow), copied into a team brain because the job holding the app token must not install third-party code, the km package included. `km upgrade` replaces a copy whose hash is in `SHIPPED` (src/km/upgrade.py): a change to either template adds its new hash there and keeps the old ones (a test checks the current one is listed).
- A release bumps `src/km/__init__.py`, `.claude-plugin/plugin.json` and the README examples together (a test checks it). Merging it to main is the release: CI tags `vX.Y.Z` once main is green. The templates pin the tag of the km that wrote them.
- Run all the smoke tests before pushing; add a case for every behaviour change and check that it fails without the change.
- A change under `skills/km/` runs the plugin evals before merge (CI does not run them, they cost money); `evals/README.md` says which cases and how to report them.
