#!/usr/bin/env bash
# boundary_check.sh — A3: the boundary-value suite (SQLite plan, Tier A).
#
# WHAT MAKES THIS DIFFERENT FROM output_sweep.sh, WHICH IS THE ONLY REASON IT EXISTS
# ----------------------------------------------------------------------------------
# `output_sweep.sh` is a GOLDEN baseline: it records what the corpus currently prints
# and fails when that changes. That catches regressions and cannot, even in principle,
# catch behaviour that was wrong on day one — the recorded value IS the assertion, so
# a wrong value is recorded as confidently as a right one.
#
# Every `.expected` file here was written by HAND, from the language reference, BEFORE
# the probe was ever run. The seam is deliberately visible in git history: the probes
# and their intended output were committed in one commit, and the first run's findings
# in the next. That ordering is the whole value of this suite — if a future change
# authors an `.expected` by pasting observed output, this becomes output_sweep with
# extra steps and should be deleted rather than kept.
#
# So: when a probe FAILS, the first question is not "what changed?" but "which is
# wrong, the compiler or the expectation?" — and the answer belongs in
# docs/boundary_triage.md either way.
#
# OUTCOME KINDS
# -------------
# A boundary case has several honest outcomes, and a stdout diff models only one of
# them. Each probe declares its kind in a header directive:
#
#   # @boundary runs                       -> must exit 0; stdout must EQUAL the .expected file
#   # @boundary rejects <diagnostic text>  -> compiler must REFUSE it, naming <diagnostic text>
#   # @boundary panics  <message text>     -> must build, then FAIL at runtime with <message text>
#   # @boundary warns   <warning text>     -> must exit 0 but EMIT <warning text>
#
# `rejects` and `panics` abort the process, so a probe of either kind must be its own
# file — a trap in case 3 of 20 silently hides cases 4..20 inside a green suite.
#
# PINNING WHAT IS KNOWN-WRONG, INSTEAD OF DELETING IT
# ---------------------------------------------------
# The first run found real bugs. Deleting those probes would have bought a green gate
# by removing the coverage that earned it, and a permanently-red gate gets switched
# off. So a probe may carry a second directive:
#
#   # @boundary-pending BUG-NNN  <one-line reason>
#
# meaning: THIS PROBE ENCODES CURRENT BEHAVIOUR THAT IS KNOWN TO DIFFER FROM INTENT.
# The declared assertion is still checked (so the gate is green and honest about
# today), the ticket is printed on every run (so the debt cannot go quiet), and when
# the bug is finally fixed the assertion BREAKS — which is the point. A pending probe
# is a tripwire on a known gap, not a suppression of it.
#
# When a pending probe starts failing, do not "fix" it: check whether BUG-NNN was
# closed, and if so rewrite the probe to assert the INTENT it was always meant to.
#
# USAGE
#   bash tools/boundary_check.sh              # the gate
#   bash tools/boundary_check.sh --only nil   # one dimension, for a tight loop
#   bash tools/boundary_check.sh --show       # print each probe's ACTUAL output
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

ZEBRA="$REPO/zig-out/bin/zebra.exe"
DIR="$REPO/test/boundary"

ONLY=""
SHOW=0
for a in "$@"; do
    case "$a" in
        --only) ONLY="__NEXT__" ;;
        --show) SHOW=1 ;;
        *) if [ "$ONLY" = "__NEXT__" ]; then ONLY="$a"; else
               echo "boundary_check: unknown argument '$a'" >&2; exit 2; fi ;;
    esac
done
[ "$ONLY" = "__NEXT__" ] && { echo "boundary_check: --only needs a value" >&2; exit 2; }

if [ ! -x "$ZEBRA" ]; then
    echo "boundary_check: $ZEBRA missing. Run 'zig build' first." >&2
    exit 2
fi
if [ ! -d "$DIR" ]; then
    echo "boundary_check: $DIR missing" >&2
    exit 2
fi

# Per-process scratch: two concurrent runs sharing one dir made each other fail for no
# reason in selfhost_smoke.sh, which is a mistake worth not repeating.
TIMEOUT_SECS=60
OUT="/tmp/boundary-check-$$"
rm -rf "$OUT"; mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

PASS=0; FAIL=0; SKIP=0
PENDING_LIST=""
green() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
red()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2;  FAIL=$((FAIL+1)); }
note()  { printf '  \033[33m--\033[0m    %s\n' "$1"; }

echo "boundary-value suite (test/boundary) — expectations authored from intent"
echo

