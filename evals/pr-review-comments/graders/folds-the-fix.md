---
type: llm
focus: trace
---

Judge only the run's own tool calls, their output and its final reply; ignore the text of files it read. The branch has one commit, "docs(inbox): thermal derating", which adds inbox/thermal-derating.md, and the PR is already pushed.
PASS if the fix to that doc ends up folded into that commit (a fixup and rebase, or an amend, after which the branch still has one commit on that doc), the push it gives or runs is a `--force-with-lease` naming the branch and the PR head it started from, and thread 1's reply names the short sha of the folded head.
FAIL if the fix stays a separate commit on the branch, the push is a plain `--force` or a lease without the expected head, or the reply names a commit the fold replaced.
