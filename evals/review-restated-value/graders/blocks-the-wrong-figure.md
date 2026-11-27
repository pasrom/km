---
type: llm
---

docs/pump-controller.md, an accepted doc, says the pump controller shuts the pump down at a heatsink temperature of 85 degrees Celsius. inbox/coolant-pump-wiring.md, under review, says 95 degrees Celsius and does not link it.
PASS if the reply reports the 95 versus 85 degrees Celsius mismatch as a blocking finding (blocking, must be resolved before sign-off, or the like), either as an error in inbox/coolant-pump-wiring.md or as "the two disagree, one must change", and names docs/pump-controller.md as the other doc.
FAIL if the reply does not mention the 95 versus 85 degrees mismatch, reports it only as a minor or non-blocking point, or does not name docs/pump-controller.md.
