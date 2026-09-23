# km

The km knowledge-management skill for Claude Code, plus the scripts and workflows it copies into
brains. See README.md for the layout.

## Conventions

- Language: English for code, comments, documentation and commit messages.
- Public repository: no employer, customer, host or ticket names in code, examples, tests or history.
- Conventional Commits `type(scope): description`; one logical change per commit.
- Python 3.11+, only PyYAML as a dependency; the scripts run standalone once copied into a brain.
- Shell scripts: `bash`, portable (macOS + Linux).
- Files a brain receives are km-owned: a change to one reaches brains through `/km upgrade`, so keep
  them backward compatible with brains initialized earlier.
- Run all three smoke tests before pushing; add a case for every behaviour change and check that it
  fails without the change.
