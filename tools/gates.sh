#!/usr/bin/env bash
# gates.sh — run the verification gates as a set, in the right order, with one
# summary line each and a non-zero exit if any fail.
#
# WHY THIS EXISTS
# ---------------
# There are 14 gates in the QUICK tier alone, with genuinely different blind spots  <!-- doc-gen: 14 = grep -c '^run "' tools/gates.sh -->
# (CLAUDE.md explains each), plus four heavy witnesses in FULL. The count in this
# sentence has been wrong before: it said "seven" while twelve were registered, and
# doc_lint cannot catch that class -- a number in prose has no referent to resolve.
# If you add a `run` line, fix the number here; `grep -c '^run "' tools/gates.sh` is
# the oracle. Running them meant assembling an ad-hoc command line every time and
# remembering which set matters after which kind of change — which is precisely
# the sort of repetitive minutiae a script is better at than a person. The risk
# is not tedium, it is SKIPPING one: the gates that catch the most are the ones
# that are slowest and least automatic.
#
#   bash tools/gates.sh              # QUICK  (~6 min)  — after any .zbr edit
#   bash tools/gates.sh --full       # FULL   (~50 min) — before committing codegen
#   bash tools/gates.sh --list       # what each tier runs, and what it cannot see
#
# QUICK also carries the A3 boundary suite — the one gate whose expectations were
#         written from intent rather than recorded, and therefore the only one that can
#         find behaviour that was wrong from day one rather than newly broken.
# QUICK's static lints look at Zebra code, EXCEPT hazard-lint, which looks at the tools
# in this directory -- the place the 2026-07/08 wrong numbers actually came from.
# QUICK = the static lints (instant), smoke (emits + runs fixtures), round-trip
#         (self-consistency), check-mode (the -c vs --check-full contract, incl.
#         proof the documented asymmetry is real), runtime-module (small
#         end-to-end programs incl. the
#         BUG-221 repro — the only gate that RUNS emitted output, and the only one
#         that checks the DEFAULT shape is actually the split one). Catches most
#         breakage fast.
# FULL  = QUICK plus the four heavy independent witnesses:
#         compile_check        — compiles what the selfhost emits (`zig` as witness)
#         compile_check-inline — the same corpus with --no-runtime-module. The split
#                                runtime is the DEFAULT now, so the INLINE shape is
#                                the one that would go unwatched — and it stays live
#                                via the opt-out and the GUI/node-addon fallbacks
#         output_sweep     — RUNS 327 corpus programs and compares what they PRINTED
#                            against a golden baseline. The only heavy gate that runs
#                            anything: the rest ask "does it compile?", so wrong OUTPUT
#                            from valid Zig is invisible to them (BUG-226). Catches
#                            regressions, not existing wrongness.
#         full_sweep       — emits + typechecks the WHOLE corpus, gated on regression
#         divergence       — emits with BOTH compilers, gated on selfhost gaps
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
        # Print the whole leading comment block, however long it grows — a fixed
        # line range silently truncated the header (and then leaked shell code
        # into --list) the first time a gate was added.
        sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
        exit 0 ;;
    "" ) ;;
    * ) echo "gates.sh: unknown option '$1' (try --full or --list)" >&2; exit 2 ;;
esac

JOBS="${JOBS:-2}"
FAILED=()
PASSED=0

