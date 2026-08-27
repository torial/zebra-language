#!/usr/bin/env bash
# FALSIFY rebuild.sh's stale-bootstrap guard. ~1 s, no build, NOT a gate.
#
# WHY THIS EXISTS. `rebuild.sh` pre-builds the bootstrap when one of its INPUTS is newer
# than the binary, because the regen runs that binary: regenerate against a stale bootstrap
# and you emit the previous compiler's output, then measure it with every gate downstream.
#
# The list was `stdlib_preamble.zig napi_preamble.zig` only. Those are EMBEDDED at build
# time; everything in `src/` is COMPILED INTO the binary, which is the same staleness and
# was not covered. Observed 2026-08-26: `File.tryDelete` was added to src/TypeChecker.zig
# and used from selfhost/main.zbr; the regen ran a bootstrap 35 minutes older and failed
# with `expected 'bool', got 'void'` -- a type error naming THE VERY FEATURE BEING ADDED.
# That reads as "your new code is wrong" rather than "your compiler is stale", which is the
# reassuring-but-wrong direction this repo keeps meeting.
#
# AND THE REAL RUN COULD NOT HAVE PROVEN THE FIX. The loop breaks on its FIRST match, and
# after the fix the preamble happened to be newest -- so the run fired citing the preamble
# and the src/ arm was never exercised. "The rebuild worked" was not evidence. Hence
# controlled timestamps in a scratch tree, where each arm can be isolated.
#
# THE CONDITION BELOW IS COPIED FROM rebuild.sh AND MUST STAY IN SYNC. That duplication is
# the weakness of this check: it can pass against logic the tool does not have. Leg 0
# compares the two textually so the copy cannot drift silently.
set -u
cd "$(dirname "$0")/.."
REBUILD=tools/rebuild.sh
LIST='selfhost/stdlib_preamble.zig selfhost/napi_preamble.zig src/*.zig build.zig'
fail=0

# ── leg 0: the copy still matches the shipped tool ───────────────────────────────────────
if ! grep -qF "for f in $LIST; do" "$REBUILD"; then
    echo "REFUSING: the guard list in $REBUILD no longer matches this check's copy."
    echo "  expected: for f in $LIST; do"
    grep -nE '^\s*for f in .*do$' "$REBUILD" | sed 's/^/  found:    /'
    exit 2
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/selfhost" "$WORK/src" "$WORK/zig-out/bin"
cd "$WORK"
touch selfhost/stdlib_preamble.zig selfhost/napi_preamble.zig src/CodeGen.zig \
      src/TypeChecker.zig build.zig selfhost/CodeGen.zbr

fires() {
    BOOT=zig-out/bin/zebra-bootstrap.exe
    for f in selfhost/stdlib_preamble.zig selfhost/napi_preamble.zig src/*.zig build.zig; do
        if [[ -f "$f" && ( ! -f "$BOOT" || "$f" -nt "$BOOT" ) ]]; then echo "$f"; return 0; fi
    done
    return 1
}
chk() {
    local got; got="$(fires || true)"
    if [[ "$2" == "$got" ]]; then echo "  ok    $1 -> ${got:-<no fire>}"
    else echo "  FAIL  $1 -> expected '${2:-<no fire>}', got '${got:-<no fire>}'"; fail=1; fi
}
fresh() { touch zig-out/bin/zebra-bootstrap.exe; sleep 1; }

echo "rebuild guard check (controlled timestamps, no build):"

# CONTROL FIRST. Without it, a guard that fires unconditionally passes every other leg.
fresh
chk "nothing newer than the binary"        ""

# THE ARM THAT WAS MISSING -- the 2026-08-26 case.
touch src/TypeChecker.zig
chk "src/ newer"                           "src/TypeChecker.zig"

# The arm that already worked must keep working.
fresh; touch selfhost/stdlib_preamble.zig
chk "preamble newer"                       "selfhost/stdlib_preamble.zig"

# build.zig decides what gets embedded at all.
fresh; touch build.zig
chk "build.zig newer"                      "build.zig"

# THE PROPERTY WIDENING COULD HAVE BROKEN. rebuild.sh promises a .zbr-only edit -- the
# common case -- pays nothing, and a needless full build here would be paid on every
# inner-loop iteration.
fresh; touch selfhost/CodeGen.zbr
chk ".zbr-only edit pays nothing"          ""

# No binary: nothing to be stale against, so build first.
rm -f zig-out/bin/zebra-bootstrap.exe
chk "no bootstrap binary at all"           "selfhost/stdlib_preamble.zig"

echo
if [[ $fail -eq 0 ]]; then echo "rebuild-guard: 6/6 ok"; else echo "rebuild-guard: FAILURES" >&2; fi
exit $fail
