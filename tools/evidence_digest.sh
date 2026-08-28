#!/usr/bin/env bash
# THE EVIDENCE READER. Report only — it fails nothing.
#
# The gates now KEEP the reason a file could not be emitted (BUG-302's lesson applied one
# layer up: 55 EMITFAILs per --daily run, every one previously sent to /dev/null). Keeping
# it is only half. Nothing read those files, so the board still said "EMITFAIL x55" and a
# reader had to know the directory existed, know which of the 55 mattered, and open them by
# hand. UNGIT "nothing withheld" is about the surface the user is ALREADY LOOKING AT.
#
# First run, 2026-08-26: 55 front-end refusals, 52 declared must-fail, 3 declared nowhere.
# That turned a bare number into three concrete actions — two exhaustiveness negatives that
# needed registering, and tc_merge_fixture, which holds git conflict markers and cannot
# compile standalone by construction.
#
# ── TWO KINDS OF EVIDENCE, AND CONFLATING THEM LIBELS WORKING FILES ──────────────────────
#   .emit.err               OUR compiler refused the SOURCE (front end).
#   .cfail.err / .fail.err  ZIG refused our EMITTED OUTPUT (back end).
#
# Only the first is something the smoke suite declares anything about. The first draft of
# this tool globbed all three together and reconciled the lot against the must-reject set,
# which named 33 files as "declared nowhere" — about thirty of them working files whose
# only sin was being a known back-end failure already tracked by full_sweep's baseline.
# A gate that libels a working file is one people learn to disbelieve.
#
# ── WHY IT RECONCILES BOTH DIRECTIONS ────────────────────────────────────────────────────
# The obvious design counts undeclared refusals. That number is 0 the moment the debt is
# cleared, and then this prints "N declared, 0 undeclared" forever — reading identically
# whether it works or whether the declared-lookup silently stopped matching. A tool that
# goes vacuous BY SUCCEEDING is the worst version: nobody is suspicious on the day the
# number improves.
#
#   A. declared must-reject, in the corpus, but produced NO evidence
#      -> A NEGATIVE TEST HAS STARTED PASSING. Nothing else here can see this. It is
#         pin_daily's logic applied to fixtures: the day a `smoke_tc_fail` fixture starts
#         compiling, its registration quietly stops asserting anything.
#   B. produced evidence, but declared by nothing  -> unasserted debt.
#
# A keeps a non-trivial denominator forever, which is what makes B's zero mean something.
#
# ── SCOPE, AND WHAT IS DELIBERATELY LEFT OUT ─────────────────────────────────────────────
# Reconciliation runs over full_sweep and examples_sweep only: one compiler, corpus-
# aligned. `divergence` emits with BOTH compilers into one evidence dir and its filenames
# do not record which one failed, so its population cannot be reconciled against a
# selfhost-side declaration. Its count is reported, unreconciled, rather than silently
# folded in or silently dropped.
#
# It does not gate. `registration_check.py` already fails on NEW unasserted files and owns
# that baseline; a second gate on the same debt is churn, and two gates disagreeing about
# one number is worse than one. Named in the output so nobody adds a second.
#
# It cannot tell whether a kept reason is USEFUL — only that one exists and who owns the
# file. Judging 55 reasons is a person's job; this says which ones to read.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
T="${TMPDIR:-/tmp}"

RECON_DIRS="$T/zebra_full_sweep/evidence $T/zebra_examples_sweep/evidence"
UNRECON_DIRS="$T/zbr-compile-check/evidence $T/zbr-divergence/evidence"