# run <label> <expected-substring-on-success> <command...>
#
# Prints the label BEFORE running and streams to a per-gate log, so a hang is
# visible immediately instead of after the fact. The first version captured with
# command substitution and printed only on completion — which meant a gate that
# hung looked exactly like a gate that was working, for 32 minutes. Also applies
# a per-gate timeout so a hang FAILS instead of blocking the suite forever.
run() {
    local label="$1"; shift
    local expect="$1"; shift
    local out rc log t0 t1
    log="$(mktemp -t gate-XXXXXX)"
    t0=$SECONDS
    # Announce BEFORE running and leave the line open, so an in-progress gate is
    # visibly in progress. stderr so it survives a caller piping stdout.
    printf '  %-16s ...' "$label" >&2
    timeout "${GATE_TIMEOUT:-2700}" "$@" >"$log" 2>&1; rc=$?
    t1=$((SECONDS - t0))
    out="$(cat "$log")"; rm -f "$log"
    printf '\r  %-16s ' "$label" >&2
    if [[ $rc -eq 124 ]]; then
        printf '\033[31mHANG\033[0m  killed after %ss\n' "${GATE_TIMEOUT:-2700}"
        FAILED+=("$label(timeout)")
        return
    fi
    local last
    # `grep -a` is load-bearing. Several tools print a UTF-8 em-dash, which Windows
    # mangles into a byte grep treats as binary -- it then prints "Binary file (standard
    # input) matches" INSTEAD of the summary, and that is what the `registration` gate's
    # line said on the board for its whole life. A gate whose result is unreadable is one
    # step from a gate nobody reads.
    last="$(echo "$out" | grep -a -vE '^[[:space:]]*$' | tail -1)"
    # THE rc CONJUNCT IS LOAD-BEARING, not belt-and-braces. `grep -qF "0 hazard"` also
    # matches "10 hazard(s)" -- and "0 stale" matches "10 stale", "20 stale", and so on.
    # Every count-shaped expectation here has that property. It is sound today only
    # because each of those tools exits non-zero when its count is non-zero.
    #
    # So: a NEW gate whose tool reports a count but exits 0 regardless would pass this
    # matcher while reporting failures. If you add one, either make it exit non-zero or
    # give it an expectation that is not a count prefix.
    if [[ $rc -eq 0 ]] && { [[ -z "$expect" ]] || echo "$out" | grep -qF "$expect"; }; then
        printf '\033[32mPASS\033[0m  %-58s %ss\n' "${last:0:58}" "$t1"
        PASSED=$((PASSED + 1))
    else
        printf '\033[31mFAIL\033[0m  %-58s %ss\n' "${last:0:58}" "$t1"
        FAILED+=("$label")
        echo "$out" | tail -12 | sed 's/^/        /'
    fi
}

# Preflight: a gate result is only meaningful if it measured the right compiler.
# doctor exits 1 on states that make results LIE (chiefly stale generated .zig,
# i.e. you would be testing the OLD compiler — see BUG-210).
if ! bash "$SCRIPT_DIR/doctor.sh" >/tmp/gates-doctor.log 2>&1; then
    echo "gates.sh: refusing to run — the tree is in a state where results cannot be trusted:" >&2
    grep -E "WRONG" /tmp/gates-doctor.log >&2 || cat /tmp/gates-doctor.log >&2
    exit 1
fi

echo "gates: $MODE (JOBS=$JOBS)"
bash "$SCRIPT_DIR/sysload.sh" 2>/dev/null | sed 's/^/  /'
echo

