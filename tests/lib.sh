# Sourced by the smoke tests: `km` from this checkout, and pass/fail bookkeeping.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Any read, write or subprocess call in km that relies on the system's default encoding fails the
# tests: on Windows that default is cp1252, not UTF-8.
km(){ PYTHONWARNDEFAULTENCODING=1 PYTHONWARNINGS=error::EncodingWarning \
      PYTHONPATH="$REPO/src${PYTHONPATH:+:$PYTHONPATH}" python3 -m km "$@"; }
pass=0; fail=0
ok(){ echo "  ok:   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
summary(){ echo "$1: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; }
kmpy(){ PYTHONPATH="$REPO/src${PYTHONPATH:+:$PYTHONPATH}" python3 "$@"; }
# A stand-in for the km repository with release tags, for `km init`/`km upgrade`, which pin a
# release by its commit: v0.9.0 (lightweight) and this km's version (annotated, as releases may be).
fake_km_remote(){
  local d="$1" g=(-c user.name=t -c user.email=t@t)
  git init -q "$d" && git -C "$d" "${g[@]}" commit -q --allow-empty -m one && git -C "$d" tag v0.9.0
  git -C "$d" "${g[@]}" commit -q --allow-empty -m two && git -C "$d" "${g[@]}" tag -a -m release "v$(km --version)"
}
# repin OLD_SHA OLD_VERSION NEW_SHA NEW_VERSION FILE...: rewrite a km pin in both formats (see km.pins)
repin(){ local f; for f in "${@:5}"; do sed -i.bak "s|$1 # $2|$3 # $4|; s|$1  # frozen: $2|$3  # frozen: $4|" "$f" && rm -f "$f.bak"; done; }
# The environments that behave like Windows: file names in UTF-8, everything else in a code page
# (cp1252 there): ASCII (C locale, coercion off) and, where the locale exists, Latin-1. Only macOS
# has them; on Linux such a locale makes file names non-UTF-8 as well, which Windows never does.
non_utf8_envs(){
  local e
  for e in "LC_ALL=C PYTHONCOERCECLOCALE=0" "LC_ALL=en_US.ISO8859-1"; do
    case "$(with_env "$e" python3 -c 'import locale, sys; print(sys.getfilesystemencoding(), locale.getpreferredencoding(False))' 2>/dev/null)" in
      "utf-8 "*[Uu][Tt][Ff]*) ;; "utf-8 "*) echo "$e";; esac
  done
}
# with_env "K=V K=V" CMD...: run CMD (a shell function too) with those exported and UTF-8 mode off
with_env(){ ( export $1 PYTHONUTF8=0; "${@:2}" ) }