collect() {  # $1 = suffix; rest = dirs. Prints basenames.
    local sfx="$1"; shift
    local d f
    for d in "$@"; do
        [ -d "$d" ] || continue
        for f in "$d"/*."$sfx"; do
            [ -e "$f" ] || continue
            local b; b="$(basename "$f")"; echo "${b%%.*}"
        done
    done
}

ndirs=0
for d in $RECON_DIRS; do [ -d "$d" ] && ndirs=$((ndirs + 1)); done
if [ "$ndirs" -eq 0 ]; then
    echo "evidence-digest: no sweep evidence found — run full_sweep first."
    echo "  Nothing to read is not the same as nothing wrong."
    exit 0
fi

FRONT="$(collect emit.err $RECON_DIRS | sort -u)"
BACK="$(collect cfail.err $RECON_DIRS; collect fail.err $RECON_DIRS)"
BACK="$(printf '%s\n' "$BACK" | grep . | sort -u || true)"

MUST_REJECT="$(bash "$REPO/tools/must_reject_set.sh")" || {
    echo "evidence-digest: REFUSING — must_reject_set.sh would not report." >&2
    echo "  Without it every refusal looks undeclared: a loud false RED, but still a lie." >&2
    exit 2
}
# run_fail asserts only "must fail SOMEHOW" — it runs the whole compiler and checks for a
# non-zero exit, so a front-end refusal satisfies it just as a runtime error does (3 of the
# 8 registrations do in fact fail at compile time). So these are ACCOUNTED FOR in B without
# being REQUIRED in A. Demanding they refuse would invent a promise the suite never makes.
RUN_FAIL="$(grep -hoE '^smoke_run_fail[a-z_]*[[:space:]]+[^[:space:]]+\.zbr' tools/selfhost_smoke.sh \
            | sed -E 's/^[a-z_]+[[:space:]]+//; s#.*/##; s#\.zbr$##' | sort -u)"
EXEMPT="$(grep -vE '^\s*#|^\s*$' tools/registration_exempt.txt 2>/dev/null | awk '{print $1}' | sort -u)"
CORPUS="$(bash tools/corpus_ls.sh test | sed -E 's#.*/##; s#\.zbr$##' | sort -u)"

a_expected=0; a_missing=""
while IFS= read -r n; do
    [ -z "$n" ] && continue
    printf '%s\n' "$CORPUS" | grep -qx "$n" || continue
    a_expected=$((a_expected + 1))
    printf '%s\n' "$FRONT" | grep -qx "$n" || a_missing="$a_missing $n"
done <<EOF
$MUST_REJECT
EOF

b_declared=0; b_undeclared=""
while IFS= read -r n; do
    [ -z "$n" ] && continue
    if printf '%s\n' "$MUST_REJECT" | grep -qx "$n" \
    || printf '%s\n' "$RUN_FAIL"    | grep -qx "$n" \
    || printf '%s\n' "$EXEMPT"      | grep -qx "$n"; then
        b_declared=$((b_declared + 1))
    else
        b_undeclared="$b_undeclared $n"
    fi
done <<EOF
$FRONT
EOF

nfront=$(printf '%s\n' "$FRONT" | grep -c . || true)
nback=$(printf '%s\n' "$BACK" | grep -c . || true)

# EVIDENCE THAT CANNOT EXPLAIN ITSELF. A zero-byte file is a failure with no account of
# itself -- the exact state this whole programme exists to remove, arriving in the form of
# a file that LOOKS like evidence. Measured 2026-08-26: 0 of 74 in a healthy run, so this
# is a rare signal rather than noise, and it fired on the one occasion it mattered
# (char_literal_test, a non-reproducing CFAIL whose empty stderr immediately ruled out both
# an ordinary compile error and the BUG-302 stdlib class -- both of which WRITE something).
#
# Deliberately NOT "has no `error:` line": that is a format assumption, not a detector.
# bug247_nonascii_diag_test's kept reason reads `15:12: unexpected non-ASCII byte ...` and
# is a perfectly good diagnostic that never says "error:".
empty=""
for d in $RECON_DIRS $UNRECON_DIRS; do
    [ -d "$d" ] || continue
    for f in "$d"/*.err; do
        [ -e "$f" ] && [ ! -s "$f" ] && empty="$empty $(basename "$f")"
    done
done

echo "── evidence digest ──"
echo "  front-end refusals (.emit.err), reconciled:  $nfront"
echo "    declared must-reject and in the corpus:    $a_expected"
echo "    of those, produced NO evidence:            $(echo $a_missing | wc -w | tr -d ' ')"
if [ -n "$a_missing" ]; then
    echo "      ^ A NEGATIVE TEST HAS STARTED PASSING — its registration asserts nothing now:"
    for n in $a_missing; do echo "        $n"; done
fi
echo "    produced evidence, declared somewhere:     $b_declared"
echo "    produced evidence, declared NOWHERE:       $(echo $b_undeclared | wc -w | tr -d ' ')"
for n in $b_undeclared; do
    r=""
    for d in $RECON_DIRS; do
        [ -f "$d/$n.emit.err" ] && { r="$(grep -ho 'error: .*' "$d/$n.emit.err" 2>/dev/null | head -1)"; break; }
    done
    [ -z "$r" ] && for d in $RECON_DIRS; do [ -f "$d/$n.emit.err" ] && r="$(grep -v '^\s*$' "$d/$n.emit.err" | tail -1)"; done
    echo "        $n — ${r:-<evidence file is EMPTY>}"
done
[ -n "$b_undeclared" ] && echo "      ^ registration_check.py owns FAILING on these; this only names them."

nempty=$(echo $empty | wc -w | tr -d ' ')
echo "  evidence files that are EMPTY (no account at all): $nempty"
if [ "$nempty" -gt 0 ]; then
    echo "    ^ a failure with NO account of itself — the state kept evidence exists to remove."
    echo "      Rules out an ordinary compile error AND the BUG-302 stdlib class: both WRITE."
    for n in $empty; do echo "        $n"; done
fi
echo "  back-end refusals (zig rejected our output):  $nback"
echo "    NOT reconciled here — full_sweep's baseline owns which of these are regressions."
for d in $UNRECON_DIRS; do
    [ -d "$d" ] || continue
    c=$(ls "$d"/*.err 2>/dev/null | wc -l | tr -d ' ')
    [ "$c" -gt 0 ] && echo "  $(basename "$(dirname "$d")"): $c file(s) — not reconciled (mixes both compilers)"
done
exit 0
