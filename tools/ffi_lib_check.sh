#!/usr/bin/env bash
# ffi_lib_check.sh — THE PREBUILT-LIBRARY GATE (BUG-266).
#
# Asserts that `use foo` resolving to a prebuilt `foo.lib` actually LINKS and that the
# foreign call returns the right value. This is the last link in the FFI chain: BUG-261
# made a `.c` SOURCE dep work, and this covers the case a real third-party dependency
# actually takes — a binary you did not build, that you cannot compile from source.
#
# WHY THIS IS A SCRIPT AND NOT A test/*.zbr FIXTURE. The dependency is a BINARY. The repo
# gitignores binaries deliberately, and committing a .lib would also pin one toolchain's
# object format into the corpus. So the library is BUILT HERE, from source, at check time
# — which additionally means the thing under test is a library this script did not exist
# before creating, rather than a stale artifact that might be passing for the wrong reason.
#
# WHAT WOULD MAKE THIS LIE, and what is done about it:
#   * A pass that has nothing to do with linking. `zebra_lib_answer` returns a value that
#     appears NOWHERE in the Zebra source, so the program cannot print it without actually
#     calling into the library. Printing a literal from the .zbr would prove nothing.
#   * A gate that cannot fail. Leg 2 removes the .lib and REQUIRES the run to stop
#     producing that value. If both legs pass, the linkage is what is doing the work.
#   * Exit codes. BUG-259 means `zebra.exe` can return 0 after a failed compile, so every
#     classification here is on PRINTED OUTPUT, never on $?.
#   * A vacuous run. If the library cannot be built at all, this REFUSES to report a pass
#     — a checker that has stopped checking must not look like a checker that found
#     nothing.
#
# pins: BUG-266 this IS the regression test — the subject is a library built here, so
# pins: BUG-266 there is no test/*.zbr for bug_fixture_check's file scan to find.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"
WORK="${TMPDIR:-/tmp}/zbr-ffi-lib-$$"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$ZEBRA" ] || fail "zebra.exe not built"

# The expected value is chosen so it cannot appear by accident, and it is NOT written
# anywhere in the .zbr — only in the C-ABI library and in this script's assertion.
EXPECT=1337

cat > "$WORK/zzlib.zig" <<EOF
export fn zebra_lib_answer() i32 { return $EXPECT; }
EOF

# A STATIC archive on purpose: a dynamic build would additionally require the .dll to sit
# beside the emitted executable at RUN time, and the emit lands in a temp dir of the
# compiler's choosing. That is a packaging question, not a linking one, and mixing it in
# would make a failure here ambiguous.
( cd "$WORK" && zig build-lib zzlib.zig >/dev/null 2>build.err ) \
    || fail "could not build the test library (this check cannot run): $(head -3 "$WORK/build.err")"

LIB=""
for cand in "$WORK/zzlib.lib" "$WORK/libzzlib.a" "$WORK/zzlib.a"; do
    [ -f "$cand" ] && LIB="$cand" && break
done
[ -n "$LIB" ] || fail "library built but no .lib/.a produced — cannot run this check"
LIBEXT="${LIB##*.}"

cat > "$WORK/zzprog.zbr" <<'EOF'
use zzlib

extern def zebra_lib_answer(): int32

def main()
    print(zebra_lib_answer())
EOF

# ── Leg 1: it links, and the foreign call returns the library's value ─────────
# `grep -qx` on a \r-stripped stream, NOT a bare substring match. The compiler echoes
# the output path, and $WORK contains the PID -- so a PID of e.g. 11337 would put the
# expected value inside a "wrote ...\zbr-ffi-lib-11337\..." line and pass leg 1 without
# anything having been linked. Matching a whole line closes that: the program prints the
# number alone. (Found by re-reading this script rather than by it failing, which is the
# only way this class ever gets found.)
got="$("$ZEBRA" "$WORK/zzprog.zbr" 2>&1 | tr -d '\r')"
if ! printf '%s\n' "$got" | grep -qx "$EXPECT"; then
    echo "FAIL: leg 1 — expected $EXPECT from the linked library" >&2
    printf '%s\n' "$got" | grep -v '^compiling:\|^ *parsing\|^ *parsed\|^ *resolved\|^wrote ' | tail -6 >&2
    exit 1
fi

# ── Leg 1b: the emit must not @import a library that has no .zig ──────────────
mkdir -p "$WORK/out"
"$ZEBRA" --emit-zig "$WORK/zzprog.zbr" --output-dir "$WORK/out" >/dev/null 2>&1
if grep -q '@import("zzlib.zig")' "$WORK/out/zzprog.zig" 2>/dev/null; then
    fail "leg 1b — emitted @import(\"zzlib.zig\") for a prebuilt library"
fi

# ── Leg 2: NEGATIVE CONTROL — without the library, that value must not appear ──
# Proves leg 1 is measuring the link rather than something incidental.
mv "$LIB" "$WORK/hidden.$LIBEXT"
got2="$("$ZEBRA" "$WORK/zzprog.zbr" 2>&1 | tr -d '\r')"
mv "$WORK/hidden.$LIBEXT" "$LIB"
if printf '%s\n' "$got2" | grep -qx "$EXPECT"; then
    fail "leg 2 — printed $EXPECT with the library REMOVED; leg 1 proves nothing"
fi

echo "ffi-lib: 3/3 checks pass (link=$EXPECT, no stray @import, negative control red)"
