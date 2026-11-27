#!/usr/bin/env bash
# Smoke test for the ownership table in CONVENTIONS.md (km.ownership): km gen-index fills the
# mounted-repositories block from .gitmodules (only paths the index holds as gitlinks), km validate
# warns on it, km upgrade adds the section. Runs on Windows too.
# Run:  bash tests/ownership_smoke.sh
set -u
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T" "${OW:-}" "${OS:-}" "${U:-}"' EXIT
doc(){ printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nbody\n' > "$1"; }
idx(){ printf -- '---\ntype: reference\ntitle: idx\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\n%b\n' "$2" > "$1"; }
has(){ echo "$out" | grep -q "$1"; }
conv(){ kmpy - "$OW/CONVENTIONS.md" "$1" <<'PY'   # conv PYTHON-EXPR: rewrite CONVENTIONS.md as the expression of t (its text) gives it
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8", newline="").read()
open(p, "w", encoding="utf-8", newline="").write(eval(sys.argv[2]))
PY
}

OW="$(mktemp -d)"; OS="$(mktemp -d)"
for r in peer res other; do git init -q "$OS/$r" && doc "$OS/$r/x.md" && git -C "$OS/$r" add -A && git -C "$OS/$r" "${G[@]}" commit -qm one; done
printf -- '---\ntype: note\ntitle: t\ntimestamp: 2026-08-26\nauthor: X\nstatus: draft\ntags: [t]\n---\nsee [gone](nope.md)\n' > "$OS/peer/dead.md"
git -C "$OS/peer" add -A && git -C "$OS/peer" "${G[@]}" commit -qm dead
mkdir -p "$OW/docs"; doc "$OW/docs/pump.md"; idx "$OW/docs/_index.md" '# Docs\n\n## Documents\n\n- [t](pump.md)'
kmpy - "$OW/CONVENTIONS.md" <<'PY'
import sys
from km.ownership import SECTION
open(sys.argv[1], "w", encoding="utf-8", newline="\n").write("# Conventions\n\nIntro.\n\n" + SECTION + "\n## Next\n\nAfter.\n")
PY
cp "$OW/CONVENTIONS.md" "$T/conv.fresh"
git -C "$OW" init -q && git -C "$OW" add -A && git -C "$OW" "${G[@]}" commit -qm init
gi(){ out="$(cd "$OW" && km gen-index "$@" 2>&1)"; rc=$?; }
outside(){ kmpy - "$OW/CONVENTIONS.md" "$1" <<'PY'   # the text outside the markers, of the file and of a copy, is the same
import re, sys
cut = lambda t: re.sub(r"(?s)(<!-- km:ownership:begin[^\n]*\n).*(<!-- km:ownership:end)", r"\1\2", t)
a, b = (open(p, encoding="utf-8", newline="").read() for p in sys.argv[1:3])
sys.exit(cut(a) != cut(b))
PY
}
gi --check; { [ "$rc" = 0 ] && has "up to date"; } && ok "ownership: no mount, the template's empty block is up to date" || no "ownership empty block ($rc: $out)"
git -C "$OW" "${G[@]}" submodule add -q "$OS/peer" brains/peer && git -C "$OW" "${G[@]}" submodule add -q "$OS/res" tools/res
git -C "$OW" "${G[@]}" commit -qm mounts
gi --check; { [ "$rc" = 1 ] && has "  - CONVENTIONS.md" && cmp -s "$OW/CONVENTIONS.md" "$T/conv.fresh"; } \
  && ok "ownership: --check fails after a mount is added, writes nothing" || no "ownership --check after add ($rc: $out)"
gi; rows="$(grep '^| `' "$OW/CONVENTIONS.md")"
{ [ "$rc" = 0 ] && has "updated 1: CONVENTIONS.md" && grep -qx '| `brains/peer` | `[^`]*peer` | default | _not stated_ |' <<< "$(sed -n 1p <<< "$rows")" \
  && grep -qx '| `tools/res` | `[^`]*res` | default | _not stated_ |' <<< "$(sed -n 2p <<< "$rows")" && outside "$T/conv.fresh"; } \
  && ok "ownership: gen-index lists each mount, inside brains/ or not, sorted by path, and leaves the text outside the markers byte for byte" \
  || no "ownership gen-index rows ($rc: $out; $rows)"
git -C "$OW" "${G[@]}" commit -qam table; gi --check; [ "$rc" = 0 ] && ok "ownership: --check passes on a fresh table" || no "ownership fresh ($rc: $out)"
git -C "$OS/peer" "${G[@]}" commit -q --allow-empty -m two && git -C "$OW/brains/peer" "${G[@]}" fetch -q origin && git -C "$OW/brains/peer" checkout -q FETCH_HEAD && git -C "$OW" add brains/peer && git -C "$OW" "${G[@]}" commit -qm bump
gi --check; [ "$rc" = 0 ] && ok "ownership: a pin move alone leaves the table fresh" || no "ownership pin move ($rc: $out)"
stale_after(){ gi --check; local c=$rc; gi; [ "$c" = 1 ] && has "updated 1: CONVENTIONS.md"; }
git -C "$OW" config -f .gitmodules submodule.brains/peer.km-owns "Pump timing"
stale_after && grep -qx '| `brains/peer` | .* | default | Pump timing |' "$OW/CONVENTIONS.md" && ok "ownership: a km-owns change makes it stale, gen-index writes Holds" || no "ownership km-owns ($out)"
git -C "$OW" config -f .gitmodules submodule.tools/res.url "https://user:secret@example.com/acme/res.git"
stale_after && grep -qx '| `tools/res` | `https://example.com/acme/res` | default | _not stated_ |' "$OW/CONVENTIONS.md" && ! grep -q secret "$OW/CONVENTIONS.md" \
  && ok "ownership: a url change makes it stale; the user info and .git are dropped" || no "ownership url ($out; $(grep tools/res "$OW/CONVENTIONS.md"))"
git -C "$OW" config -f .gitmodules submodule.tools/res.branch .
stale_after && grep -q "| this brain's branch |" "$OW/CONVENTIONS.md" && ok "ownership: branch . reads as this brain's branch" || no "ownership branch ($out)"
git -C "$OW" "${G[@]}" commit -qam owns; git -C "$OW" mv tools/res tools/res2
stale_after && grep -q '^| `tools/res2` |' "$OW/CONVENTIONS.md" && ! grep -q '^| `tools/res` |' "$OW/CONVENTIONS.md" && ok "ownership: a rename makes it stale" || no "ownership rename ($out)"
git -C "$OW" add -A && git -C "$OW" "${G[@]}" commit -qm rename
git -C "$OW" config -f .gitmodules submodule.ghost.path ghost; git -C "$OW" config -f .gitmodules submodule.ghost.url "$OS/other"
gi --check; { [ "$rc" = 0 ] && ! grep -q ghost "$OW/CONVENTIONS.md"; } && ok "ownership: a .gitmodules entry without a gitlink is no row" || no "ownership gitlink intersection ($rc: $out)"
git -C "$OW" config -f .gitmodules --remove-section submodule.ghost
# every value is one safe cell: a pipe, a backtick, a newline, link brackets and the end marker itself
git -C "$OW" config -f .gitmodules submodule.brains/peer.km-owns "$(printf 'a|b `c`\n[x](https://example.com) <!-- km:ownership:end -->')"
gi; holds="$(grep '^| `brains/peer`' "$OW/CONVENTIONS.md")"
{ [ "$rc" = 0 ] && [ "${holds#*| default | }" = 'a\|b ?c? x (https://example.com) &lt;!-- km:ownership:end --> |' ]; } \
  && ok "ownership: a value is escaped into one cell (pipe, backtick, newline, brackets, a marker)" || no "ownership escaping ($holds)"
gi; { [ "$rc" = 0 ] && has "up to date"; } && ok "ownership: gen-index is idempotent over an escaped value" || no "ownership idempotent ($rc: $out)"
out="$(cd "$OW" && km validate 2>&1)"; ! has "ownership-markers" && ok "ownership: a marker in a value does not break the markers" || no "ownership marker in value ($out)"
git -C "$OW" "${G[@]}" commit -qam escaped
# PRE_COMMIT: the rewrite fails the commit, nothing is staged
git -C "$OW" config -f .gitmodules submodule.brains/peer.km-owns "Pump timing"
out="$(cd "$OW" && PRE_COMMIT=1 km gen-index 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && has "updated 1: CONVENTIONS.md; stage them and commit again" && [ -n "$(git -C "$OW" diff --name-only -- CONVENTIONS.md)" ] \
  && [ -z "$(git -C "$OW" diff --cached --name-only)" ]; } && ok "ownership: under pre-commit a rewrite fails the commit and stages nothing" || no "ownership PRE_COMMIT ($rc: $out)"
git -C "$OW" "${G[@]}" commit -qam fill
# broken markers: nothing written (no _index.md either), exit 1 with a fix line
doc "$OW/docs/new.md"; git -C "$OW" add -A
cp "$OW/CONVENTIONS.md" "$T/conv.ok"; printf '<!-- km:ownership:end -->\n' >> "$OW/CONVENTIONS.md"; cp "$OW/CONVENTIONS.md" "$T/conv.bad"
gi; { [ "$rc" = 1 ] && has "fix the marker lines by hand" && cmp -s "$OW/CONVENTIONS.md" "$T/conv.bad" && ! grep -q new.md "$OW/docs/_index.md"; } \
  && ok "ownership: broken markers: gen-index writes nothing and exits 1 with a fix line" || no "ownership broken markers ($rc: $out)"
cp "$T/conv.ok" "$OW/CONVENTIONS.md"
# no markers: the file is left alone
sed -i.bak '/km:ownership:/d' "$OW/CONVENTIONS.md" && rm -f "$OW/CONVENTIONS.md.bak"; cp "$OW/CONVENTIONS.md" "$T/conv.none"
gi; { [ "$rc" = 0 ] && cmp -s "$OW/CONVENTIONS.md" "$T/conv.none"; } && ok "ownership: without markers CONVENTIONS.md is left alone" || no "ownership no markers ($rc: $out)"
# a symlinked CONVENTIONS.md is neither read nor written through, wherever it points
mv "$OW/CONVENTIONS.md" "$OS/conv.outside"; printf '<!-- km:ownership:begin -->\nstale\n<!-- km:ownership:end -->\n' >> "$OS/conv.outside"
cp "$OS/conv.outside" "$T/conv.outside"
if ln -s "$OS/conv.outside" "$OW/CONVENTIONS.md" 2>/dev/null && [ -L "$OW/CONVENTIONS.md" ]; then
  gi; { [ "$rc" = 0 ] && has "CONVENTIONS.md is a symbolic link" && cmp -s "$OS/conv.outside" "$T/conv.outside"; } \
    && ok "ownership: gen-index writes nothing through a symlinked CONVENTIONS.md, with a note" || no "ownership symlink ($rc: $out)"
else echo "  skip: no symbolic links here"; fi
rm -f "$OW/CONVENTIONS.md"
cp "$T/conv.ok" "$OW/CONVENTIONS.md"; git -C "$OW" config -f .gitmodules submodule.tools/res.km-owns "Shared resources"; gi; git -C "$OW" add -A && git -C "$OW" "${G[@]}" commit -qm docs
# git and bump-mounted-pins ignore km-owns
out="$(git -C "$OW" "${G[@]}" submodule update --init 2>&1 && git -C "$OW" submodule status 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && ! has "km-owns" && ! has warning; } && ok "ownership: git takes a .gitmodules with km-owns without a word" || no "ownership git and km-owns ($rc: $out)"
out="$(cd "$OW" && kmpy - "$REPO/src/km/templates/team/bump-mounted-pins.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bmp", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
subs = m.submodules()
print(subs)
sys.exit(not subs or any(set(s) != {"name", "path", "url", "branch", "slug"} for s in subs))
PY
)"; [ $? = 0 ] && ok "ownership: bump-mounted-pins reads path, url and branch only" || no "ownership bump-mounted-pins ($out)"
# --- what .gitmodules or CONVENTIONS.md may hold: undecodable bytes, fenced examples, CRLF, odd urls,
# two names for one path, format characters, long values, a symlink ---
save(){ cp "$OW/CONVENTIONS.md" "$T/c.save"; cp "$OW/.gitmodules" "$T/g.save"; }
restore(){ rm -f "$OW/CONVENTIONS.md" "$OW/.gitmodules"; cp "$T/c.save" "$OW/CONVENTIONS.md"; cp "$T/g.save" "$OW/.gitmodules"; }
pyhas(){ kmpy - "$OW/CONVENTIONS.md" "$1" <<'PY'   # pyhas PYTHON-EXPR: true when the expression of t (CONVENTIONS.md as bytes decoded) holds
import sys
b = open(sys.argv[1], "rb").read(); t = b.decode("utf-8")
sys.exit(not eval(sys.argv[2]))
PY
}
save
printf '\tkm-owns = Pr\xfcfst\xe4nde\n' >> "$OW/.gitmodules"   # in the last section, tools/res: the last value wins
gi; { [ "$rc" = 0 ] && pyhas '"| Pr�fst�nde |" in t and t.startswith("# Conventions")'; } \
  && ok "ownership: a byte .gitmodules does not decode becomes U+FFFD, the file stays whole" || no "ownership undecodable byte ($rc: $out)"