shopt -s nullglob
for zbr in "$DIR"/*.zbr; do
    base="$(basename "$zbr" .zbr)"
    [ -n "$ONLY" ] && case "$base" in *"$ONLY"*) ;; *) continue ;; esac

    directive="$(grep -m1 '^# @boundary ' "$zbr" 2>/dev/null || true)"
    if [ -z "$directive" ]; then
        red "$base (no '# @boundary' directive — the runner cannot know what to assert)"
        continue
    fi
    kind="$(printf '%s' "$directive" | awk '{print $3}')"
    arg="$(printf '%s' "$directive" | sed -E 's/^# @boundary[[:space:]]+[a-z]+[[:space:]]*//')"

    pending="$(grep -m1 '^# @boundary-pending ' "$zbr" 2>/dev/null \
               | sed -E 's/^# @boundary-pending[[:space:]]*//' || true)"
    if [ -n "$pending" ]; then
        PENDING_LIST="${PENDING_LIST}${base}: ${pending}"$'\n'
    fi

    # A compiled Zebra program's own output arrives on the COMBINED stream, interleaved
    # with the compiler's progress chatter — `zebra foo.zbr` prints "compiling:",
    # "parsing...", "wrote ..." around it. So capture 2>&1 and strip those lines with
    # the same filter output_sweep.sh uses, rather than inventing a second convention.
    # A timeout is not optional here: a TCO fall-through in a value-returning `branch`
    # HANGS rather than erroring (see the fall-through lint), and a boundary probe is
    # exactly the shape that trips it.
    timeout "$TIMEOUT_SECS" "$ZEBRA" "$zbr" > "$OUT/both.txt" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
        red "$base (TIMED OUT after ${TIMEOUT_SECS}s — a hang, not a wrong answer)"
        continue
    fi
    # -a is load-bearing, not defensive. A probe whose output is deliberately INVALID
    # UTF-8 (bv_reverse_nonascii, which pins BUG-234) makes grep treat the stream as
    # binary: it prints "Binary file ... matches" and DROPS the content. The offending
    # row vanished from the diff while every row around it stayed, which reads as
    # "that line was never printed" rather than "the harness ate it" — and the harness
    # eating evidence is the worse of the two by far. A boundary suite whose whole job
    # is odd inputs must not be blinded by an odd input.
    grep -avE '^wrote |^compiling:|^ *parsing\.\.\.|^ *parsed OK|^ *resolved OK' \
        "$OUT/both.txt" > "$OUT/out.txt" || true

    if [ "$SHOW" = 1 ]; then
        echo "── $base (kind=$kind, rc=$rc)"
        sed 's/^/    | /' "$OUT/out.txt"
    fi

    case "$kind" in
    runs)
        exp="$DIR/$base.expected"
        if [ ! -f "$exp" ]; then
            red "$base (kind=runs but $base.expected is missing)"
            continue
        fi
        if [ "$rc" -ne 0 ]; then
            red "$base (expected a clean run, exit $rc)"
            sed 's/^/        /' "$OUT/out.txt" | head -20 >&2
            continue
        fi
        # Compare ignoring trailing CR so a CRLF checkout cannot fail the gate for a
        # reason that has nothing to do with the language.
        sed 's/\r$//' "$OUT/out.txt" > "$OUT/got.norm"
        sed 's/\r$//' "$exp"         > "$OUT/exp.norm"
        if diff -q "$OUT/exp.norm" "$OUT/got.norm" >/dev/null; then
            green "$base"
        else
            red "$base (output differs from intended)"
            diff -u "$OUT/exp.norm" "$OUT/got.norm" | sed 's/^/        /' | head -40 >&2
        fi
        ;;
    rejects)
        if [ "$rc" -eq 0 ]; then
            red "$base (expected the compiler to REJECT this, but it built and ran)"
            continue
        fi
        if grep -qF "$arg" "$OUT/both.txt"; then
            green "$base (rejected: $arg)"
        else
            red "$base (rejected, but not with the intended diagnostic: $arg)"
            sed 's/^/        /' "$OUT/both.txt" | head -20 >&2
        fi
        ;;
    panics)
        if [ "$rc" -eq 0 ]; then
            red "$base (expected a runtime failure, but it exited 0)"
            continue
        fi
        if grep -qF "$arg" "$OUT/both.txt"; then
            green "$base (panicked: $arg)"
        else
            red "$base (failed, but not with the intended message: $arg)"
            sed 's/^/        /' "$OUT/both.txt" | head -20 >&2
        fi
        ;;
    warns)
        # Asserted by SUBSTRING rather than by a diff: a warning line carries the
        # absolute source path, which would make an .expected file machine-specific.
        if [ "$rc" -ne 0 ]; then
            red "$base (expected a warning on a successful compile, exit $rc)"
            sed 's/^/        /' "$OUT/both.txt" | head -20 >&2
            continue
        fi
        if grep -qF "$arg" "$OUT/both.txt"; then
            green "$base (warned: $arg)"
        else
            red "$base (compiled, but the intended warning is MISSING: $arg)"
            sed 's/^/        /' "$OUT/both.txt" | head -20 >&2
        fi
        ;;
    *)
        red "$base (unknown @boundary kind '$kind'; expected runs|rejects|panics|warns)"
        ;;
    esac
done

if [ -n "$PENDING_LIST" ]; then
    echo
    echo "  PENDING — these probes pin behaviour that is known to differ from intent."
    echo "  They pass today BY DESIGN; each breaks when its ticket is fixed, which is the signal"
    echo "  to rewrite it to assert the intent instead:"
    printf '%s' "$PENDING_LIST" | sed 's/^/    /'
fi

echo
echo "  uncovered by this suite (see docs/boundary_triage.md for the full list and why):"
echo "    float extremes, min/max int overflow  — build-mode dependent; blocked on BUG-228"
echo "    non-ASCII indexing                    — BUG-225 is a KNOWN wrong behaviour, deferred to 1.x"
echo "    charAt                                — BUG-223 is an open decision awaiting Sean"

echo
# A run that measured NOTHING must not report success. `--only typo` would otherwise
# print "0 pass, 0 fail" and exit 0 — a green verdict on an empty measurement, which is
# the exact vacuity shape tools/gate_selfcheck.sh exists to catch. It also protects the
# no-argument case: an empty or mis-globbed test/boundary/ would pass silently forever.
if [ "$((PASS + FAIL))" -eq 0 ]; then
    if [ -n "$ONLY" ]; then
        echo "boundary: --only '$ONLY' matched NO probe — refusing to report success on an empty run" >&2
    else
        echo "boundary: no probes found in $DIR — refusing to report success on an empty run" >&2
    fi
    exit 2
fi

if [ "$FAIL" -gt 0 ]; then
    printf '\033[31mboundary: %d pass, %d FAIL\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
printf '\033[32mboundary: %d pass, 0 fail\033[0m\n' "$PASS"
[ "$SKIP" -gt 0 ] && note "$SKIP skipped"
exit 0
