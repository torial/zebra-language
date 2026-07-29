#!/usr/bin/env bash
# runtime_module_check.sh — end-to-end gate for `--runtime-module` (#1).
#
# WHY A SEPARATE GATE
# -------------------
# `compile_check.sh --runtime-module` proves the emitted Zig COMPILES across the
# corpus, which is the big coverage win. It cannot prove two things that are the
# whole point of the change, because it never runs anything and never looks at the
# shape of what was emitted:
#
#   1. BUG-221 — module init is not transitive. A three-module program whose
#      DEEPEST module touches a file segfaults at 0xffffffffffffffff, because the
#      entry point initialised direct dependencies only. It compiles perfectly.
#      Only running it shows the bug, and only running it shows the fix.
#   2. That the runtime was actually externalised. If a future change quietly fell
#      back to splicing the preamble, everything would still compile and still run
#      — and the emitted file would be 3,800 lines again. The size assertion is
#      what makes "it worked" mean something.
#
# Both checks are cheap (three tiny programs), so this runs in the QUICK tier.
#
#   bash tools/runtime_module_check.sh
#
# NOTE: `--runtime-module` is deliberately NOT passed by bootstrap_check.sh. The
# round-trip re-emits selfhost/*.zig with the selfhost itself, and the compiler's
# own committed .zig must have one shape no matter which tool last regenerated it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

ZEBRA="$REPO/zig-out/bin/zebra.exe"
OUT="${TMPDIR:-/tmp}/zbr-rtmod-$$"
FAIL=0

cleanup() { rm -rf "$OUT"; }
trap cleanup EXIT

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$ZEBRA" ] || { echo "runtime-module: $ZEBRA missing — run 'zig build'"; exit 1; }

echo "runtime-module gate"
echo

# ── 1. hello-world: emits, externalises the runtime, compiles, runs ───────────
hw="$OUT/hw"; mkdir -p "$hw"
printf 'def main()\n    print("hi")\n' > "$hw/hw.zbr"
if ! "$ZEBRA" --emit-zig --output-dir "$hw" --runtime-module "$hw/hw.zbr" >/dev/null 2>&1; then
    fail "hello-world did not emit"
else
    lines=$(wc -l < "$hw/hw.zig" | tr -d ' ')
    if [ ! -f "$hw/zebra_rt.zig" ]; then
        fail "zebra_rt.zig was not written beside the program"
    elif [ "$lines" -gt 100 ]; then
        # The inline shape is ~3,790 lines. Anything near that means the runtime
        # was spliced in after all and the split silently regressed.
        fail "emitted program is $lines lines — the runtime was NOT externalised"
    elif ! ( cd "$hw" && zig build-exe hw.zig -fno-llvm -fno-lld -femit-bin=hw.exe >/dev/null 2>&1 ); then
        fail "emitted hello-world does not compile"
    elif [ "$("$hw/hw.exe" 2>&1)" != "hi" ]; then
        fail "emitted hello-world does not run"
    else
        pass "hello-world: $lines-line program + shared runtime, compiles and runs"
    fi
fi

# ── 2. BUG-221: transitive module init (the reason the change exists) ─────────
b="$OUT/b221"; mkdir -p "$b"
cp test/bug221_transitive_init_leaf.zbr test/bug221_transitive_init_mid.zbr \
   test/bug221_transitive_init_test.zbr "$b/" 2>/dev/null || {
       fail "BUG-221 fixture missing from test/"; }
if [ -f "$b/bug221_transitive_init_test.zbr" ]; then
    if ! "$ZEBRA" --emit-zig --output-dir "$b" --runtime-module \
            "$b/bug221_transitive_init_test.zbr" >/dev/null 2>&1; then
        fail "BUG-221 fixture did not emit"
    elif ! ( cd "$b" && zig build-exe bug221_transitive_init_test.zig \
                -fno-llvm -fno-lld -femit-bin=b221.exe >/dev/null 2>&1 ); then
        fail "BUG-221 fixture does not compile"
    else
        got=$("$b/b221.exe" 2>&1)
        if [ "$got" = "missing" ]; then
            pass "BUG-221: depth-2 dep initialises and runs (was: segfault)"
        else
            fail "BUG-221: expected 'missing', got: $got"
        fi
    fi
fi

# ── 3. the mutually-exclusive flags are actually refused ─────────────────────
if "$ZEBRA" --emit-zig --output-dir "$hw" --runtime-module --single-file \
        "$hw/hw.zbr" >/dev/null 2>&1; then
    fail "--runtime-module --single-file was accepted; it should be refused"
else
    pass "--runtime-module + --single-file is refused"
fi

echo
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mruntime-module: %d check(s) FAILED\033[0m\n' "$FAIL"
    exit 1
fi
printf '\033[32mruntime-module: all checks pass\033[0m\n'