gi; { [ "$rc" = 0 ] && has "up to date"; } && ok "ownership: and the next run finds it up to date" || no "ownership undecodable rerun ($rc: $out)"
restore; printf '\tkm-owns = Pr\xfcfst\xe4nde\n' >> "$OW/.gitmodules"
out="$(cd "$OW" && PRE_COMMIT=1 km gen-index 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && pyhas '"Pr�fst" in t and "## Next" in t'; } && ok "ownership: under pre-commit too: the commit fails, the file is whole" || no "ownership undecodable PRE_COMMIT ($rc: $out)"
restore
# a fenced example of the markers is no marker: the real block is filled, the example and _index.md lists stay right
conv 't + "\n## Example\n\n```markdown\n<!-- km:ownership:begin -->\nexample text\n<!-- km:ownership:end -->\n```\n"'; cp "$OW/CONVENTIONS.md" "$T/c.fenced"
git -C "$OW" config -f .gitmodules submodule.brains/peer.km-owns "Pump timing and flow"; doc "$OW/docs/fence.md"; git -C "$OW" add docs/fence.md
gi; { [ "$rc" = 0 ] && grep -q "fence.md" "$OW/docs/_index.md" && pyhas '"Pump timing and flow |" in t and "\n<!-- km:ownership:begin -->\nexample text\n<!-- km:ownership:end -->\n```\n" in t'; } \
  && ok "ownership: markers in a fenced example are no markers: the real block is filled, the example kept, _index.md updated" || no "ownership fenced example ($rc: $out)"
