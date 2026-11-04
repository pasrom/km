"""External sources a doc cites (`cites:`), pinned by the sha256 of the file's bytes, and
`km cites check`, which compares them with local copies.

A SharePoint or OneDrive file has no immutable link while it is current, and the hashes the service
reports are not a sha256 of the file. So each entry records the https URL a reader opens, the sha256
of the bytes the author read, and the date: a local copy (a synced library, a download) is all km
needs to tell whether the file still is what the doc was written against. Nothing here touches the
network; `km validate` checks only the entries' format.

Run:  km cites check [--root DIR] [DOC ...] (--file URL=PATH ... | --dir LOCAL=URLPREFIX ...)
      Exit 0: every entry is current or unchecked; 1: one is stale or malformed; 2: a usage error.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import os
import re
import sys
import unicodedata
import urllib.parse
from pathlib import Path
from typing import NamedTuple

from km.common import (ROOT, RETIRED_STATUS, append_fm, as_date, frontmatter, is_article, read, scalar, send_back,
                       set_fm_block, tracked_md)
from km.edit import not_a_doc

FIELD = "cites"
KEYS = ("url", "title", "version", "sha256", "retrieved", "ctag")   # the order km writes them in
REQUIRED = ("url", "sha256", "retrieved")
SHA256 = re.compile(r"[0-9a-fA-F]{64}")
DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
# Links to SharePoint and OneDrive: a doc citing such a file should record it under `cites:`.
HINT = re.compile(r"sharepoint\.(?:com|us|cn|de)|1drv\.ms|onedrive\.(?:live\.)?com", re.I)   # a cheap test first
_URL_CHAR = r"[^\s<>()\[\]\"'`|]"
BODY_URL = re.compile(rf"https?://(?:{_URL_CHAR}|\({_URL_CHAR}*\))+", re.I)   # (v2) in a name, not a link's )
# SharePoint hosts: worldwide team sites and personal OneDrive (<tenant>-my.sharepoint.com), and the
# national clouds: .cn (operated by 21Vianet); .us (US government) and .de (the former German cloud)
# are unverified against a Microsoft page.
SHAREPOINT = (".sharepoint.com", ".sharepoint.cn", ".sharepoint.us", ".sharepoint.de")
ONEDRIVE = ("onedrive.live.com", "onedrive.com", "www.onedrive.com")
# Query keys that name the file itself (OneDrive's ?id=/?resid=, Office's Doc.aspx?sourcedoc=); every
# other query key (?web=1, a sharing link's ?e=...) only changes how the same file is shown.
SHARING = re.compile(r":[a-z]:", re.I)   # the first segment of a sharing link: :w: Word, :b: PDF, :f: folder
NAMING_KEYS = ("id", "resid", "cid", "sourcedoc", "file")
VIEWERS = ("doc.aspx", "wopiframe.aspx", "wopiframe2.aspx")   # Office opening a file; other .aspx are pages, forms, views


def is_https(url) -> bool:
    if not isinstance(url, str) or any(c.isspace() for c in url):
        return False
    try:
        parts = urllib.parse.urlsplit(url)
        return parts.scheme == "https" and bool(parts.hostname)
    except ValueError:   # a malformed host, such as an unclosed [
        return False


def _iso_date(v) -> bool:
    """A plain date: YAML's date, or a YYYY-MM-DD string that is one; not a datetime."""
    return (not isinstance(v, datetime.datetime) and as_date(v) is not None
            and (isinstance(v, datetime.date) or isinstance(v, str) and bool(DATE.fullmatch(v))))


