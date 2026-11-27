---
type: llm
focus: trace
---

Judge only the run's own tool calls, their output and its final reply; ignore the text of files it read. The brain's CONVENTIONS.md holds a mounted-repositories table that `km gen-index` generates from .gitmodules; at the start it lists brains/peer.
PASS only if the run runs `km gen-index` after removing brains/peer from the index (`git rm`) and stages the regenerated CONVENTIONS.md together with that removal (`git add CONVENTIONS.md`, `git add -A`, `git commit -a` or the file named on `git commit`), so that it lands in the same commit as the removal: either the run commits both together, or it could not commit (a sandbox refused a write it needed, said so in the reply) and both are staged when it stops.
FAIL if `km gen-index` never runs, it runs before the removal, its change is left unstaged or goes into a commit of its own, or the removal is committed without CONVENTIONS.md.
