#!/usr/bin/env bash
# check_mode_check.sh — gate the CONTRACT of `-c` vs `--check-full` (#4).
#
# WHY THIS EXISTS
# ---------------
# `-c` is front-end-only as of 2026-07-29: fast, and deliberately incomplete. That
# incompleteness is a promise to users, printed in `--help`:
#
#     -c can pass on code that `zebra run` fails to build
#
# A promise nobody tests is a comment. Two ways it could rot, both silent:
#
#   1. `-c` starts invoking zig again (someone "fixes" the asymmetry). The fast path
#      quietly becomes slow, the IDE goes back to a pause, and every test still passes
#      because the answers are all still correct.
#   2. `--check-full` stops being fuller than `-c`. Then the flag is a lie and the
#      escape hatch users are pointed at does nothing.
#
# So this asserts the asymmetry EXISTS, using corpus files that really do emit cleanly
# and are then rejected by zig. If the front end ever grows strong enough to catch all
# three of them, this gate FAILS — and that failure is good news that needs a decision
# (pick a new witness, or retire the asymmetry and make `-c` total again). It should not
# be silently deleted.
#
#   bash tools/check_mode_check.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

ZEBRA="$REPO/zig-out/bin/zebra.exe"
FAIL=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -x "$ZEBRA" ] || { echo "check-mode: $ZEBRA missing — run 'zig build'"; exit 1; }

echo "check-mode gate"
echo

OUT="${TMPDIR:-/tmp}/zbr-chk-$$"; mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

# ── 1. valid code passes both ────────────────────────────────────────────────
printf 'def main()\n    print("hi")\n' > "$OUT/ok.zbr"
if "$ZEBRA" -c "$OUT/ok.zbr" >/dev/null 2>&1; then pass "-c accepts valid code"
else fail "-c rejected valid code"; fi
if "$ZEBRA" --check-full "$OUT/ok.zbr" >/dev/null 2>&1; then pass "--check-full accepts valid code"
else fail "--check-full rejected valid code"; fi

# ── 2. a front-end error is caught by BOTH ───────────────────────────────────
printf 'def main()\n    var s: str = "x" + 1\n    print(s)\n' > "$OUT/bad.zbr"
if "$ZEBRA" -c "$OUT/bad.zbr" >/dev/null 2>&1; then fail "-c accepted a type error"
else pass "-c rejects a front-end error"; fi
if "$ZEBRA" --check-full "$OUT/bad.zbr" >/dev/null 2>&1; then fail "--check-full accepted a type error"
else pass "--check-full rejects a front-end error"; fi

# ── 3. THE ASYMMETRY: emits clean, zig rejects ───────────────────────────────
# Each of these passes the front end and is then rejected by zig. That is exactly what
# --help promises, so at least one must still behave that way.
WITNESSES="bug099_unresolved_test bug106_heterogeneous_list_test c_interop_test"
found=0
for w in $WITNESSES; do
    f="test/$w.zbr"
    [ -f "$f" ] || continue
    "$ZEBRA" -c "$f" >/dev/null 2>&1 || continue          # front end must accept it
    "$ZEBRA" --check-full "$f" >/dev/null 2>&1 && continue # full must reject it
    pass "asymmetry witness: $w passes -c, fails --check-full"
    found=$((found+1))
done
if [ "$found" -eq 0 ]; then
    fail "no asymmetry witness left — -c and --check-full agree on all of: $WITNESSES"
    printf '        This is not necessarily a regression: the front end may have grown\n'
    printf '        strong enough to catch these. It needs a DECISION — pick a new witness,\n'
    printf '        or retire the asymmetry and make -c total again and say so in --help.\n'
fi

# ── 4. fast really is fast ───────────────────────────────────────────────────
# Guards against `-c` quietly starting to invoke zig again. Generous threshold: the
# front end is ~60ms and a zig pass is ~800ms, so anything under half a second means
# zig was not run. Timing is coarse on purpose — this is a shape check, not a benchmark.
t0=$(date +%s%N)
"$ZEBRA" -c "$OUT/ok.zbr" >/dev/null 2>&1
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [ "$ms" -lt 500 ]; then pass "-c took ${ms}ms (front-end only; a zig pass is ~800ms)"
else fail "-c took ${ms}ms — that is zig-pass territory, the fast path may be gone"; fi

echo
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mcheck-mode: %d check(s) FAILED\033[0m\n' "$FAIL"; exit 1
fi
printf '\033[32mcheck-mode: all checks pass\033[0m\n'
