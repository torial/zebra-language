#!/usr/bin/env bash
# bootstrap_check.sh — verify selfhost round-trip and level-2 fixed point.
#
# What it does:
#   1. Regenerates all 9 selfhost .zig files from the Zig-compiled zebra.
#   2. Builds zebra-selfhost-A.exe from those.
#   3. Has A re-emit the 9 .zig files; builds zebra-selfhost-B.exe.
#   4. Has B re-emit the 9 .zig files; diffs against A's output.
#   5. Passes only if B compiles cleanly AND A==B byte-for-byte.
#
# Prerequisites: zig build has already produced zig-out/bin/zebra.exe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

ZEBRA="$REPO/zig-out/bin/zebra.exe"
SELFHOST_A="$REPO/zig-out/bin/zebra-selfhost.exe"
SELFHOST_B="$REPO/zig-out/bin/zebra-selfhost-B.exe"

FILES=(Token Lexer ast parser resolver astbuilder cg_helpers codegen main)

if [[ ! -x "$ZEBRA" ]]; then
    echo "bootstrap_check: $ZEBRA missing. Run 'zbuild' first." >&2
    exit 1
fi

echo "── Step 1: regenerate selfhost/*.zig from zebra (Zig-compiled compiler)"
for f in "${FILES[@]}"; do
    "$ZEBRA" --emit-zig "selfhost/$f.zbr" > "selfhost/$f.zig" 2>/dev/null
done

echo "── Step 2: build selfhost-A"
rm -f "$SELFHOST_A"
if ! zig build-exe selfhost/main.zig -femit-bin="$SELFHOST_A" 2>/tmp/bs-rebuildA.err; then
    echo "FAIL: selfhost-A build errors:" >&2
    head -30 /tmp/bs-rebuildA.err >&2
    exit 1
fi

echo "── Step 3: selfhost-A re-emits its own source"
mkdir -p /tmp/bs-A /tmp/bs-B
for f in "${FILES[@]}"; do
    "$SELFHOST_A" --emit-zig "selfhost/$f.zbr" >/dev/null 2>/dev/null
    # Stash the root emit immediately — subsequent iterations recompile $f as a
    # dep of some other file, overwriting selfhost/$f.zig with a dep-shaped
    # version (no entry thunk, no _zbr_error_msg helper).
    cp "selfhost/$f.zig" "/tmp/bs-A/$f.zig"
done

echo "── Step 4: build selfhost-B (level-2 bootstrap)"
rm -f "$SELFHOST_B"
if ! zig build-exe selfhost/main.zig -femit-bin="$SELFHOST_B" 2>/tmp/bs-rebuildB.err; then
    echo "FAIL: selfhost-B build errors:" >&2
    grep -E "^selfhost[\\\\/].+:[0-9]+:[0-9]+: error:" /tmp/bs-rebuildB.err >&2 || head -30 /tmp/bs-rebuildB.err >&2
    exit 1
fi

echo "── Step 5: selfhost-B re-emits + diff against selfhost-A output"
for f in "${FILES[@]}"; do
    "$SELFHOST_B" --emit-zig "selfhost/$f.zbr" >/dev/null 2>/dev/null
    cp "selfhost/$f.zig" "/tmp/bs-B/$f.zig"
done

DIVERGENT=0
for f in "${FILES[@]}"; do
    if ! diff -q "/tmp/bs-A/$f.zig" "/tmp/bs-B/$f.zig" >/dev/null; then
        echo "DIVERGENT: $f.zig"
        DIVERGENT=$((DIVERGENT+1))
    fi
done

if [[ $DIVERGENT -ne 0 ]]; then
    echo "FAIL: $DIVERGENT file(s) diverge between selfhost-A and selfhost-B" >&2
    exit 1
fi

# Tree is left in selfhost-B-emitted state: main.zig as root (with entry
# thunk + _zbr_error_msg), everything else last-written as a dep of main.
# This is the deterministic fixed point, so subsequent runs produce no diff.
# (We used to restore to zebra-emitted form here, but zebra leaks pointer
# addresses into _box_<hex>/_bp_<hex> identifier names — see BUGS.md — so
# every bootstrap run would dirty the working tree.)

echo "PASS: round-trip clean, selfhost-B produces output byte-identical to selfhost-A"