git -C "$OW" rm -q -f docs/fence.md; gi >/dev/null
printf '# C\n\n```\n<!-- km:ownership:begin -->\nhand text\n<!-- km:ownership:end -->\n```\n' > "$OW/CONVENTIONS.md"; cp "$OW/CONVENTIONS.md" "$T/c.only"
gi; { [ "$rc" = 0 ] && cmp -s "$OW/CONVENTIONS.md" "$T/c.only"; } && ok "ownership: a file whose only markers are in a fence is left alone" || no "ownership fence only ($rc: $out)"
printf '# C\n\n<!-- km:ownership:begin: generated\nby km gen-index -->\n\nhand text\n\n<!-- km:ownership:end -->\n' > "$OW/CONVENTIONS.md"; cp "$OW/CONVENTIONS.md" "$T/c.wrap"
gi; { [ "$rc" = 1 ] && has "does not close its comment on that line" && cmp -s "$OW/CONVENTIONS.md" "$T/c.wrap"; } \
  && ok "ownership: a begin comment wrapped onto two lines is a broken marker: nothing written, exit 1" || no "ownership wrapped begin ($rc: $out)"
restore
# CRLF: read as LF, compared as LF, written back with CRLF throughout
conv 't.replace("\n", "\r\n")'
gi --check; [ "$rc" = 0 ] && ok "ownership: a CRLF CONVENTIONS.md with a fresh table is up to date" || no "ownership CRLF fresh ($rc: $out)"
git -C "$OW" config -f .gitmodules submodule.brains/peer.km-owns "Pump timing and flow"
gi; { [ "$rc" = 0 ] && pyhas 'b.count(b"\n") == b.count(b"\r\n") and b"Pump timing and flow |\r\n" in b'; } \
  && ok "ownership: gen-index keeps CRLF throughout a CRLF file" || no "ownership CRLF write ($rc: $out)"
