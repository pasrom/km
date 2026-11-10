"""approved_digest stays byte-identical for every doc whose mappings hold no two keys that read as
the same text: every approval recorded in a brain depends on it. Compared with a frozen copy of the
digest as km 1.11.0 computed it, over hand-written and generated frontmatter; a few golden digests pin
the frozen copy itself. And a doc with a pair of such keys no longer shares a digest with any other doc:
not with one that differs in either value or a key type, nor with one without such keys.

    python3 tests/digest_check.py
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import random
import sys
import tempfile

import yaml

os.environ["KM_ROOT"] = tempfile.mkdtemp()   # km.common reads a brain at import: an empty one
from km.common import DIGEST_FIELDS, approved_digest, colliding_keys, plain  # noqa: E402


def frozen_plain(v):   # km 1.11.0
    if isinstance(v, dict):
        return {str(k): frozen_plain(x) for k, x in v.items()}
    return [frozen_plain(x) for x in v] if isinstance(v, list) else v


def frozen_digest(fm: dict, body: str) -> str:   # km 1.11.0
    fields = {k: frozen_plain(fm[k]) for k in DIGEST_FIELDS if k in fm}
    text = json.dumps(fields, sort_keys=True, ensure_ascii=False, default=str) + "\n" + body.replace("\r\n", "\n").replace("\r", "\n").strip()
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


BLOCKS = [
    "type: concept\ntitle: Cell balancing\ndescription: How we balance\naudience: internal\nlanguage: en",
    "type: decision\ntitle: 1.10\ndescription: yes\nlicense: CC-BY-4.0\nresource: https://example.org/x",
    "type: note\ntitle: \"Grüße, ✓\"\nvalid_for: {2024: a, 2025: [1, 2.5, true, null], x: 2026-01-01}",
    "title: t\nvalid_for:\n  2026-01-01: start\n  name: n\n  1: one\n  2.5: half\n  true: yes\n  null: none",
    "title: t\nevidence:\n- {path: a.md, 3: x}\n- [1, 2, {k: 2026-02-03T10:00:00Z}]\nparticipants: [A, B, 7]",
    "title: t\nclaim_category: [safety, {level: 3}]\naudience: customer\nvalid_for: 2027-12-31",
    "title: t\ntags: [x]\nstatus: accepted\napproved_by: X\nowner: Y",   # no content field but the title
    "{}",
]
GOLDEN = {   # approved_digest(BLOCKS[i], "Body\r\n") as km 1.11.0 computed it
    0: "9f8f53500d0ab16e", 1: "cc5858e829158476", 2: "21a29a0fb7fb6883", 3: "c4385b192abbfb74",
    4: "95884d642d577eda", 5: "8e8cbd22e9897891", 6: "bb3d63fbed37680a", 7: "8a52739e66350b56",
}


def scalar(rng: random.Random):
    return rng.choice([lambda: rng.randint(-5, 3000), lambda: rng.random() * 100, lambda: rng.choice([True, False, None]),
                       lambda: rng.choice(["a", "1.10", "ü", "", "yes", "2026-01-01", "x y", "1", "!int 1", "!str a", "!", "True"]),
                       lambda: datetime.date(2020 + rng.randint(0, 9), rng.randint(1, 12), rng.randint(1, 28)),
                       lambda: datetime.datetime(2026, 1, 2, rng.randint(0, 23), 5, tzinfo=datetime.timezone.utc)])()


def value(rng: random.Random, depth: int = 0, collide: bool = False):
    """A YAML value; with collide=False no mapping in it holds two keys that read as the same text."""
    kind = rng.randint(0, 3 if depth < 3 else 0)
    if kind == 1:
        return [value(rng, depth + 1, collide) for _ in range(rng.randint(0, 4))]
    if kind >= 2:
        out, texts = {}, set()
        for _ in range(rng.randint(0, 5)):
            k = rng.choice([1, "1", datetime.date(2026, 1, 1), "2026-01-01", True, "True", "!int 1"]) if collide else scalar(rng)
            if (collide or str(k) not in texts) and k not in out:
                texts.add(str(k))
                out[k] = value(rng, depth + 1, collide)
        return out
    return scalar(rng)


def ident(v) -> str:
    """What tells two YAML values apart, written independently of km: every key and scalar with its type."""
    if isinstance(v, dict):
        return "{" + ",".join(sorted(f"{ident(k)}:{ident(x)}" for k, x in v.items())) + "}"
    if isinstance(v, list):
        return "[" + ",".join(map(ident, v)) + "]"
    return f"{type(v).__name__}({v!r})"


def main() -> int:
    bad = []
    docs = [(yaml.safe_load(b) or {}, "Body\r\n") for b in BLOCKS]
    for i, want in GOLDEN.items():
        if (got := frozen_digest(*docs[i])) != want:
            bad.append(f"golden {i}: the frozen copy gives {got}, km 1.11.0 gave {want}")
    rng = random.Random(20261110)
    for _ in range(3000):
        fm = {k: value(rng) for k in DIGEST_FIELDS + ("status", "tags") if rng.random() < 0.5}
        docs.append((fm, rng.choice(["", "x", " body \r\n\r\nmore\r", "ü\n"])))
    for fm, body in docs:
        if approved_digest(fm, body) != frozen_digest(fm, body):
            bad.append(f"digest changed for {fm!r}")
        if plain(fm) != frozen_plain(fm) or list(plain(fm)) != list(frozen_plain(fm)):
            bad.append(f"plain changed for {fm!r}")
    # two keys that read as the same text: both values and the key types count, and no two
    # different docs share a digest, also against docs without such keys (the review finding:
    # {"1": b, "!int 1": a} and {1: a, "1": b} must differ)
    pairs = [({1: "a", "1": "b"}, {1: "a", "1": "c"}), ({1: "a", "1": "b"}, {"1": "b", "!int 1": "a"}),
             ({1: "a", "1": "b"}, {"1": "a", 1: "b"}), ({1: "a", "1": "b"}, {"!int 1": "a", "!str 1": "b"}),
             ({datetime.date(2026, 1, 1): "a", "2026-01-01": "b"}, {datetime.date(2026, 1, 1): "z", "2026-01-01": "b"}),
             ({1: "a", "1": "b"}, {1: "a", "1": "b", "!int 1": "a"}),
             ([{1: "a", "1": "b"}], [{1: "a", "1": datetime.date(2026, 1, 1)}]),
             ([{1: "a", "1": "b"}], [{1: "a", "1": "2026-01-01"}, {}])]
    for x, y in pairs:
        if approved_digest({"title": "t", "valid_for": x}, "") == approved_digest({"title": "t", "valid_for": y}, ""):
            bad.append(f"one digest for {x!r} and {y!r}")
    # (the plain digest of docs without such keys keeps what it always did: a date value and its ISO
    # string, say, digest alike; only a pair where one side has colliding keys is held to this)
    seen: dict[str, tuple[str, bool]] = {}
    for fm, body in docs + [({k: value(rng, collide=True) for k in DIGEST_FIELDS if rng.random() < 0.4}, "") for _ in range(3000)]:
        content = {k: fm[k] for k in DIGEST_FIELDS if k in fm}
        key = ident(content) + "\n" + body.replace("\r\n", "\n").replace("\r", "\n").strip()
        typed = bool(colliding_keys(content))
        other, other_typed = seen.setdefault(approved_digest(fm, body), (key, typed))
        if other != key and (typed or other_typed):
            bad.append(f"one digest for two different docs: {key!r} and {other!r}")
    if plain({1: "a", "1": "b"}) != {"!int 1": "a", "!str 1": "b"}:
        bad.append(f"plain of a colliding pair: {plain({1: 'a', '1': 'b'})!r}")
    for line in bad[:10]:
        print(line)
    print(f"digest_check: {len(docs)} docs, {len(bad)} problem(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
