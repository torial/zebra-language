#!/usr/bin/env bash
# gates.sh — run the verification gates as a set, in the right order, with one
# summary line each and a non-zero exit if any fail.
#
# WHY THIS EXISTS
# ---------------
# The gates have genuinely different blind spots (CLAUDE.md explains each). Running
# them meant assembling an ad-hoc command line every time and remembering which set
# matters after which kind of change — which is precisely the sort of repetitive
# minutiae a script is better at than a person. The risk is not tedium, it is
# SKIPPING one: the gates that catch the most are the slowest and least automatic.
#
#   bash tools/gates.sh --static     # ~15s   — no build needed AT ALL
#   bash tools/gates.sh --fast       # ~2.5m  — everything except smoke + round-trip
#   bash tools/gates.sh              # 7-20m  — QUICK, the default. After any .zbr edit
#   bash tools/gates.sh --full       # 36-83m — before committing a codegen change
#   bash tools/gates.sh --daily      # 37-85m — ONCE A DAY: full + the excluded set
#   bash tools/gates.sh --list       # what each tier runs, and what it cannot see
#
# THE TIERS ARE CUMULATIVE: each runs everything below it. So a gate documented as
# "QUICK tier" in CLAUDE.md is still run by QUICK — the lower tiers are SUBSETS, not
# a re-shuffle, and no existing tier label was falsified when they were added.
#
# THE LADDER IS CUT ON BUILD-DEPENDENCE, NOT ON SECONDS (2026-08-19)
# -----------------------------------------------------------------
# The obvious cut is by cost, and it is wrong. Timings are taken on a WARM tree, so a
# gate that measures 1s because the binaries happen to be current (zig-test, ffi-lib,
# diag-columns) costs a full build on a cold one. A tier whose advertised cost stops
# being true exactly when you most want it — mid-edit, stale tree — is a tier that
# lies. Build-dependence is stable, derivable, and maps onto the real question:
#
#   --static  needs NO Zebra binary. If you edited docs, ledgers, or tools/, this is
#             not a cheap subset — it is COMPLETE coverage for that change.
#   --fast    needs the binary but runs no corpus-scale suite.
#   (default) adds smoke + round-trip, which are 99% of QUICK's wall clock.
#
# MEASURED, NOT ASSUMED. The classification was established by hiding
# zig-out/bin/zebra*.exe and running the candidates: all 12 static gates passed with no
# ZEBRA compiler present, and two controls (str-ownership, diag-columns) REFUSED — so the
# experiment can discriminate. "No compiler" means no Zebra build; zig-keywords still
# needs the ZIG TOOLCHAIN (it reads std/zig/tokenizer.zig, located via `zig env`), so
# re-running the experiment on a machine without zig on PATH will fail it for a reason
# that is not a classification error. `_static_purity_check` below re-derives the cheap half
# of that on every run; the hiding experiment is the stronger control, and re-running
# it by hand is the way to re-prove the boundary after adding a static gate.
#
# WHAT EACH TIER CANNOT SEE — the reason the ladder is not just a speed knob:
#   static : NOTHING here builds, emits, or runs the compiler. It cannot see a
#            miscompile, a crash, a wrong answer, or a build that does not link.
#            A green static tier says the TREE is consistent, not that it WORKS.
#   fast   : no test fixture is executed and the compiler is never round-tripped.
#            BUG-294 was found by the round-trip and by nothing else — a green smoke
#            suite says nothing about what the selfhost emits for the selfhost.
#   quick  : the corpus is never swept. Emitted Zig that fails to COMPILE, behaviour
#            that CHANGED, and selfhost↔bootstrap drift are all invisible here.
#   full   : --release/--turbo are covered, but the three items below are not.
#   daily  : GUI RENDERING, input, layout, resize and colours. No gate clicks a
#            button; six green gates once sat on top of three real GUI crashes.
#            Startup is covered (gui-scaffold); everything after it is not.
#
# THE THREE ITEMS THAT USED TO BE "RUN THESE DELIBERATELY" are the --daily tier as of
# 2026-08-19: fuzz/gramgen.py, tools/node_addon_test.sh, tools/gui_scaffold_check.sh.
# They are still excluded from FULL, so "gates green" keeps its precise meaning — but
# they now have a NAMED cadence instead of a paragraph asking someone to remember.
# NOT included: escape_hatches_check (red on a page_allocator review owned elsewhere)
# and compile_check --bootstrap (219/19/20 is its documented NORMAL state and it has
# no baseline, so it cannot be gated without inventing one).
#
# Record a green --daily run in CLAUDE.md's sweep table; the tier prints the line.