restore
# urls: scp-style user, query and fragment dropped, IPv6 brackets kept
url_row(){ git -C "$OW" config -f .gitmodules submodule.brains/peer.url "$1"; gi; grep -q "^| \`brains/peer\` | \`$2\` |" "$OW/CONVENTIONS.md"; }
url_row "git@example.com:acme/peer.git" "example.com:acme/peer" && ok "ownership: an scp-style url loses its user" || no "ownership scp url ($(grep brains/peer "$OW/CONVENTIONS.md"))"
url_row "https://example.com/acme/peer.git?token=s3cret#frag" "https://example.com/acme/peer" && ! grep -q s3cret "$OW/CONVENTIONS.md" \
  && ok "ownership: a url loses its query and fragment" || no "ownership url query ($(grep brains/peer "$OW/CONVENTIONS.md"))"
url_row "https://u:p@[::1]/acme/peer" 'https://\[::1\]/acme/peer' && ok "ownership: IPv6 brackets stay" || no "ownership IPv6 ($(grep brains/peer "$OW/CONVENTIONS.md"))"
restore
git -C "$OW" config -f .gitmodules submodule.zz-dup.path brains/peer; git -C "$OW" config -f .gitmodules submodule.zz-dup.url "$OS/other"
gi; [ "$(grep -c '^| `brains/peer`' "$OW/CONVENTIONS.md")" = 1 ] && ok "ownership: two names for one path give one row" || no "ownership duplicate path ($(grep brains/peer "$OW/CONVENTIONS.md"))"
restore
kmpy -c 'import subprocess, sys; subprocess.run(["git", "-C", sys.argv[1], "config", "-f", ".gitmodules", "submodule.brains/peer.km-owns", "A​B‮C" + "x" * 300], check=True)' "$OW"
gi; { [ "$rc" = 0 ] && pyhas 'any(l.startswith("| `brains/peer`") and l.split(" | ")[3] == "ABC" + "x" * 196 + "… |" for l in t.splitlines())'; } \
  && ok "ownership: format characters are dropped and a cell is cut at 200 characters" || no "ownership Cf and length ($(grep brains/peer "$OW/CONVENTIONS.md" | cut -c1-120))"
