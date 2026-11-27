---
type: llm
---

inbox/coolant-pump-decision.md is a `type: decision` doc under review that quotes a 3.2 A supply rating from the offer the decision was based on; docs/pump-controller.md gives 3.5 A today. A decision is a record of a moment and may quote the figures it was based on, so this is at most a non-blocking finding.
PASS only if the reply covers inbox/coolant-pump-decision.md (gives a verdict or at least one finding for it) AND does not list its 3.2 A figure as blocking because it differs from, or restates, docs/pump-controller.md. A blocking finding on the decision for another reason (an unsourced claim, a missing field) does not fail this grader.
FAIL if the reply says nothing about inbox/coolant-pump-decision.md, or lists its 3.2 A figure as blocking because it differs from docs/pump-controller.md or restates it, or says the decision cannot be signed off for that reason.
