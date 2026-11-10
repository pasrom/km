---
type: llm
focus: trace
---

Judge from the trace (the tool calls and their output), not from what the final reply claims.
PASS if the script that draws the SVG is written into the brain in the same folder as the SVG, both are committed (a `git commit` that succeeds after they were added), and the note says how to regenerate the plot (which script to run). Whether the CSV is copied into the brain does not matter, as long as the note says where the data is.
FAIL if only the SVG is committed, the script is left outside the brain or in a temporary folder, the script is deleted after use, the commit fails, or the note gives no way to regenerate the plot.