restore
mv "$OW/.gitmodules" "$OS/gitmodules.outside"
if ln -s "$OS/gitmodules.outside" "$OW/.gitmodules" 2>/dev/null && [ -L "$OW/.gitmodules" ]; then
  git -C "$OW" config -f "$OS/gitmodules.outside" submodule.brains/peer.km-owns "Read through a link"; cp "$OW/CONVENTIONS.md" "$T/c.link"
  gi; { [ "$rc" = 0 ] && has ".gitmodules is a symbolic link" && cmp -s "$OW/CONVENTIONS.md" "$T/c.link"; } \
    && ok "ownership: a symlinked .gitmodules is not read, with a note" || no "ownership .gitmodules symlink ($rc: $out)"
else echo "  skip: no symbolic links here"; fi
restore
gi; git -C "$OW" add -A && git -C "$OW" "${G[@]}" commit -q --allow-empty -m restored; gi --check
[ "$rc" = 0 ] && ok "ownership: back to the committed state, fresh" || no "ownership restored ($rc: $out)"
# validate: the five warnings, each on its condition only; a dead row link is dead-link; exit 0
vout(){ out="$(cd "$OW" && km validate 2>&1)"; rc=$?; }
vout; { [ "$rc" = 0 ] && ! has "ownership-" && ! has "nope.md"; } \
  && ok "ownership: a fresh table with every mount stated warns nothing; a mount's own dead links are not the brain's" || no "ownership validate clean ($rc: $out)"