def problems(value) -> list[str]:
    """What is wrong with a `cites:` value, one line per problem; [] when every entry is well formed."""
    if value is None:
        return []
    if not isinstance(value, list):
        return ["cites must be a list of entries (- url: ...)"]
    out, seen = [], set()
    for i, e in enumerate(value, 1):
        if not isinstance(e, dict):
            out.append(f"entry {i}: must be a mapping with url, sha256 and retrieved")
            continue
        url = e.get("url")
        where = f"entry {i} ({url})" if isinstance(url, str) else f"entry {i}"
        out += [f"{where}: unknown key {k!r} (allowed: {', '.join(KEYS)})" for k in e if k not in KEYS]
        out += [f"{where}: '{k}' is required" for k in REQUIRED if k not in e]
        if "url" in e and not is_https(url):
            out.append(f"{where}: url must be an https:// URL")
        if isinstance(url, str):
            if same_url(url) in seen:
                out.append(f"{where}: the same url is cited twice")
            seen.add(same_url(url))
        if "sha256" in e and not (isinstance(e["sha256"], str) and SHA256.fullmatch(e["sha256"])):
            out.append(f"{where}: sha256 must be 64 hex digits (the file's sha256, quoted if all digits)")
        if "retrieved" in e and not _iso_date(e["retrieved"]):
            out.append(f"{where}: retrieved must be a date, YYYY-MM-DD")
        out += [f"{where}: {k} must be a string (quote it: {k}: \"{e[k]}\")"
                for k in ("title", "version", "ctag") if k in e and not isinstance(e[k], str)]
    return out


def editable(fm: dict) -> list[dict] | str:
    """A copy of a doc's `cites:` entries to edit, or the refusal when they are malformed."""
    if why := problems(fm.get(FIELD)):
        return f"its cites: entries are malformed, fix them first ({why[0]})"
    return [dict(e) for e in fm.get(FIELD) or []]


def _split(url: str):
    """(host, path segments, query) of a URL, the segments decoded (NFC) and a sharing link that
    carries the real path (`/:b:/r/sites/...`, any `:x:` with `r`) reduced to that path; None for a
    URL km cannot read."""
    try:
        p = urllib.parse.urlsplit(url)
        host = (p.hostname or "") + (f":{p.port}" if p.port else "")   # hostname is lower case
    except ValueError:
        return None
    segs = [unicodedata.normalize("NFC", urllib.parse.unquote(x)) for x in p.path.split("/") if x]
    if host.endswith(SHAREPOINT) and len(segs) > 2 and SHARING.fullmatch(segs[0]) and segs[1].lower() == "r":
        segs = segs[2:]
    return host, segs, p.query


def opaque(url: str) -> bool:
    """A link that names its file by a token or an id, not a path: a sharing link
    (`/:b:/s/<site>/<token>`, `/:b:/g/...`, 1drv.ms), Office's viewer (`.../Doc.aspx?sourcedoc=...`)
    or onedrive.live.com (`?id=...`). No local folder maps to it."""
    if (parts := _split(url)) is None:
        return False
    host, segs, _ = parts
    if host in ("1drv.ms", "onedrive.live.com"):
        return True
    return host.endswith(SHAREPOINT) and bool(segs) and (
        bool(SHARING.fullmatch(segs[0])) or segs[-1].lower() in VIEWERS)


def same_url(url: str) -> str:
    """A URL as two links to the same file are compared: http and https alike, the host in lower
    case, the path decoded without a trailing slash (and in lower case on SharePoint, which ignores
    it; a sharing link that carries the path is that path), the fragment and every query key that
    does not name the file dropped."""
    if (parts := _split(url)) is None:
        return url
    host, segs, query = parts
    naming = sorted((k.lower(), v) for k, v in urllib.parse.parse_qsl(query) if k.lower() in NAMING_KEYS)
    path = "/" + "/".join(segs)
    return f"//{host}{fold(path) if host.endswith(SHAREPOINT) else path}" + (
        f"?{urllib.parse.urlencode(naming)}" if naming else "")


def watched(url: str) -> bool:
    """Whether `url` is a SharePoint or OneDrive link that can name a file: not a site, a folder
    (a path whose last segment has no extension, a `/:f:/` or 1drv.ms `/f/` sharing link), a page,
    a list form or a library view (an .aspx other than Office's viewer)."""
    if (parts := _split(url)) is None:
        return False
    host, segs, query = parts
    if host == "1drv.ms":
        return bool(segs) and segs[0].lower() != "f"
    if host in ONEDRIVE:
        named = {k.lower() for k, _ in urllib.parse.parse_qsl(query)} & {"id", "resid"}
        return bool(named) or bool(segs) and "." in segs[-1]
    if not host.endswith(SHAREPOINT):
        return False
    if segs and SHARING.fullmatch(segs[0]):   # an opaque sharing link: :w: Word, :b: PDF, :f: folder
        return segs[0][1].lower() != "f"
    if not segs or "." not in segs[-1]:
        return False
    return not segs[-1].lower().endswith(".aspx") or segs[-1].lower() in VIEWERS


