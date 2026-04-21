#!/usr/bin/env bash
# test/selfhost_compat/run_compat.sh
#
# Verify that zebra-selfhost.exe produces the same diagnostic lines as
# zebra.exe, so CompilerBridge.parseLine() in ZebraIDE.zbr keeps working
# after Phase 22 cutover.
#
# Expected format (required by parseLine):
#   path:LINE:COL: error: message
#
# The selfhost binary in normal mode delegates to the Zig backend and
# passes its stderr through; extra zig build scaffolding lines are already
# filtered by parseLine() returning nil for non-matching lines.
#
# Known gap (documented, not a cutover blocker):
#   --selfhost-compile mode uses remapZigErrors() which emits "file:LINE: error:"
#   (no COL field). parseLine() will return nil for those lines. This is only
#   relevant if --selfhost-compile ever becomes the default for -c checks.
#
# Run from repo root: bash test/selfhost_compat/run_compat.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZIG_ZEBRA="$REPO/zig-out/bin/zebra.exe"
SELFHOST="$REPO/zig-out/bin/zebra-selfhost.exe"
DIR="$(dirname "${BASH_SOURCE[0]}")"

PASS=0
FAIL=0

check() {
    local fixture="$1"
    local name
    name="$(basename "$fixture")"

    if [[ ! -x "$ZIG_ZEBRA" ]]; then
        echo "SKIP $name: $ZIG_ZEBRA not found — run 'zig build' first"
        return
    fi
    if [[ ! -x "$SELFHOST" ]]; then
        echo "SKIP $name: $SELFHOST not found — run 'zig build selfhost' first"
        return
    fi

    # Run both compilers; capture stderr (they exit non-zero, so || true)
    local zig_out sh_out
    zig_out=$("$ZIG_ZEBRA" -c "$fixture" 2>&1 || true)
    sh_out=$("$SELFHOST"   -c "$fixture" 2>&1 || true)

    # Extract the first line matching path:LINE:COL: (parseLine's expected format)
    local diag_re='[^:]+:[0-9]+:[0-9]+:'
    local zig_diag sh_diag
    zig_diag=$(echo "$zig_out" | grep -E "^$diag_re" | head -1 || true)
    sh_diag=$( echo "$sh_out"  | grep -E "^$diag_re" | head -1 || true)

    # Compare the LINE:COL:severity:message tail (strip path prefix so
    # absolute vs relative differences don't cause spurious failures)
    local zig_tail sh_tail
    zig_tail=$(echo "$zig_diag" | sed 's|^[^:]*:||')   # strip leading path
    sh_tail=$( echo "$sh_diag"  | sed 's|^[^:]*:||')

    if [[ -z "$zig_diag" ]]; then
        echo "FAIL $name: Zig compiler produced no diagnostic line"
        FAIL=$((FAIL+1))
        return
    fi
    if [[ -z "$sh_diag" ]]; then
        echo "FAIL $name: selfhost compiler produced no diagnostic line"
        echo "  zig output: $zig_out"
        FAIL=$((FAIL+1))
        return
    fi
    if [[ "$zig_tail" == "$sh_tail" ]]; then
        echo "PASS $name"
        PASS=$((PASS+1))
    else
        echo "FAIL $name: diagnostic mismatch"
        echo "  zig:      $zig_tail"
        echo "  selfhost: $sh_tail"
        FAIL=$((FAIL+1))
    fi
}

check "$DIR/type_error.zbr"
check "$DIR/undef_var.zbr"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
