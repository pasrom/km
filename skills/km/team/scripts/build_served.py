# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Build the SERVED bundle: the filtered, machine-readable feed AI/RAG tools read (people read the
repo itself).

'Served' = git-tracked AND the served status (gate.served_status, default accepted) AND an allowed
audience (CONVENTIONS.md). Writes per-audience JSONL bundles + a manifest under dist/served/
(gitignored; CI uploads it as an artifact). Blame-free (no author/commit history), permission-aware (customer bundle excludes
internal docs), git-free to consume.

km-owned (team brains): copied in by `/km init --team`, refreshed by `/km upgrade`; do not edit a
brain's copy, change it in km.

Run:  python3 scripts/build_served.py
"""
from __future__ import annotations

import datetime
import json
import re
import sys
from pathlib import Path

from team_common import CUSTOMER_AUDIENCE, ROOT, SERVED_STATUS, is_article, read, split_frontmatter, tracked_md

OUT = ROOT / "dist" / "served"
ALLOWED_AUDIENCE = {"internal", CUSTOMER_AUDIENCE}


def write_jsonl(path: Path, records: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as fh:
        for r in records:
            fh.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    accepted: list[dict] = []
    skipped_bad_audience = 0
    for rel in tracked_md():
        if not is_article(rel):
            continue
        fm, _, body = split_frontmatter(read(rel))
        if not fm or fm.get("status") != SERVED_STATUS:
            continue
        audience = fm.get("audience", "internal")
        if audience not in ALLOWED_AUDIENCE:
            skipped_bad_audience += 1
            continue
        accepted.append({
            "path": rel,
            "title": fm.get("title"),
            "type": fm.get("type"),
            "tags": fm.get("tags") or [],
            "audience": audience,
            "language": fm.get("language"),
            "ticket": fm.get("ticket"),
            "updated": str(fm.get("timestamp")) if fm.get("timestamp") is not None else None,
            "body": re.sub(r"<!--.*?-->", "", body, flags=re.S).strip(),   # HTML comments never ship
        })

    accepted.sort(key=lambda r: r["path"])
    customer = [r for r in accepted if r["audience"] == CUSTOMER_AUDIENCE]   # customer-safe subset
    write_jsonl(OUT / "internal.jsonl", accepted)                           # the internal view: every served doc
    write_jsonl(OUT / "customer.jsonl", customer)
    manifest = {
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "counts": {"internal": len(accepted), "customer": len(customer)},
        "skipped_bad_audience": skipped_bad_audience,
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"served: internal={len(accepted)} customer={len(customer)} "
          f"(bad-audience skipped {skipped_bad_audience}) -> {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
