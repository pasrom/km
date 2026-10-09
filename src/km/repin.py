"""Pin each source of a doc to its current content: every entry of a pinned field (`sources`,
`translates`) whose source changed since its pin, or that has no hash yet, is rewritten as
`path.md@<blob>`, the source's blob as staged now, abbreviated. Pins that still match are left alone.

A blob pin depends only on the file's content, so unlike a commit pin it survives a rebase or squash
merge. Run it when a doc is written, and after re-reviewing it when `km validate` reports a stale
pin. An approval vouches for the sources it saw: a signed-off doc whose pins change goes back to
`status: review` without its approval and pre-reviews (`reviewed_by`), to be approved again. Only
the pinned fields are rewritten, as plain YAML; the doc is then gated by `km validate` and restored unchanged if that fails.

Run:  km repin [--root DIR] <doc.md>...
"""
from __future__ import annotations

import argparse
import json
import sys

import yaml

from km.common import PIN, SCHEMA, SERVED_STATUS, as_list, demote_raw, pin_state, set_fm_block, staged_blob
from km.edit import edit_docs

ABBREV = 12   # hex digits of a written pin: unambiguous in any brain, short enough to read
PINNED = [f for f, spec in SCHEMA["fields"].items() if spec.get("format") == "path_at_hash"]


def scalar(value: str) -> str:
    """`value` as a YAML scalar: plain where YAML reads it back unchanged, else double-quoted."""
    try:
        if yaml.safe_load(f"k: {value}") == {"k": value}:
            return value
    except yaml.YAMLError:
        pass
    return json.dumps(value)


def change(fm: dict, raw: str):
    """Re-pin one doc's frontmatter: the refusal, or `(new_raw, message)` for `edit_docs`."""
    before, changed, missing, uncompared = raw, [], [], []
    for field in PINNED:
        values = [v for v in as_list(fm.get(field)) if v]   # an empty entry, as validate skips it
        if not values:
            continue
        pins, before_field = [], len(changed)
        for v in values:
            m = PIN.match(str(v))
            src = (m.group(1) if m else str(v)).strip()
            state = pin_state(str(v)) if m else None
            if state == "current":
                pins.append(str(v))
                continue
            if state == "unknown":
                uncompared.append(src)
            blob = staged_blob(src) if src.endswith(".md") else ""
            if not blob:
                missing.append(src)
                continue
            pins.append(f"{src}@{blob[:ABBREV]}")
            changed.append(src)
        if len(changed) == before_field:
            continue                    # every pin of this field is current: leave its lines alone
        text = ("\n".join([f"{field}:", *(f"- {scalar(p)}" for p in pins)])
                if isinstance(fm.get(field), list) else f"{field}: {scalar(pins[0])}")
        if (raw := set_fm_block(raw, field, text)) is None:
            return f"cannot find the `{field}:` line to rewrite"
    if missing:
        return f"not a tracked .md file, cannot pin: {', '.join(missing)}"
    if not changed:
        return before, "already pins the current content"
    message = f"pins the current content of {', '.join(changed)}"
    if uncompared:
        message += f"; could not compare {', '.join(uncompared)} with the old pin (not in this clone's history)"
    if fm.get("status") == SERVED_STATUS:   # the approval saw other sources: sign off again
        if (raw := demote_raw(raw)) is None:
            return "signed off, but its status line cannot be rewritten to review"
        if "reviewed_by" in fm and (raw := set_fm_block(raw, "reviewed_by", "")) is None:
            return "cannot find the `reviewed_by:` line to drop"   # pre-reviews saw the old sources
        message += "; back to review without its approval, run `km approve` after review"
    return raw, message


def main() -> int:
    ap = argparse.ArgumentParser(prog="km repin")
    ap.add_argument("docs", nargs="+")
    a = ap.parse_args()
    refused = edit_docs(a.docs, change, "repin")
    for why in refused:
        print(f"repin: REFUSED {why}")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
