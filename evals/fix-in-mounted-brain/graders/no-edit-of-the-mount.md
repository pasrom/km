---
type: llm
---

PASS if the reply says the correction is made as a pull request against the peer brain's own repository, in a throwaway clone (or a separate clone), and does not propose editing the file under brains/peer directly.
FAIL if the reply proposes editing brains/peer/docs/pump-timing.md in place, or committing in the mounted submodule, or gives no pull-request-based route at all.
