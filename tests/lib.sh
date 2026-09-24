# Sourced by the smoke tests: `km` from this checkout, and pass/fail bookkeeping.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
km(){ PYTHONPATH="$REPO/src${PYTHONPATH:+:$PYTHONPATH}" python3 -m km "$@"; }
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
