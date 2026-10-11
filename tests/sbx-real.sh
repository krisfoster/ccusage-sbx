# Sourced by the tests. Makes 'sbx' mean the real sbx binary, never a wrapper script that happens to sit
# earlier on PATH (for example ~/.local/bin/sbx that adds a default --kit to every create, which would make
# these tests pass the kit twice). On a machine with no wrapper, this just finds the one sbx there is.
# SBX_REAL=<path> overrides the search.
_real=""
if [ -n "${SBX_REAL:-}" ]; then
  _real="$SBX_REAL"
else
  for _c in $(type -ap sbx 2>/dev/null); do
    if [ "$(head -c 2 "$_c" 2>/dev/null)" = '#!' ]; then
      echo "note: skipping $_c, a script that wraps sbx; the tests use the real binary" >&2
      continue
    fi
    _real="$_c"; break
  done
fi
[ -x "$_real" ] || { echo "no real sbx binary found on PATH (set SBX_REAL to its path)" >&2; exit 2; }
SBX_REAL="$_real"
sbx() { "$SBX_REAL" "$@"; }
