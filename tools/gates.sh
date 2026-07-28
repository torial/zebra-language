#!/usr/bin/env bash
# gates.sh — run the verification gates as a set, in the right order, with one
# summary line each and a non-zero exit if any fail.
#
# WHY THIS EXISTS
# ---------------
# There are seven gates with genuinely different blind spots (CLAUDE.md explains
# each). Running them meant assembling an ad-hoc command line every time and
# remembering which set matters after which kind of change — which is precisely
# the sort of repetitive minutiae a script is better at than a person. The risk
# is not tedium, it is SKIPPING one: the gates that catch the most are the ones
# that are slowest and least automatic.
#
#   bash tools/gates.sh              # QUICK  (~6 min)  — after any .zbr edit
#   bash tools/gates.sh --full       # FULL   (~50 min) — before committing codegen
#   bash tools/gates.sh --list       # what each tier runs, and what it cannot see
#
# QUICK = the static lints (instant), smoke (emits + runs fixtures), round-trip
#         (self-consistency). Enough to catch most breakage fast.
# FULL  = QUICK plus the three heavy independent witnesses:
#         compile_check   — compiles what the selfhost emits (`zig` as the witness)
#         full_sweep      — emits + typechecks the WHOLE corpus, gated on regression
#         divergence      — emits with BOTH compilers, gated on selfhost gaps
#
# HONEST LIMITS — what NO tier here covers:
#   * Anything requiring a GUI. No gate clicks a button; the libui_ng/IDE paths
#     are only ever proven by a human running them (this is not hypothetical —
#     six green gates once sat on top of three real GUI crashes).
#   * fuzz/gramgen.py (parser robustness) — optional, minutes, run per-session.
#   * tools/node_addon_test.sh — needs node.
# Run those deliberately; they are not folded in so that "gates green" keeps a
# precise meaning.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

MODE="quick"
case "${1:-}" in
    --full) MODE="full" ;;
    --list)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    "" ) ;;
    * ) echo "gates.sh: unknown option '$1' (try --full or --list)" >&2; exit 2 ;;
esac

JOBS="${JOBS:-2}"
FAILED=()
PASSED=0

# run <label> <expected-substring-on-success> <command...>
run() {
    local label="$1"; shift
    local expect="$1"; shift
    printf '  %-16s ' "$label"
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    local last
    last="$(echo "$out" | grep -vE '^\s*$' | tail -1)"
    if [[ $rc -eq 0 ]] && { [[ -z "$expect" ]] || echo "$out" | grep -qF "$expect"; }; then
        printf '\033[32mPASS\033[0m  %s\n' "${last:0:78}"
        PASSED=$((PASSED + 1))
    else
        printf '\033[31mFAIL\033[0m  %s\n' "${last:0:78}"
        FAILED+=("$label")
        echo "$out" | tail -12 | sed 's/^/        /'
    fi
}

if [[ ! -x zig-out/bin/zebra.exe ]]; then
    echo "gates.sh: zig-out/bin/zebra.exe missing — run 'bash tools/rebuild.sh' first" >&2
    exit 1
fi

echo "gates: $MODE (JOBS=$JOBS)"
bash "$SCRIPT_DIR/sysload.sh" 2>/dev/null | sed 's/^/  /'
echo

run "interp-escape"  "0 hazard"  python tools/lint_interp_escape.py
run "fallthrough"    "0 hazard"  python tools/lint_fallthrough.py
run "smoke"          "passed"    bash tools/selfhost_smoke.sh
run "round-trip"     "PASS"      bash tools/bootstrap_check.sh

if [[ "$MODE" == "full" ]]; then
    run "compile_check" "0 FAILED" env JOBS="$JOBS" bash tools/compile_check.sh
    run "full_sweep"    "gate PASS" env JOBS="$JOBS" bash tools/full_sweep.sh --gate
    run "divergence"    "gate PASS" env JOBS="$JOBS" bash tools/divergence_check.sh --gate
fi

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
    printf '\033[32mgates: %d/%d PASS (%s)\033[0m\n' "$PASSED" "$PASSED" "$MODE"
    [[ "$MODE" == "quick" ]] && echo "  (quick tier — run --full before committing a codegen change)"
    exit 0
else
    printf '\033[31mgates: %d FAILED — %s\033[0m\n' "${#FAILED[@]}" "${FAILED[*]}"
    exit 1
fi