set -uo pipefail
# Where a FAILING gate's complete output is kept (the board shows only a tail). CI uploads
# this directory as an artifact; locally it is the first place to look after a red board.
GATES_LOG_DIR="${GATES_LOG_DIR:-/tmp/gates-logs}"
mkdir -p "$GATES_LOG_DIR" 2>/dev/null && rm -f "$GATES_LOG_DIR"/*.log 2>/dev/null || true


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

# -- THE TIER LADDER -----------------------------------------------------------
#
# CUMULATIVE: a tier runs every gate at its level and below. Adding the lower tiers
# therefore falsified no existing "QUICK tier" label anywhere in the docs — they are
# subsets, not a re-shuffle.
_level() {
    case "$1" in
        static) echo 1 ;;
        fast)   echo 2 ;;
        quick)  echo 3 ;;
        full)   echo 4 ;;
        daily)  echo 5 ;;
        *)      echo 99 ;;
    esac
}

# How many gates THIS FILE registers at a tier. The expectation below is derived from
# the script's own text, so adding or removing a gate cannot leave a stale constant
# behind -- the same self-calibrating property the RAN-N-OF-M check has always had,
# now per-tier because the tiers are what select gates.
_count_tier() { grep -cE "^[[:space:]]*(run|pin)_$1 \"" "$0"; }

MODE="quick"
case "${1:-}" in
    --static) MODE="static" ;;
    --fast)   MODE="fast" ;;
    --full)   MODE="full" ;;
    --daily)  MODE="daily" ;;
    --list)
        # Print the whole leading comment block, however long it grows — a fixed
        # line range silently truncated the header (and then leaked shell code
        # into --list) the first time a gate was added.
        sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
        # THE COUNTS ARE COMPUTED, NEVER WRITTEN DOWN. The header used to carry a
        # hand-maintained "there are N gates in the QUICK tier" sentence; it once said
        # seven while twelve were registered. A number in prose has no referent, and the
        # doc-gen oracle attached to that one had NEVER RUN -- doc_lint scans *.md and
        # docs/*.md, not .sh. Deriving the counts here removes the claim instead of
        # instrumenting it.
        echo "TIERS (cumulative — each runs everything below it):"
        printf '  %-8s %5s %11s\n' "TIER" "GATES" "CUMULATIVE"
        _cum=0
        for _t in static fast quick full daily; do
            _n=$(_count_tier "$_t"); _cum=$(( _cum + _n ))
            printf '  %-8s %5d %11d\n' "$_t" "$_n" "$_cum"
        done
        exit 0 ;;
    "" ) ;;
    * ) echo "gates.sh: unknown option '$1' (try --static, --fast, --full, --daily or --list)" >&2; exit 2 ;;
esac

MODE_LEVEL=$(_level "$MODE")

JOBS="${JOBS:-2}"
FAILED=()
PASSED=0
PINNED=0

# _run <tier> <label> <expected-substring-on-success> <command...>
#
# Call it through the run_<tier> wrappers below, never directly: the wrapper name is what
# `_count_tier` greps for, so a gate invoked any other way would RUN without being
# EXPECTED -- and the RAN-N-OF-M check would then report a mismatch blaming the wrong
# side. One registration form, one oracle.
#
# Prints the label BEFORE running and streams to a per-gate log, so a hang is
# visible immediately instead of after the fact. The first version captured with
# command substitution and printed only on completion — which meant a gate that
# hung looked exactly like a gate that was working, for 32 minutes. Also applies
# a per-gate timeout so a hang FAILS instead of blocking the suite forever.
_run() {
    local gate_tier="$1"; shift
    local label="$1"; shift
    local expect="$1"; shift
    # BELOW-TIER GATES DO NOT RUN AND ARE NOT COUNTED. Both halves matter: the
    # expectation is derived from the same tier tags, so a filter bug that skips a gate
    # surfaces as RAN N OF M rather than as a smaller, plausible-looking green board.
    [[ $(_level "$gate_tier") -gt $MODE_LEVEL ]] && return 0
    local out rc log t0 t1
    log="$(mktemp -t gate-XXXXXX)"
    t0=$SECONDS
    # Announce BEFORE running and leave the line open, so an in-progress gate is
    # visibly in progress. stderr so it survives a caller piping stdout.
    printf '  %-16s ...' "$label" >&2
    # CEILING RAISED 2700 -> 5400 on 2026-08-26, from measurement rather than comfort.
    # Two DIFFERENT gates hit 2700 s in two days, both on an IDLE machine, both passing
    # when run alone: `smoke` (08-23) and `divergence` (08-26). Standalone divergence then
    # measured 2467 s against a history of 1454-1813 s -- 8.6% of headroom, which the
    # tier's own load is enough to erase.
    #
    # The gates that grew are the zig-build-heavy ones (output_sweep 1016->1719,
    # full_sweep 726->1251, divergence 1491->2467) while `smoke`, which shells out least,
    # got FASTER in the same run. So this is not a machine-wide slowdown, and 5400 is not a
    # guess at one: it is ~2x the slowest observed run, the same ratio 2700 gave back when
    # the heavy gates ran ~1400 s.
    timeout "${GATE_TIMEOUT:-5400}" "$@" >"$log" 2>&1; rc=$?
    t1=$((SECONDS - t0))
    out="$(cat "$log")"
    # KEEP THE FULL OUTPUT OF A FAILING GATE. The board shows 8 failing lines and a
    # 12-line tail; a regression list longer than 12 is CUT, and what survives is the
    # alphabetical END of it -- which reads as a pattern ("the u..z tests broke") when it
    # is an artefact of the cut. On the 2026-09-12 CI full run that was the only evidence
    # left of full_sweep and examples_sweep, and it was the wrong evidence. Same rule as
    # zig_build_lib: a gate that classifies a failure must keep the failure's own account.
    if [[ $rc -ne 0 ]]; then
        mkdir -p "$GATES_LOG_DIR" 2>/dev/null && cp "$log" "$GATES_LOG_DIR/$label.log" 2>/dev/null || true
    fi
    rm -f "$log"
    printf '\r  %-16s ' "$label" >&2
    if [[ $rc -eq 124 ]]; then
        # "HANG" was the wrong word and it cost real diagnosis time: divergence was
        # killed at the ceiling while running FINE, and the board asserted it had hung.
        # A gate killed at its limit and a gate stuck in a loop are DIFFERENT claims, and
        # only one of them is knowable from here -- so state what is known and name the
        # discriminator instead of asserting the alarming reading.
        printf '\033[31mKILLED\033[0m at the %ss ceiling - SLOW or hung, this cannot tell which.\n' "${GATE_TIMEOUT:-5400}"
        printf '                   re-run it alone: a hang stays stuck, a slow gate finishes.\n'
        FAILED+=("$label(killed-at-ceiling)")
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
    local ok=0
    if [[ $rc -eq 0 ]] && { [[ -z "$expect" ]] || echo "$out" | grep -qF "$expect"; }; then ok=1; fi
    # A PINNED gate is one known to be RED, with a ticket. It still RUNS and is still
    # PRINTED -- the alternative (leave it out of every tier and write a paragraph asking
    # someone to remember) is what let `zig build test` sit broken for months (BUG-279)
    # and what let node-addon regress unnoticed between 2026-08-04 and 08-19. And it
    # FAILS THE TIER WHEN IT STARTS PASSING, because a pin that has come good is a
    # registration nobody updated -- the same signal an @boundary-pending probe gives.
    if [[ -n "${_PIN_TICKET:-}" ]]; then
        if [[ $ok -eq 1 ]]; then
            printf '\033[31mPIN OK\033[0m %-58s %ss\n' "PASSES now — retire the pin ($_PIN_TICKET)" "$t1"
            FAILED+=("$label(pin-now-passes)")
        else
            printf '\033[33mXFAIL\033[0m %-58s %ss\n' "known red, pinned to $_PIN_TICKET" "$t1"
            PINNED=$((PINNED + 1))
        fi
        return
    fi
    if [[ $ok -eq 1 ]]; then
        printf '\033[32mPASS\033[0m  %-58s %ss\n' "${last:0:58}" "$t1"
        PASSED=$((PASSED + 1))
    else
        printf '\033[31mFAIL\033[0m  %-58s %ss\n' "${last:0:58}" "$t1"
        FAILED+=("$label")
        # THE FAILING LINES FIRST, then the tail. `tail -12` alone reliably HIDES the
        # answer for any gate whose output is long: smoke prints 335 PASS lines, so a
        # single failure scrolls past and the board shows twelve PASSes underneath the
        # word FAIL. Observed 2026-08-15 — a smoke fixture failed in-tier, passed on
        # rerun, and could not be NAMED because the runner had dropped it. A gate that
        # reports a failure without saying which is one investigation longer than needed.
        echo "$out" | grep -aiE '^[[:space:]]*(FAIL|✗|error:)' | head -8 | sed 's/^/      ! /'
        echo "$out" | tail -12 | sed 's/^/        /'
        [[ -f "$GATES_LOG_DIR/$label.log" ]] && printf '        (full output kept: %s, %s lines)\n' "$GATES_LOG_DIR/$label.log" "$(wc -l < "$GATES_LOG_DIR/$label.log" | tr -d ' ')"
    fi
    # NEAR-CEILING WARNING. The runner knew divergence had taken 91% of its ceiling and
    # said nothing until the run that failed -- the first signal was the loudest one, with
    # no warning shot. UNGIT "nothing withheld": surface it while the gate is still GREEN.
    local _ceil=${GATE_TIMEOUT:-5400}
    if [[ $t1 -gt $(( _ceil * 80 / 100 )) ]]; then
        printf '  \033[33m!!\033[0m    %s took %ss of the %ss ceiling (>80%%) - raise it or split the gate\n' \
               "$label" "$t1" "$_ceil"
    fi
}

run_static() { _PIN_TICKET=""; _run static "$@"; }
run_fast()   { _PIN_TICKET=""; _run fast   "$@"; }
run_quick()  { _PIN_TICKET=""; _run quick  "$@"; }
run_full()   { _PIN_TICKET=""; _run full   "$@"; }
run_daily()  { _PIN_TICKET=""; _run daily  "$@"; }
# pin_<tier> <label> <ticket> <expect> <cmd...> -- a gate KNOWN to be red, with a ticket.
pin_daily()  { local l="$1" t="$2"; shift 2; _PIN_TICKET="$t"; _run daily "$l" "$@"; _PIN_TICKET=""; }

# -- THE STATIC TIER IS ONLY HONEST IF ITS GATES REALLY NEED NO COMPILER ----------------
#
# --static claims its gates need no Zebra binary, and that claim decays silently: a lint
# that later grows an "emit this and check it" leg would still be REGISTERED as static,
# would fail confusingly on a tree with no build, and -- worse -- would measure a STALE
# compiler on a tree doctor would have refused, because --static downgrades doctor's
# refusal to a warning.
#
# So the boundary is re-derived on every run rather than remembered. This is the cheap
# half of the experiment that established it (hide zig-out/bin/zebra*.exe, run the
# candidates, watch two controls refuse); the hiding experiment remains the stronger
# control and is the right thing to re-run by hand when adding a static gate.
_static_purity_check() {
    local pat='zig-out|zebra(-bootstrap)?\.exe|zig build'
    # CONTROL FIRST: a known build-dependent tool MUST trip the detector. Without this, a
    # broken pattern reports every gate pure -- the reassuring answer, which is the
    # direction instrument failures always point.
    if ! grep -qE "$pat" "$REPO/tools/str_ownership_extract.py"; then
        echo "gates.sh: REFUSING - the static-purity control stopped firing." >&2
        echo "  tools/str_ownership_extract.py is build-dependent and must match; the" >&2
        echo "  detector is broken, so its verdict on the static tier means nothing." >&2
        exit 2
    fi
    local impure="" line tool
    while read -r line; do
        tool=$(echo "$line" | grep -oE '(tools|fuzz)/[A-Za-z0-9_]+\.(py|sh)' | tail -1)
        [[ -z "$tool" ]] && continue
        grep -qE "$pat" "$REPO/$tool" && impure="$impure $tool"
    done < <(grep -E '^[[:space:]]*(run|pin)_static "' "$0")
    if [[ -n "$impure" ]]; then
        echo "gates.sh: REFUSING - gate(s) registered as static reference the compiler:$impure" >&2
        echo "  Either move the registration to run_fast, or the --static tier is lying" >&2
        echo "  about needing no build (and doctor's refusal is being downgraded for it)." >&2
        exit 2
    fi
}
_static_purity_check

# Preflight: a gate result is only meaningful if it measured the right compiler.
# doctor exits 1 on states that make results LIE (chiefly stale generated .zig,
# i.e. you would be testing the OLD compiler — see BUG-210).
#
# --static IS THE ONE EXCEPTION, and it is a deliberate choice rather than an oversight.
# Everything doctor refuses for is about the BINARY being wrong or unbuildable, and no
# static gate reads the binary -- which is not an assertion here, it is what
# _static_purity_check has just finished verifying, with a control. Refusing would deny
# the fast tier exactly when it is most useful (mid-edit, generated .zig stale, nothing
# rebuilt yet), which is the state a doc or tools/ change leaves the tree in every time.
#
# The warning is printed LOUDLY rather than swallowed: a downgrade nobody sees is how a
# refusal turns into a habit of ignoring it.
if ! bash "$SCRIPT_DIR/doctor.sh" >/tmp/gates-doctor.log 2>&1; then
    if [[ "$MODE" == "static" ]]; then
        echo "gates.sh: WARNING — doctor says this tree cannot be trusted for BUILD results:" >&2
        grep -E "WRONG" /tmp/gates-doctor.log >&2 || tail -5 /tmp/gates-doctor.log >&2
        echo "  Continuing anyway: no --static gate reads the compiler (purity-checked above)." >&2
        echo "  Any tier above static WILL refuse until this is fixed — run: bash tools/doctor.sh --fix" >&2
        echo >&2
    else
        echo "gates.sh: refusing to run — the tree is in a state where results cannot be trusted:" >&2
        grep -E "WRONG" /tmp/gates-doctor.log >&2 || cat /tmp/gates-doctor.log >&2
        exit 1
    fi
fi

echo "gates: $MODE (JOBS=$JOBS)"
bash "$SCRIPT_DIR/sysload.sh" 2>/dev/null | sed 's/^/  /'
echo

run_static "interp-escape"  "0 hazard"  python tools/lint_interp_escape.py
run_static "fallthrough"    "0 hazard"  python tools/lint_fallthrough.py
# The only gate aimed at OUR OWN TOOLING rather than at Zebra code. Five bugs in
# tools/mutation_check.py in two days, none of which crashed or exited non-zero -- every
# one produced a plausible wrong number and two were published. It refuses to report
# clean if its own controls stop firing, and `--rev <sha>` re-derives what it would have
# said on the commit that shipped the bugs.
run_static "hazard-lint"    "0 hazard"  python tools/hazard_lint.py
# The docs' CHECKABLE claims. Most of what they assert needs a human; the machine-checkable
# minority is the part that rots fastest, because it is exactly what changes when a tool is
# renamed or retired. Append-only records (BUGS.md, the journal) are reported but not gated
# -- an old entry naming a since-deleted tool is accurate history, not a defect.
run_static "doc-lint"       "0 stale"   python tools/doc_lint.py --quiet
run_static "keyword-coverage" "0 NEW"  python tools/lint_keyword_coverage.py
run_fast "doc-example"    "0 NEW"     python tools/doc_example_check.py --quiet
# The parser's rule table is the authority; grammar.txt is generated from it. Before
# 2026-08-04 the two had drifted badly enough that fuzz/gramgen.py -- which reads
# grammar.txt -- was generating 9 constructs the parser does not have and never reaching
# 40 that it does.
run_static "grammar-export" "matches"    python tools/grammar_export.py --check
# The STABLE SURFACE (keywords, CLI, namespaces + static members, builtin receiver methods),
# derived from the compiler's own tables into docs/SURFACE.md. Same shape as grammar-export:
# the compiler is the authority, the document is generated, and a diff is a surface change
# that needs a deliberate --write. This is the 1.0 stability promise as a gate (2026-09-14).
run_static "surface-freeze" "matches"    python tools/surface_inventory.py --check

# BUG-279: the ZIG-side test binaries (unit + integration), which were in NO tier and
# NOT in CLAUDE.md's uncovered table either -- the one state that table exists to make
# impossible. Three unrelated failures sat on committed code as a result, and two of
# them were hiding STALE TESTS asserting removed syntax.
#
# Deliberately NOT `zig build test`, which is a SUPERSET: it also runs selfhost_smoke
# (~14 min) and compile_check (~6 min), both already gated here, so the command would
# cost ~20 minutes of duplication to buy ~4 seconds of new coverage. `test-zig` is the
# uncovered part alone. escape_hatches joins it once BUG-279 leg 3 clears.
run_fast "zig-test"       "tests passed"  bash tools/zig_test_check.sh
run_quick "smoke"          "passed"    bash tools/selfhost_smoke.sh
run_quick "round-trip"     "PASS"      bash tools/bootstrap_check.sh
# The only gate that RUNS emitted output, hence the only one that can see BUG-221 —
# and the only one that would notice if the default silently stopped being the split
# runtime, since every other gate is happy either way.
run_fast "runtime-module" "all checks pass" bash tools/runtime_module_check.sh
# #4: `-c` is front-end-only and deliberately incomplete. This gates the CONTRACT —
# that valid code passes both modes, a front-end error fails both, and the asymmetry
# --help promises ACTUALLY EXISTS (witnesses that pass -c and fail --check-full).
# It also guards the speed, so `-c` silently starting to invoke zig again fails here.
run_fast "check-mode"     "all checks pass" bash tools/check_mode_check.sh
# BUG-266: the last link in the FFI chain — a `use` resolving to a PREBUILT library
# (.lib/.a), which is the shape a real third-party dependency actually takes. No
# compile-only gate can witness this: they build with -fno-emit-bin and never link, so
# an extern that resolves to nothing passes them. Builds its own library at check time
# rather than committing a binary to the corpus, and carries a negative control (remove
# the library, the value must stop appearing) so a pass cannot be incidental.
run_fast "ffi-lib"        "checks pass"     bash tools/ffi_lib_check.sh
run_fast "bug302-control" "all legs pass"  bash tools/bug302_infra_retry_check.sh
# The walker-drift gate. A function searching the Expr tree for a name is only correct
# if it descends into every variant that HOLDS expressions; miss one and it silently
# answers "not used" for a whole construct, which surfaces as a Zig error in code the
# user wrote correctly (BUG-260, BUG-267). This class was declared retired once already
# by hand ("BUG-169 retirement") and came back twice, because the failure is not
# forgetting a variant — it is writing down that a variant holds nothing. The oracle is
# Ast.zbr itself, so the answer is derived rather than remembered.
# NOTE the expectation is "0 finding" and that is a count PREFIX — sound only because
# the tool exits non-zero under --gate when findings exist (see run()'s warning above).
run_static "expr-walker"    "0 finding"       python tools/lint_expr_walkers.py --gate
# Two agents allocate bug numbers from the same ledger, and collided TWICE on
# 2026-08-06 (BUG-260, BUG-269). doc_lint D4 cannot see it: it checks that a cited
# BUG-NNN RESOLVES, and a duplicate resolves twice over — so a collision leaves D4
# more satisfied, not less. Also gates the allocator line, because a "Last bug number"
# that lags is not a stale fact, it is the NEXT collision already scheduled.
run_static "bug-numbers"    "0 NEW"           python tools/lint_bug_numbers.py --gate
# A reserved word costs every user the right to name a thing with it, and that cost is
# invisible until someone hits it — at which point it looks like a compiler bug. `aspect`
# sat reserved for a feature that was never built, blocking a real DB column name and
# forcing a keyword-rename shield in another project, until 2026-08-09. The audit that
# found it also turned up `expect` and `lock`, which nobody had flagged, and cleared
# `cue`/`vari`, which had been guessed at — two guesses wrong in opposite directions,
# which is the argument for a lint over a memory. Baselined; fails only on NEW words.
run_static "reserved-words" "0 NEW"           python tools/lint_reserved_words.py --gate
# The mirror image of reserved-words: a word Zebra does NOT reserve but ZIG does
# (align, volatile, opaque, packed, noalias, anyframe). The user may legally name a
# field with one, so codegen has to escape it as @"name" on the way out. emitName
# always did; the FIELD paths never called it, and nine emit sites were involved —
# five of which reading the source did not find. Emits the fixture and reports any
# keyword left BARE outside a string literal, which needs no allow-list: an
# allow-list here would be the same hand-maintained oracle that caused the bug.
# Its coverage IS the fixture — see BUG-281, where it passed the bootstrap while
# three further emit families were broken in it.
run_fast "keyword-ident"  "escaped in every" bash tools/keyword_ident_check.sh
# And the ORACLE behind keyword-ident: `isZigKeyword` decides which words get escaped,
# it exists twice (bootstrap + selfhost), and both copies were hand-written. The receipt
# is not the 12 keywords they were missing — every one of those is also a Zebra keyword,
# so nothing was reachable. It is the 3 they still carry that Zig 0.16 no longer HAS
# (async, await, usingnamespace): the list already drifted across a version bump with
# nothing noticing. Compares both copies against Zig's own std/zig/tokenizer.zig table,
# found through `zig env`. The only gate here that reads the Zig INSTALLATION, so it
# prints the version it judged against.
run_static "zig-keywords"   "cover all"        python tools/lint_zig_keywords.py
# A diagnostic that cannot say WHERE is delivered half-finished, and `file:8:0` is not
# "unknown" -- it is a plausible coordinate that is simply wrong, defeats caret rendering,
# and sends an editor to the wrong place. THREE bugs of exactly this shape were fixed in
# two days (BUG-284 zig literals, BUG-249 this/nil/result, BUG-121 checkExpr) and every
# one was found by a person reading output: a golden-output gate does not assert positions
# and a compile gate cannot see them. Candidate set DERIVED from the smoke suite's own
# must-fail registrations; baselined, so only NEW position-less diagnostics fail.
run_fast "diag-columns"   "0 NEW"           python tools/lint_diag_columns.py
# §28e: docs/design/str_ownership.md is DERIVED from real emit, so a codegen change that flips
# a borrow into an own (or the reverse) makes the shipped table wrong while it still
# carries a "GENERATED" banner vouching for it. One emit; cheap.
run_fast "str-ownership"  "is current" python tools/str_ownership_extract.py --check
# A1 (testing_strategy.md): SQLite's "a regression test for every reported bug", as a lint
# rather than a habit. Fails only on NEW debt — the backlog is baselined — and counts a
# fixture as real only if something actually RUNS it. Static; instant.
run_static "bug-fixture"    "gate PASS" python tools/bug_fixture_check.py --gate
# BUG-243: a corpus file that nothing registers AND that has never been sweep-clean
# is invisible to every gate -- full_sweep baselines the pass set, so a file that has
# never passed cannot make it red. Fifteen files were found in that state, two of them
# regression fixtures that had never run. Baselined like bug-fixture: fails on NEW debt.
run_static "registration"   "0 NEW"    python tools/registration_check.py
# A4: `unreachable` is UB in ReleaseFast, which is what `zebra --release` ships. Every
# gate here runs Debug, where it traps cleanly — so this hazard is invisible to all of
# them and live only in what users distribute. A static lint is the only witness.
run_static "oom-unreachable" "0 hazard" python tools/lint_oom_unreachable.py
# The section-drift lint (refuter, 2026-09-09): every `.@"fn"` dispatch line in a GUI
# section must have a byte-identical twin in the preamble. Three copies of one dispatch
# had drifted twice before anyone wrote the one-line check.
run_static "fn-twins"       "0 drift"  python tools/lint_fn_twins.py
run_static "root-clean"     "0 compiled" bash tools/root_clean_check.sh
run_static "decl-exhaustive" "0 issue" python tools/lint_decl_exhaustive.py
# A3: the boundary-value suite. The ONLY gate here whose expectations were written from
# INTENT rather than recorded from behaviour — output_sweep is a golden baseline and so
# can never find something that was wrong on day one. 33 probes, ~30s, and it found  <!-- doc-gen: 33 = bash tools/corpus_ls.sh test/boundary | wc -l | tr -d ' ' -->
# BUG-230/231/232 on its first run. Probes marked @boundary-pending pin known-broken
# behaviour deliberately and will FAIL when their ticket is fixed; that is the signal to
# rewrite them, not to re-baseline.
run_fast "boundary"       "0 fail"   bash tools/boundary_check.sh
run_fast "stream-sep"     "PASS"     bash tools/stream_check.sh
run_fast "cli-surface"   "PASS"     bash tools/cli_check.sh
run_fast "lsp-smoke"     "passed"   python tools/lsp_server_smoke.py
# `zebra lsp` sees the `use` graph (modules a document uses + same-dir dependents) from
# disk, not only open documents -- references / definition / rename across files with
# ONE file open. Found by zebra-ide's rename_workspace_test, 2026-09-08.
run_fast "lsp-workspace" "passed"   python tools/lsp_workspace_smoke.py
run_fast "debug-map"     "passed"   bash tools/debug_map_check.sh

# THE ONLY GATE THAT BUILDS WITH --release. Every other gate here is Debug, which is
# how BUG-228 survived 19 green gates: `--release` switched backend but never passed
# an optimize flag, so users shipped Debug believing otherwise.
run_full "release-mode"   "all checks pass" bash tools/release_mode_check.sh
run_full "contract-mode"  "checks pass" bash tools/contract_mode_check.sh
# A Zebra shared library loaded by a Zebra host (QUICKSTART §44): `zebra --shared`, then
# DynLib.open + lookup from a Zebra host. Pinned red as BUG-356 from 2026-09-08 until the
# fix landed 2026-09-09 (the "garbage fat pointer" was ElfDynLib skipping relocations on a
# host built without libc) — the pin did its job: it was the first thing to go green.
run_full "dynlib-roundtrip" "PASS" bash tools/dynlib_roundtrip_check.sh
# compile_check (DEFAULT runtime shape) was REMOVED from this tier 2026-08-19 —
# its property now rides on full_sweep, which was already doing the identical work.
#
# MEASURED, not assumed: compile_check's positive set (276 after skips) is a strict
# SUBSET of full_sweep's corpus (499) with ZERO unique entries, and both run the same
# `zig build-exe -fno-emit-bin -lc` over the same selfhost emit. The tier was emitting
# and compiling those 276 files TWICE, for ~8 minutes.
#
# THE TWO GATES DIFFERED IN KIND, NOT JUST CORPUS, which is why this was not a plain
# deletion: full_sweep is RELATIVE (regression vs a baseline, so a file outside the
# baseline cannot make it red) and compile_check is ABSOLUTE (0 FAILED over the
# positive set). Dropping it alone would have traded an absolute guarantee for a
# relative one. full_sweep now asserts BOTH and prints both numbers.
#
# compile_check remains the manual tight-loop tool it is documented as (`--only`),
# and its --no-runtime-module twin STAYS here: that shape is genuinely unwatched
# elsewhere.
# The same corpus with the INLINE runtime. Since 2026-07-28 the split runtime is
# the DEFAULT, so this is the mode that would otherwise go unwatched — and it is
# still live: --no-runtime-module selects it, and the GUI and node-addon paths
# fall back to it.
run_full "compile_check-inline" "0 FAILED" env JOBS="$JOBS" bash tools/compile_check.sh --no-runtime-module
# THE BEHAVIOUR GATE, and the only heavy one that RUNS anything. Every other gate in
# this tier asks "does the emitted Zig compile?", so valid Zig producing the WRONG
# OUTPUT is invisible to all of them at any corpus size — BUG-226 is the receipt.
# Golden baseline: it catches REGRESSIONS against recorded behaviour, not existing
# wrongness. Sequential by design; parallel runs would let fixtures interfere and a
# flaky behaviour gate is one people learn to re-baseline without reading.
run_full "output_sweep"  "identical to baseline" bash tools/output_sweep.sh --gate
run_full "full_sweep"    "gate PASS" env JOBS="$JOBS" bash tools/full_sweep.sh --gate
# A5: the SAME sweep over examples/*.zbr, which no gate touched until 2026-07-30.
# examples/widget_smoke.zbr shipped BROKEN on BUG-230 and nothing noticed, because
# every other heavy gate globs test/*.zbr and `zebra -c` is front-end-only so the
# obvious spot-check exits 0. Small corpus, ~90s. Buckets that are NOT gated are
# NAMED in its output rather than counted, because on examples/ each one is a
# question worth answering.
run_full "examples_sweep" "gate PASS" env JOBS="$JOBS" bash tools/full_sweep.sh --examples --gate
run_full "divergence"    "gate PASS" env JOBS="$JOBS" bash tools/divergence_check.sh --gate

# -- DAILY: the set that was excluded from every tier until 2026-08-19 -----------------
#
# These three were listed under "HONEST LIMITS -- run those deliberately", which is a
# paragraph asking a person to remember. The record shows how well that works: this file
# recorded their last sweep as 2026-08-04, and on 2026-08-19 node-addon turned out to
# have regressed at some point in between, with nothing reporting it.
#
# They stay OUT of --full, so "gates green" keeps the precise meaning the exclusion was
# for. What changes is that they now have a NAME and a CADENCE instead of a reminder.
#
# The parser's only fuzz coverage: 960 deterministic grammar-derived programs, gated on
# HANGS and CRASHES (accept/reject divergences are expected and are not failures). It
# would have caught BUG-199 -- an 18-byte parser infinite loop -- automatically.
run_daily "selfhost-div" "PASS" bash tools/selfhost_divergence_check.sh
run_daily "gramgen"      "gate PASS" python fuzz/gramgen.py --gate
# THE "ZEBRA ACCEPTS, ZIG REJECTS" FUZZER (2026-09-09): gen.py's well-formed programs,
# emitted by the selfhost, sema'd by zig. Any leak signature not in fuzz/leak_baseline.txt
# fails. Its first 3,000 programs found seven codegen bugs (BUG-360..366) that no
# hand-written fixture had reached. Carries a positive control (the BUG-354 shape).
run_daily "leakgen"      "gate PASS" python fuzz/leakgen.py --gate
# Startup-only GUI coverage. Four GUI crashes have sat under fully green gates and all
# four were at STARTUP, which needs neither a human nor a terminal to detect. Rendering,
# input, layout, resize and colours remain provable only by a human running the app.
#
# READ ITS LEG 2 LINE, DO NOT ASSUME IT RAN — BUG-298. Leg 2 (run the built app) SKIPS
# when it finds no app.exe, and a build that FAILED produces exactly that state, so the
# gate can print "startup path clean" having asserted only leg 1 against a scaffold left
# on disk by an earlier run. Observed here on 2026-08-19 (a corrupted scratch cache).
# Until that is fixed, a green line from this gate means "leg 1 clean", not "the app
# starts".
run_daily "gui-scaffold" "startup path clean" bash tools/gui_scaffold_check.sh
# BUG-358: a view() with a closure-taking builder (`g.panel`) re-runs per frame; the
# counter example has none, so it could never see the 65th-frame death. Leg 2 of this
# run renders far more than 64 frames headless.
run_daily "gui-scaffold-panel" "startup path clean" bash tools/gui_scaffold_check.sh examples/panel_smoke.zbr
# BUG-340/343/355/357: a GUI program built from MORE THAN ONE MODULE (deps emitted beside
# the scaffold, a used module named `sci`, a CodeEditor across the boundary, sys.args()
# in the used module). Neither counter nor panel_smoke has a `use`, so nothing in this
# repo ran that shape until 2026-09-09 -- zebra-ide's model_test did, one repo over.
run_daily "gui-scaffold-modules" "startup path clean" bash tools/gui_scaffold_check.sh examples/gui_modules_smoke.zbr
# THE GUI-BACKEND WITNESS WITHOUT WINDOWS (2026-09-07; registered 2026-09-09 -- it had
# been run by hand and by zebra-ide's check.sh only): the libui_ng project for six
# examples, `zig build-obj -fno-emit-bin` against the REAL zig-libui-ng bindings, plus
# the private-decl lint over the pub-marked section. Needs the bindings on disk
# (C:\Projects\zig-libui-ng\src on the laptop; LIBUI_BINDINGS= elsewhere) -- it
# refuses, not passes, without them.
run_daily "libui-section" "examples compile" bash tools/libui_section_check.sh
# PINNED: known red, BUG-297. `zebra --target node-addon` on a class STATIC-block export
# emits a reference to the owning class that is never declared. It is REGISTERED rather
# than excluded precisely because exclusion is what let it rot unnoticed -- and it fails
# this tier the day it starts passing, so the pin cannot outlive the bug.
# BUG-297 fixed 2026-08-25, so the pin is retired -- gates.sh FAILS the tier when a
# pinned gate starts passing, on the principle that a pin which has come good is a
# registration nobody updated. Note the expectation also changed: the pin carried
# "node-addon tests: ok", which the gate has NEVER printed (it prints PASS). The
# XFAIL was masking a stale match string, so retiring the pin without fixing it
# would have turned the gate red on the expectation rather than on the code.
run_daily "node-addon"   "node-addon tests: PASS" bash tools/node_addon_test.sh
# -- Did every gate actually RUN? ---------------------------------------------
#
# The summary used to print "$PASSED/$PASSED PASS" -- both numbers the same, which is a
# tautology rather than a check. A gate that silently stopped running (a `run` line removed,
# an early exit, a conditional that skipped it) produced "21/21 PASS" and looked healthy.
#
# Credit: found by applying Fable's false-green taxonomy (wiki concept_false-green-taxonomy,
# 2026-08-04) to this file. Its finding is that every false green presents as an ABSENCE
# rather than a wrong value, and its check is "count what SHOULD have reported, and
# compare". A green result is a claim about what was FOUND; it is not a claim that anything
# ran.
#
# SELF-CALIBRATING: the expectation comes from this script's own registrations, so adding
# or removing a gate cannot leave a stale constant behind.
#
# IT USED TO DEPEND ON INDENTATION. The FULL gates lived inside an `if` block and the
# expectation was derived by counting `run "` lines above and below it -- so the tier
# boundary was expressed as WHITESPACE. Dedenting that block (which the tier filter made
# redundant) would quietly have made the QUICK expectation equal the FULL one. Tagging
# each gate with its tier at the call site replaces a structural property with a written
# one, and the same tags feed both the filter and this count.
_expected=0
for _t in static fast quick full daily; do
    [[ $(_level "$_t") -le $MODE_LEVEL ]] && _expected=$(( _expected + $(_count_tier "$_t") ))
done
# VACUITY FLOOR. The derivation above is textual, so a pattern that stopped matching -- a
# renamed wrapper, an edited quote -- would yield 0 expected, 0 actual, and a "0/0 PASS"
# board that exits 0. Every tier includes at least the static twelve, so anything under
# ten means the counter broke, not that the gates went away.
if [[ "$_expected" -lt 10 ]]; then
    printf '\033[31mgates: REFUSING - expected only %d gates for the %s tier\033[0m\n' \
           "$_expected" "$MODE" >&2
    printf '  The expectation is derived from this file own run_<tier> lines; a count\n' >&2
    printf '  this low means that derivation broke. A gate suite that cannot say how many\n' >&2
    printf '  gates it should have run must not report a result.\n' >&2
    exit 2
fi
# Pinned gates RAN -- they are neither passes nor tier failures, but they must be counted
# here or the RAN-N-OF-M check would report them as gates that never executed.
_actual=$(( PASSED + ${#FAILED[@]} + PINNED ))
if [[ "$_actual" -ne "$_expected" ]]; then
    printf '\033[31mgates: RAN %d OF %d -- %d gate(s) never executed\033[0m\n' \
           "$_actual" "$_expected" "$(( _expected - _actual ))" >&2
    printf '  A gate that does not run reports nothing, and nothing looks like success.\n' >&2
    printf '  Ran: %d passed, %d failed. Expected %d for the %s tier.\n' \
           "$PASSED" "${#FAILED[@]}" "$_expected" "$MODE" >&2
    exit 1
fi

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
    printf '\033[32mgates: %d/%d PASS (%s)\033[0m\n' "$PASSED" "$_expected" "$MODE"
    [[ $PINNED -gt 0 ]] && printf '  %d pinned gate(s) XFAILed as expected - see the ticket(s) above.\n' "$PINNED"
    # NAME WHAT THIS TIER DID NOT LOOK AT. A green board is a claim about what was FOUND,
    # and on a lower tier the more important fact is what was never examined -- otherwise
    # the ladder becomes a way to get a green cheaply rather than a way to spend the right
    # amount of time.
    case "$MODE" in
        static) echo "  (static tier — NOTHING here built, emitted or ran the compiler." ;
                echo "   It cannot see a miscompile, a crash or a wrong answer. Next: --fast, ~2.5 min)" ;;
        fast)   echo "  (fast tier — smoke and round-trip did NOT run: no fixture was executed and" ;
                echo "   the compiler was never round-tripped. Next: the default tier, ~14 min)" ;;
        quick)  echo "  (quick tier — the corpus was never swept; run --full before committing a codegen change)" ;;
        full)   echo "  (full tier — the three --daily gates were not run; GUI rendering is uncovered by both)" ;;
        daily)  echo "  (daily tier — GUI rendering, input, layout, resize and colours are STILL uncovered:" ;
                echo "   only a human running the app proves those.)" ;
                echo "  Record it in CLAUDE.md: DAILY tier $(date +%Y-%m-%d): $PASSED/$_expected PASS, $PINNED pinned." ;;
    esac
    exit 0
else
    printf '\033[31mgates: %d FAILED — %s\033[0m\n' "${#FAILED[@]}" "${FAILED[*]}"
    exit 1
fi
