# Evals

One case per row of the dispatch table in `skills/km/SKILL.md`, plus a negative case. Each case scaffolds a brain with `km init` from this checkout (`lib/brain.sh`), so run with `--scaffold`; the write and shell cases need `--allow-tools Bash Write Edit`, and every shell command then runs in Claude Code's sandbox inside the fixture brain.

Each case whose row names a reference file has a `reads-reference` grader (that file was read); `help` and `save content` name only the core, so they have none. Every case has one grader on the flow's key step (the `km` command it runs, the file it writes, the line it answers), which the pre-split skill passes as well. Graders are `tool_used` and `regex`, except one `llm` grader in `fix-in-mounted-brain`.

Run from the plugin root: `claude plugin eval . --scaffold --no-publish --ablation none --allow-tools Bash Write Edit`; `--tag batch2` selects the nine dispatch cases, and the no-plugin baseline (`--ablation with-without`) is worth its cost only when a grader changes. `results/` is ignored.
