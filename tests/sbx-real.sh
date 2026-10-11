# Sourced by the tests. Makes 'sbx' mean the real sbx binary, skipping any wrapper script earlier on PATH
# (for example one that adds a default --kit to every create, which would make these tests pass --kit twice).
# SBX_REAL=<path> overrides the search.
_real=""
if [ -n "${SBX_REAL:-}" ]; then
  _real="$SBX_REAL"
else
  for _c in $(type -ap sbx 2>/dev/null); do
    [ "$(head -c 2 "$_c" 2>/dev/null)" = '#!' ] && continue
    _real="$_c"; break
  done
fi
[ -n "$_real" ] || { echo "no real sbx binary found on PATH (set SBX_REAL)" >&2; exit 2; }
SBX_REAL="$_real"
sbx() { "$SBX_REAL" "$@"; }