kmpy - "$OW/CONVENTIONS.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
rows = ("| Pump ratings | [docs/pump.md](docs/pump.md) | datasheet |\n| Peer timing | [peer](brains/peer/) | |\n"
        "| Resources | [res](tools/res2/) | |\n| Coil | https://example.com/coil | |\n\n<!-- an example:\n| Topic | Home |\n|---|---|\n| Example | no home here |\n-->\n")
open(p, "w", encoding="utf-8", newline="\n").write(t.replace("|-------|------|-------|\n", "|-------|------|-------|\n" + rows, 1))
PY
git -C "$OW" "${G[@]}" commit -qam rows
vout; { [ "$rc" = 0 ] && ! has "ownership-" && ! has "dead-link"; } && ok "ownership: hand rows with links and URLs, one to a mount root, and a row in a comment warn nothing" || no "ownership hand rows ($rc: $out)"
git -C "$OW" submodule deinit -q -f tools/res2
vout; ! has "dead-link" && ok "ownership: a link to a mount root not checked out is no dead link" || no "ownership unchecked mount ($out)"
kmpy - "$OW/CONVENTIONS.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8", newline="\n").write(t.replace("| Coil | https://example.com/coil | |\n",
    "| Coil | ask the bench team | |\n| pump  RATINGS | [x](docs/gone.md) | |\n", 1))
PY
git -C "$OW" config -f .gitmodules --unset submodule.brains/peer.km-owns; git -C "$OW" add -A
vout; { [ "$rc" = 0 ] && has "ownership-home" && has "'Coil' names no home" && has "ownership-duplicate" && has "'pump  RATINGS' has more than one row" \
  && has "ownership-stale" && has "ownership-topic" && has "the mount brains/peer does not say what it holds" && has "links missing docs/gone.md" && ! has "ownership-markers"; } \
  && ok "ownership: home, duplicate, stale and topic warn on their condition, a dead row link is dead-link, exit 0" || no "ownership warnings ($rc: $out)"