def uncited(body: str, fm: dict, strip=lambda s: s) -> list[str]:
    """SharePoint and OneDrive URLs `body` links to that no `cites:` entry records, each once, in
    order; `strip` removes what is not a link (code), and runs only when there may be one."""
    if not HINT.search(body):
        return []
    body = strip(body)
    cited = {same_url(e["url"]) for e in as_entries(fm.get(FIELD))}
    out = []
    for m in BODY_URL.finditer(body):
        url = m.group(0).rstrip(".,;:!?*_")
        if watched(url) and (key := same_url(url)) not in cited:
            cited.add(key)
            out.append(url)
    return out


def as_entries(value) -> list[dict]:
    """Every mapping with a string url in a `cites:` value, well formed or not."""
    return [e for e in value if isinstance(e, dict) and isinstance(e.get("url"), str)] if isinstance(value, list) else []


def sha256_file(path: Path) -> str:
    """The sha256 of a file's bytes, read in chunks: a file of any size."""
    with open(path, "rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def fold(name: str) -> str:
    """A file or folder name as SharePoint, APFS and NTFS compare it: NFC, case-insensitive."""
    return unicodedata.normalize("NFC", name).casefold()


def render(items: list[dict]) -> str:
    """A `cites:` block from its entries, keys in km's order, values as YAML reads them back."""
    lines = [f"{FIELD}:"]
    for e in items:
        for n, k in enumerate(k for k in KEYS if k in e):   # problems() rejected any other key
            v = e[k]
            text = v.isoformat() if isinstance(v, datetime.date) else scalar(str(v))
            lines.append(f"{'- ' if n == 0 else '  '}{k}: {text}")
    return "\n".join(lines)


def write(fm: dict, raw: str, items: list[dict], message: str, changed: bool):
    """`change` for `edit_docs`: `raw` with its `cites:` block replaced by `items`, or added last,
    the other lines byte for byte. A signed-off doc whose cited content `changed` goes back to
    review. The refusal if the doc has a `cites` key this edit cannot find (quoted, say)."""
    text = render(items)
    raw = set_fm_block(raw, FIELD, text) if FIELD in fm else append_fm(raw, text)
    if raw is None:
        return f"cannot find the `{FIELD}:` line to rewrite"
    return send_back(fm, raw, message) if changed else (raw, message)


DIR_FORM = ('--dir "LOCAL=URLPREFIX", e.g. --dir "$HOME/Example - Documents='
            'https://example.sharepoint.com/sites/Example/Shared Documents"')


class Library(NamedTuple):
    """A synced library or folder: `local` holds exactly what the URL prefix holds."""
    local: Path
    prefix: str
    host: str
    segs: list[str]   # the prefix's path, folded


class Located(NamedTuple):
    """Where the local copy of a cited file is, or why there is none to compare: `missing` when
    there is simply no copy (not synced, not under any library), not when km cannot tell which."""
    path: Path | None
    why: str = ""
    missing: bool = False


class Copies:
    """The local copies to compare cited files with: one per URL (`--file URL=PATH`), or found in a
    synced library or folder mapped to its URL prefix (`--dir LOCAL=URLPREFIX`). A URL below a
    prefix names exactly one local path, segment by segment (decoded, NFC, case-insensitive);
    nothing is searched for by name, so a namesake in another library or folder never counts."""

    def __init__(self, files: dict[str, Path] | None = None, libraries: list[Library] | None = None):
        self.files = {same_url(u): p for u, p in (files or {}).items()}
        self.libraries = libraries or []
        self._hashes: dict[Path, str] = {}
        self.used: set[str] = set()
        self.hit: set[str] = set()   # the prefixes of the libraries some cited URL fell under

    def sha256(self, path: Path) -> str:
        """sha256_file, once per file and run; an OSError propagates."""
        if path not in self._hashes:
            self._hashes[path] = sha256_file(path)
        return self._hashes[path]

    def locate(self, url: str) -> Located:
        key = same_url(url)
        if key in self.files:
            self.used.add(key)
            return Located(self.files[key])
        if not self.libraries:
            return Located(None, "no local copy given", missing=True)
        host, segs, _ = _split(url) or ("", [], "")
        folded = [fold(x) for x in segs]
        under = [lib for lib in self.libraries if lib.host == host and folded[:len(lib.segs)] == lib.segs]
        if not under:
            return Located(None, "not under any --dir library", missing=True)
        lib = max(under, key=lambda x: len(x.segs))   # the most specific library
        self.hit.add(lib.prefix)
        path = lib.local
        for name in segs[len(lib.segs):]:
            try:
                hits = [n for n in os.listdir(path) if fold(n) == fold(name)]
            except OSError:
                hits = []
            if len(hits) > 1:   # a case-sensitive disk with names that differ only in case
                return Located(None, f"{path} holds {', '.join(hits)}, which differ only in case; "
                                     f"pass the copy with --file URL=PATH")
            if not hits:
                return Located(None, f"no local copy at {lib.local.joinpath(*segs[len(lib.segs):])}", missing=True)
            path = path / hits[0]
        if not path.is_file():
            return Located(None, f"{path} is not a file", missing=True)
        return Located(path)

    def hint(self) -> str | None:
        """What to say about --dir libraries no cited URL fell under (a mistyped prefix, a parent
        folder instead of the library)."""
        idle = [lib.prefix for lib in self.libraries if lib.prefix not in self.hit]
        if idle:
            return (f"no cited URL is under --dir {', '.join(idle)}; point LOCAL at the synced library "
                    f"or folder itself and URLPREFIX at its URL: {DIR_FORM}")
        return None


def parse_files(specs: list[str]) -> dict[str, Path] | str:
    """`--file URL=PATH` arguments as {url: path}, or what is wrong with one. A URL may itself hold
    '=' (a query), so the split is at the first '=' after which an existing file is named."""
    out = {}
    for spec in specs:
        cuts = [i for i, c in enumerate(spec) if c == "="]
        hit = next((i for i in cuts if Path(spec[i + 1:]).is_file()), None)
        if hit is None:
            return f"--file {spec}: expected URL=PATH with PATH an existing file"
        url, path = spec[:hit], Path(spec[hit + 1:])
        if not is_https(url):
            return f"--file {spec}: {url!r} is not an https:// URL"
        out[url] = path
    return out


def parse_dirs(specs: list[str]) -> list[Library] | str:
    """`--dir LOCAL=URLPREFIX` arguments as libraries, or what is wrong with one. The split is at the
    '=' before `https://`, so LOCAL may hold '=' and the prefix may hold spaces."""
    out = []
    for spec in specs:
        if not (m := re.search(r"=(?=https://)", spec, re.I)):
            return f"--dir {spec}: expected {DIR_FORM}"
        local, prefix = Path(spec[:m.start()]).expanduser(), spec[m.end():]
        parts = _split(prefix)
        if not parts or not parts[0]:
            return f"--dir {spec}: {prefix!r} is not an https:// URL; expected {DIR_FORM}"
        if opaque(prefix):
            return f"--dir {spec}: {prefix!r} is a sharing or viewer link, not the library's path URL; expected {DIR_FORM}"
        if not local.is_dir():
            return f"--dir {spec}: the local folder {local} does not exist; expected {DIR_FORM}"
        out.append(Library(local, prefix, parts[0], [fold(x) for x in parts[1]]))
    return out


def add_copy_args(ap: argparse.ArgumentParser, required: bool = False) -> None:
    g = ap.add_mutually_exclusive_group(required=required)
    g.add_argument("--file", action="append", default=[], metavar="URL=PATH",
                   help="a local copy of the file the URL names (repeatable)")
    g.add_argument("--dir", action="append", default=[], metavar="LOCAL=URLPREFIX",
                   help="a synced library or folder and the URL it holds (repeatable)")


def copies_from(a: argparse.Namespace) -> Copies | str:
    if a.dir:
        libraries = parse_dirs(a.dir)
        return libraries if isinstance(libraries, str) else Copies(libraries=libraries)
    files = parse_files(a.file)
    return files if isinstance(files, str) else Copies(files=files)


class Reading(NamedTuple):
    """What the local copy says about one entry: its sha256, or '' with `why` saying why there is
    none to compare (`missing` when there is simply no copy)."""
    digest: str
    copy: Path | None
    why: str
    missing: bool = False


def read_copies(entry: dict, copies: Copies) -> Reading:
    """The sha256 of the entry's file as its local copy has it, or why it does not tell."""
    loc = copies.locate(entry["url"])
    if loc.path is None:
        return Reading("", None, loc.why, loc.missing)
    try:
        return Reading(copies.sha256(loc.path), loc.path, "")
    except OSError as e:
        return Reading("", None, f"{loc.path}: unreadable, {e.strerror or e}")


def compare(entry: dict, copies: Copies) -> tuple[str, str]:
    """(status, detail) of one entry against its local copy: current or stale, or unchecked (with
    the reason) when there is none it can tell from."""
    r = read_copies(entry, copies)
    want = entry["sha256"].lower()
    if not r.digest:
        return "unchecked", r.why
    if r.digest == want:
        return "current", str(r.copy)
    return "stale", f"recorded {want[:12]}, retrieved {entry['retrieved']}; {r.copy}: {r.digest[:12]}"


def _docs(given: list[str]) -> list[str] | str:
    if not given:
        return [p for p in tracked_md() if is_article(p)]
    paths = [Path(d).resolve() for d in given]
    if why := next(filter(None, (not_a_doc(d, p) for d, p in zip(given, paths))), ""):
        return why
    return [p.relative_to(ROOT).as_posix() for p in paths]


def main() -> int:
    ap = argparse.ArgumentParser(prog="km cites", description="Compare the files docs cite with local copies.")
    sub = ap.add_subparsers(dest="action", required=True)
    chk = sub.add_parser("check", help="report each cited file as current, stale or unchecked; writes nothing")
    chk.add_argument("docs", nargs="*", help="docs to check (default: every doc)")
    add_copy_args(chk, required=True)
    a = ap.parse_args()
    copies, docs = copies_from(a), _docs(a.docs)
    for bad in (copies, docs):
        if isinstance(bad, str):
            print(f"km cites: {bad}", file=sys.stderr)
            return 2
    counts = {"current": 0, "stale": 0, "unchecked": 0, "invalid": 0}
    for rel in docs:
        fm = frontmatter(read(rel))
        if fm.get("status") in RETIRED_STATUS or not (value := fm.get(FIELD)):
            continue
        print(rel)
        whole = problems(value)
        for i, e in enumerate(value if isinstance(value, list) else [value], 1):
            if why := [w for w in whole if not isinstance(value, list) or w.startswith((f"entry {i}:", f"entry {i} ("))]:
                counts["invalid"] += 1
                label = e.get("url") if isinstance(e, dict) and isinstance(e.get("url"), str) else "cites:"
                print(f"  {'invalid':<10} {label} ({why[0]}; see km validate)")
                continue
            status, detail = compare(e, copies)
            counts[status] += 1
            print(f"  {status:<10} {e['url']} ({detail})")
    for url in sorted(set(copies.files) - copies.used):
        print(f"km cites: no doc checked cites {url}", file=sys.stderr)
    if hint := copies.hint():
        print(f"km cites: {hint}", file=sys.stderr)
    print(f"km cites: {', '.join(f'{n} {s}' for s, n in counts.items() if n or s != 'invalid')}")
    return 1 if counts["stale"] or counts["invalid"] else 0


if __name__ == "__main__":
    sys.exit(main())
