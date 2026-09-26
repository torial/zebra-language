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

# ── 1b. a CHECK must not RUN the program (2026-09-25) ────────────────────────
# `--check-full` on its own used to compile AND RUN the program: a hello world printed,
# an Http.serve server started listening. Only `-c --check-full` stopped short. `--help`
# called it a "full check", so a user checking a server started it, and one checking a
# script that deletes files ran it. Leg 1 could not see this -- "accepts valid code"
# passes whether or not the program ran. The sentinel below is printed only by RUNNING
# the program, so its absence is the property; its presence under a plain run (the
# control) proves the program does print it and that this leg can see output at all.
printf 'def main()\n    print("CHECK-MUST-NOT-RUN-ME")\n' > "$OUT/runs.zbr"
if "$ZEBRA" "$OUT/runs.zbr" 2>&1 | grep -q CHECK-MUST-NOT-RUN-ME; then
    if "$ZEBRA" --check-full "$OUT/runs.zbr" 2>&1 | grep -q CHECK-MUST-NOT-RUN-ME; then
        fail "--check-full RAN the program (a check must not execute it)"
    else pass "--check-full checks without running the program"; fi
else fail "control: a plain run did not print the sentinel -- this leg cannot see output"; fi

# ── 2. a front-end error is caught by BOTH ───────────────────────────────────
printf 'def main()\n    var s: str = "x" + 1\n    print(s)\n' > "$OUT/bad.zbr"
if "$ZEBRA" -c "$OUT/bad.zbr" >/dev/null 2>&1; then fail "-c accepted a type error"
else pass "-c rejects a front-end error"; fi
if "$ZEBRA" --check-full "$OUT/bad.zbr" >/dev/null 2>&1; then fail "--check-full accepted a type error"
else pass "--check-full rejects a front-end error"; fi

# ── 3. THE ASYMMETRY: emits clean, zig rejects ───────────────────────────────
# Each of these passes the front end and is then rejected by zig. That is exactly what
# --help promises, so at least one must still behave that way.
# WITNESS SELECTION CRITERION, adopted 2026-08-04 (Sean): a witness must demonstrate a
# GENUINE LIMIT of front-end checking -- something `zig` can see that no Zebra front end
# could -- NOT a check the selfhost happens to be missing.
#
# The original three were audited against that criterion and two FAILED it. The bootstrap
# rejects both bug099_unresolved_test and bug106_heterogeneous_list_test, which proves a
# Zebra front end CAN catch them; the selfhost simply had not been given the checks. Using
# those as evidence that "-c cannot see everything" was circular -- it demonstrated missing
# features, not a boundary. BUG-106's check has since been ported and that file no longer
# passes -c at all.
#
#   witness_zig_backend_literal  PERMANENT. A `zig"..."` literal is passed through to the
#                                emitted Zig UNPARSED by design, so the front end cannot
#                                judge it even in principle. This asymmetry can never be
#                                "fixed", which is what a witness should rest on.
#   c_interop_test               genuine: a missing C source file is a link-time fact.
#   bug099_unresolved_test       ON NOTICE -- still passes -c only because the selfhost
#                                lacks the check the bootstrap has. Retire it when BUG-099
#                                is ported (BUG-252); it is listed so the set never drops
#                                to one, not because it is good evidence.
WITNESSES="witness_zig_backend_literal c_interop_test bug099_unresolved_test"
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
# Guards against `-c` quietly starting to invoke zig again.
#
# SELF-CALIBRATING, and it has to be. This was an absolute `< 500ms`, written when
# "the front end is ~60ms". On 2026-08-06 it failed at 1205ms on an IDLE machine —
# and `zebra --help`, which compiles NOTHING, measured 1445-1801ms by itself. The
# 37 MB binary simply costs that much to load here now. So the gate was reporting a
# lost fast path while the fast path was fine: an absolute millisecond number is a
# recorded constant, and recorded constants rot exactly like the hardcoded binary
# size that `release_mode_check` had to stop using for the same reason.
#
# What the check actually wants to know is "does `-c` do substantially LESS WORK than
# a full check?", and that is a comparison, not a number. So measure three things in
# THIS run: process startup (`--help`, compiles nothing), `-c`, and `--check-full`.
# Subtracting startup leaves the work each mode really does, on this machine, today.
t0=$(date +%s%N); "$ZEBRA" --help            >/dev/null 2>&1; t1=$(date +%s%N)
base=$(( (t1 - t0) / 1000000 ))
t0=$(date +%s%N); "$ZEBRA" -c "$OUT/ok.zbr"  >/dev/null 2>&1; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
t0=$(date +%s%N); "$ZEBRA" --check-full "$OUT/ok.zbr" >/dev/null 2>&1; t1=$(date +%s%N)
full=$(( (t1 - t0) / 1000000 ))

work_c=$(( ms - base ));   [ "$work_c" -lt 0 ] && work_c=0
work_f=$(( full - base )); [ "$work_f" -lt 0 ] && work_f=0

# REFUSE rather than report when the two modes cannot be told apart — if a full check
# costs no more than startup noise, this run has no resolution and a "pass" would mean
# nothing. A check that has stopped discriminating must not look like a check that
# found nothing.
if [ "$work_f" -lt 150 ]; then
    fail "cannot discriminate: --check-full cost only ${work_f}ms above startup (${base}ms) — no resolution to judge -c by"
elif [ $(( work_c * 2 )) -lt "$work_f" ]; then
    pass "-c does ${work_c}ms of work vs --check-full ${work_f}ms (startup ${base}ms) — fast path intact"
else
    fail "-c did ${work_c}ms of work vs --check-full ${work_f}ms (startup ${base}ms) — that is full-check territory, the fast path may be gone"
fi

echo
if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mcheck-mode: %d check(s) FAILED\033[0m\n' "$FAIL"; exit 1
fi
printf '\033[32mcheck-mode: all checks pass\033[0m\n'