printf '<!-- km:ownership:begin -->\n' >> "$OW/CONVENTIONS.md"
vout; { [ "$rc" = 0 ] && has "ownership-markers" && ! has "ownership-stale"; } && ok "ownership: a second begin line is ownership-markers, not stale too" || no "ownership markers ($rc: $out)"
out="$(cd "$OW" && km validate CONVENTIONS.md docs/pump.md 2>&1)"; ! has "ownership-" && ok "ownership: per-file runs skip the table" || no "ownership per-file ($out)"
# --- km upgrade past 1.26.0 appends the section: over undecodable bytes, in a CRLF file, past a fenced heading,
# beside a mounts table of the brain's own ---
U="$(mktemp -d)"; fake_km_remote "$U/remote"; export KM_REPO_URL="file://$U/remote"
git -C "$U/remote" "${G[@]}" commit -q --allow-empty -m three && git -C "$U/remote" tag v1.99.0
git -C "$U/remote" tag v1.11.0 "$(git -C "$U/remote" "${G[@]}" commit-tree -p v0.9.0 -m 1.11 'v0.9.0^{tree}')"
old_brain(){ # old_brain DIR: a personal brain pinned to km 1.11.0, its CONVENTIONS.md without the section
  km init "$1" --initials UU --pin v1.11.0 >/dev/null && kmpy - "$1/CONVENTIONS.md" <<'PY'
import sys, km.ownership as o
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8", newline="\n").write(t.replace(o.SECTION + "\n", "", 1))
PY
  git -C "$1" init -q && git -C "$1" add -A && git -C "$1" "${G[@]}" commit -qm init; }
upg(){ out="$(km upgrade --root "$1" --pin v1.99.0 2>&1)"; rc=$?; }
upyhas(){ kmpy - "$1/CONVENTIONS.md" "$2" <<'PY'
import sys
b = open(sys.argv[1], "rb").read(); t = b.decode("utf-8")
sys.exit(not eval(sys.argv[2]))
PY
}
old_brain "$U/b1"; git -C "$U/b1" "${G[@]}" submodule add -q "$OS/peer" brains/peer && printf '\tkm-owns = Pr\xfcfst\xe4nde\n' >> "$U/b1/.gitmodules"
git -C "$U/b1" add -A && git -C "$U/b1" "${G[@]}" commit -qm mount
upg "$U/b1"; { [ "$rc" = 0 ] && upyhas "$U/b1" 't.startswith("# CONVENTIONS.md") and "\n## Ownership\n" in t and "| Pr�fst�nde |" in t and t.endswith("<!-- km:ownership:end -->\n")'; } \
  && ok "ownership upgrade: a byte .gitmodules does not decode: the section is added whole, with U+FFFD" || no "ownership upgrade undecodable ($rc: $out)"
old_brain "$U/b2"; kmpy -c 'import sys; p = sys.argv[1]; t = open(p, "rb").read(); open(p, "wb").write(t.replace(b"\n", b"\r\n"))' "$U/b2/CONVENTIONS.md"
out="$(kmpy -c 'import sys, pathlib, km.upgrade as u; print(u.add_ownership(pathlib.Path(sys.argv[1])))' "$U/b2" 2>&1)"
upyhas "$U/b2" 'b.count(b"\n") == b.count(b"\r\n") and b"\r\n## Ownership\r\n" in b' \
  && ok "ownership upgrade: a CRLF CONVENTIONS.md gets the section in CRLF" || no "ownership upgrade CRLF ($out)"
upg "$U/b2"; { [ "$rc" = 0 ] && upyhas "$U/b2" 'b.count(b"\r\n") in (0, b.count(b"\n")) and t.count("## Ownership") == 1'; } \
  && ok "ownership upgrade: the whole upgrade of it leaves one line ending and one section" || no "ownership upgrade CRLF whole ($rc: $out)"
old_brain "$U/b3"; printf '\n```markdown\n## Ownership\n```\n\n## Mounted repositories\n\n| Name | Repo |\n|---|---|\n| peer | example |\n' >> "$U/b3/CONVENTIONS.md"
git -C "$U/b3" add -A && git -C "$U/b3" "${G[@]}" commit -qm own
upg "$U/b3"; { [ "$rc" = 0 ] && out_has "added the '## Ownership' section" && out_has "already has a 'Mounted repositories' heading of its own" \
  && upyhas "$U/b3" 't.count("<!-- km:ownership:begin") == 1 and "| peer | example |" in t'; } \
  && ok "ownership upgrade: an '## Ownership' heading in a fence is none; a mounts heading of the brain's own gets a note" || no "ownership upgrade fence and mounts ($rc: $out)"

summary ownership-smoke || exit 1