run "interp-escape"  "0 hazard"  python tools/lint_interp_escape.py
run "fallthrough"    "0 hazard"  python tools/lint_fallthrough.py
# The only gate aimed at OUR OWN TOOLING rather than at Zebra code. Five bugs in
# tools/mutation_check.py in two days, none of which crashed or exited non-zero -- every
# one produced a plausible wrong number and two were published. It refuses to report
# clean if its own controls stop firing, and `--rev <sha>` re-derives what it would have
# said on the commit that shipped the bugs.
run "hazard-lint"    "0 hazard"  python tools/hazard_lint.py
# The docs' CHECKABLE claims. Most of what they assert needs a human; the machine-checkable
# minority is the part that rots fastest, because it is exactly what changes when a tool is
# renamed or retired. Append-only records (BUGS.md, the journal) are reported but not gated
# -- an old entry naming a since-deleted tool is accurate history, not a defect.
run "doc-lint"       "0 stale"   python tools/doc_lint.py --quiet
run "doc-example"    "0 NEW"     python tools/doc_example_check.py --quiet
run "smoke"          "passed"    bash tools/selfhost_smoke.sh
run "round-trip"     "PASS"      bash tools/bootstrap_check.sh
# The only gate that RUNS emitted output, hence the only one that can see BUG-221 —
# and the only one that would notice if the default silently stopped being the split
# runtime, since every other gate is happy either way.
run "runtime-module" "all checks pass" bash tools/runtime_module_check.sh
# #4: `-c` is front-end-only and deliberately incomplete. This gates the CONTRACT —
# that valid code passes both modes, a front-end error fails both, and the asymmetry
# --help promises ACTUALLY EXISTS (witnesses that pass -c and fail --check-full).
# It also guards the speed, so `-c` silently starting to invoke zig again fails here.
run "check-mode"     "all checks pass" bash tools/check_mode_check.sh
# §28e: docs/str_ownership.md is DERIVED from real emit, so a codegen change that flips
# a borrow into an own (or the reverse) makes the shipped table wrong while it still
# carries a "GENERATED" banner vouching for it. One emit; cheap.
run "str-ownership"  "is current" python tools/str_ownership_extract.py --check
# A1 (testing_strategy.md): SQLite's "a regression test for every reported bug", as a lint
# rather than a habit. Fails only on NEW debt — the backlog is baselined — and counts a
# fixture as real only if something actually RUNS it. Static; instant.
run "bug-fixture"    "gate PASS" python tools/bug_fixture_check.py --gate
# BUG-243: a corpus file that nothing registers AND that has never been sweep-clean
# is invisible to every gate -- full_sweep baselines the pass set, so a file that has
# never passed cannot make it red. Fifteen files were found in that state, two of them
# regression fixtures that had never run. Baselined like bug-fixture: fails on NEW debt.
run "registration"   "0 NEW"    python tools/registration_check.py
# A4: `unreachable` is UB in ReleaseFast, which is what `zebra --release` ships. Every
# gate here runs Debug, where it traps cleanly — so this hazard is invisible to all of
# them and live only in what users distribute. A static lint is the only witness.
run "oom-unreachable" "0 hazard" python tools/lint_oom_unreachable.py
# A3: the boundary-value suite. The ONLY gate here whose expectations were written from
# INTENT rather than recorded from behaviour — output_sweep is a golden baseline and so
# can never find something that was wrong on day one. 23 probes, ~30s, and it found  <!-- doc-gen: 23 = bash tools/corpus_ls.sh test/boundary | wc -l | tr -d ' ' -->
# BUG-230/231/232 on its first run. Probes marked @boundary-pending pin known-broken
# behaviour deliberately and will FAIL when their ticket is fixed; that is the signal to
# rewrite them, not to re-baseline.
run "boundary"       "0 fail"   bash tools/boundary_check.sh

if [[ "$MODE" == "full" ]]; then
    # THE ONLY GATE THAT BUILDS WITH --release. Every other gate here is Debug, which is
    # how BUG-228 survived 19 green gates: `--release` switched backend but never passed
    # an optimize flag, so users shipped Debug believing otherwise.
    run "release-mode"   "all checks pass" bash tools/release_mode_check.sh
    run "compile_check" "0 FAILED" env JOBS="$JOBS" bash tools/compile_check.sh
    # The same corpus with the INLINE runtime. Since 2026-07-28 the split runtime is
    # the DEFAULT, so this is the mode that would otherwise go unwatched — and it is
    # still live: --no-runtime-module selects it, and the GUI and node-addon paths
    # fall back to it.
    run "compile_check-inline" "0 FAILED" env JOBS="$JOBS" bash tools/compile_check.sh --no-runtime-module
    # THE BEHAVIOUR GATE, and the only heavy one that RUNS anything. Every other gate in
    # this tier asks "does the emitted Zig compile?", so valid Zig producing the WRONG
    # OUTPUT is invisible to all of them at any corpus size — BUG-226 is the receipt.
    # Golden baseline: it catches REGRESSIONS against recorded behaviour, not existing
    # wrongness. Sequential by design; parallel runs would let fixtures interfere and a
    # flaky behaviour gate is one people learn to re-baseline without reading.
    run "output_sweep"  "identical to baseline" bash tools/output_sweep.sh --gate
    run "full_sweep"    "gate PASS" env JOBS="$JOBS" bash tools/full_sweep.sh --gate
    # A5: the SAME sweep over examples/*.zbr, which no gate touched until 2026-07-30.
    # examples/widget_smoke.zbr shipped BROKEN on BUG-230 and nothing noticed, because
    # every other heavy gate globs test/*.zbr and `zebra -c` is front-end-only so the
    # obvious spot-check exits 0. Small corpus, ~90s. Buckets that are NOT gated are
    # NAMED in its output rather than counted, because on examples/ each one is a
    # question worth answering.
    run "examples_sweep" "gate PASS" env JOBS="$JOBS" bash tools/full_sweep.sh --examples --gate
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
