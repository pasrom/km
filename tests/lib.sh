# Sourced by the smoke tests: `km` from this checkout, and pass/fail bookkeeping.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && { pwd -W 2>/dev/null || pwd; })"   # -W: a path Python on Windows reads
SEP=":"; pwd -W >/dev/null 2>&1 && SEP=";"                                            # PYTHONPATH's separator
PY="${PYTHON:-python3}"
# Any read, write or subprocess call in km that relies on the system's default encoding fails the
# tests: on Windows that default is cp1252, not UTF-8.
km(){ PYTHONWARNDEFAULTENCODING=1 PYTHONWARNINGS=error::EncodingWarning \
      PYTHONPATH="$REPO/src${PYTHONPATH:+$SEP$PYTHONPATH}" "$PY" -m km "$@"; }
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
summary(){ echo "$1: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; }
kmpy(){ PYTHONPATH="$REPO/src${PYTHONPATH:+$SEP$PYTHONPATH}" "$PY" "$@"; }
out_has(){ LC_ALL=C grep -aq "$1" <<< "$out"; }   # $out may be in a non-UTF-8 encoding: match bytes
# A stand-in for the km repository with release tags, for `km init`/`km upgrade`, which pin a
# release by its commit: v0.9.0 (lightweight) and this km's version (annotated, as releases may be).
fake_km_remote(){
  local d="$1" g=(-c user.name=t -c user.email=t@t)
  git init -q "$d" && git -C "$d" "${g[@]}" commit -q --allow-empty -m one && git -C "$d" tag v0.9.0
  git -C "$d" "${g[@]}" commit -q --allow-empty -m two && git -C "$d" "${g[@]}" tag -a -m release "v$(km --version)"
}
# repin OLD_SHA OLD_VERSION NEW_SHA NEW_VERSION FILE...: rewrite a km pin in both formats (see km.pins)
repin(){ local f; for f in "${@:5}"; do sed -i.bak "s|$1 # $2|$3 # $4|; s|$1  # frozen: $2|$3  # frozen: $4|" "$f" && rm -f "$f.bak"; done; }
# windows_like "K=V ...": whether that environment behaves like Windows: file names in UTF-8,
# everything else in a code page (cp1252 there). macOS has such locales; on Linux a non-UTF-8 locale
# makes file names non-UTF-8 as well, which Windows never does.
windows_like(){ with_env "$1" "$PY" -c 'import locale, sys
sys.exit(sys.getfilesystemencoding() != "utf-8" or "utf" in locale.getpreferredencoding(False).lower())' 2>/dev/null; }
# with_env "K=V K=V" CMD...: run CMD (a shell function too) with those exported and UTF-8 mode off
with_env(){ ( export $1 PYTHONUTF8=0; "${@:2}" ) }
