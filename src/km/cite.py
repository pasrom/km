"""Record an external file a doc cites: `km cite add` writes (or replaces) the doc's `cites:` entry
for a URL, with the sha256 of a local copy of the file (a synced SharePoint or OneDrive library, a
download) and today's date. km downloads nothing: the copy must be on disk.

The `cites:` block is rewritten, the rest of the frontmatter is kept byte for byte, and the doc is
then gated by `km validate` and restored unchanged if that fails. A new file, or new content for a
cited one, sends a signed-off doc back to review, as `km repin --cites` does: the approval never saw
it (an approval key it cannot find, quoted, stays, named, and the run exits 1). Replacing an entry keeps its title and drops its version label and ctag, which named the old
content. The same content again changes nothing (only a different --title or --version is written).

Run:  km cite add [--root DIR] <doc.md> <https URL> --file <local copy> [--title T] [--version V]
"""
from __future__ import annotations

import argparse
import datetime
import sys
from pathlib import Path

from km.cites import editable, is_https, opaque, same_url, sha256_file, write
from km.edit import edit_sending_back


def change_for(url: str, digest: str, title: str | None, version: str | None, today: datetime.date):
    def change(fm: dict, raw: str, _body: str):
        if isinstance(items := editable(fm), str):
            return items
        old = next((e for e in items if same_url(e["url"]) == same_url(url)), None)
        given = {k: v for k, v in (("title", title), ("version", version)) if v is not None}
        if old is not None and old["sha256"].lower() == digest:   # the same content: keep the entry
            if not (labels := {k: v for k, v in given.items() if old.get(k) != v}):
                return raw, f"already cites {old['url']} with this content (sha256 {digest[:12]})"
            old.update(labels)
            return write(fm, raw, items, f"relabels {old['url']} ({', '.join(labels)})", changed=False)
        entry = {"url": url, **({"title": old["title"]} if old and "title" in old else {}), **given,
                 "sha256": digest, "retrieved": today}
        if old is None:
            items.append(entry)
            message = f"cites {url} (sha256 {digest[:12]})"
        else:
            items[items.index(old)] = entry
            message = f"re-cites {url} (sha256 {digest[:12]}, changed)"
        return write(fm, raw, items, message, changed=True)   # the approval never saw this content
    return change


def main() -> int:
    ap = argparse.ArgumentParser(prog="km cite", description="Record an external file a doc cites.")
    sub = ap.add_subparsers(dest="action", required=True)
    add = sub.add_parser("add", help="write or replace the doc's cites: entry for URL")
    add.add_argument("doc")
    add.add_argument("url", help="the https URL a reader opens")
    add.add_argument("--file", required=True, type=Path, help="a local copy of the file; it is hashed, not uploaded")
    add.add_argument("--title")
    add.add_argument("--version", help="a version label, e.g. SharePoint's 3.0")
    a = ap.parse_args()
    if not is_https(a.url):
        print(f"km cite: {a.url!r} is not an https:// URL", file=sys.stderr)
        return 2
    if opaque(a.url):
        print(f"km cite: {a.url} is a sharing link that names the file by a token, not a path, so no "
              f"synced library maps to it; cite the file's path URL instead (https://<host>/sites/<site>/"
              f"<library>/.../<file>, as the library shows it, or a /:x:/r/ link)", file=sys.stderr)
        return 2
    try:
        digest = sha256_file(a.file)
    except OSError as e:
        print(f"km cite: --file {a.file}: {e.strerror or e}", file=sys.stderr)
        return 2
    return edit_sending_back([a.doc], change_for(a.url, digest, a.title, a.version, datetime.date.today()), "cite")


if __name__ == "__main__":
    sys.exit(main())
