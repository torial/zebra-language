#!/usr/bin/env bash
# full_sweep.sh — independent-witness over the WHOLE test corpus.
#
# compile_check.sh only checks the ~210 smoke-registered tests. This sweeps EVERY
# test/*.zbr: emit with the selfhost, then `zig build-exe -fno-emit-bin` the result.
# Buckets: PASS | CFAIL (emitted, bad Zig) | EMITFAIL (compiler-side, incl. negative
# tests) | NOMAIN (library module — no `pub fn main`).
#
#   bash tools/full_sweep.sh                    # report buckets
#   bash tools/full_sweep.sh --gate             # FAIL on regression vs the baseline
#   bash tools/full_sweep.sh --update-baseline  # re-baseline the current PASS set
#   bash tools/full_sweep.sh --examples [...]   # the SAME sweep over examples/*.zbr
#
# A5 (2026-07-30): `--examples` points the identical machinery at examples/*.zbr,
# which until then was swept by NO gate at all -- every heavy gate globs test/*.zbr.
# That hole was not theoretical: examples/widget_smoke.zbr SHIPPED BROKEN (BUG-230,
# found by the A3 boundary suite), and `zebra -c` exits 0 on it because check mode is
# front-end-only, so the obvious spot-check could not see it either. Both had to be
# true for it to go unnoticed. For a 0.9 whose claim is ready-for-others, the
# directory a newcomer opens first is worth a gate.
#
# Extending this tool rather than writing a sixth near-identical script is deliberate:
# the emit -> build-exe -> baseline-allow-list -> regress-only-gate logic is already
# proven here, and a copy would drift from it.
#
# The baseline (tools/full_sweep_baseline.txt) is the set of tests that currently
# emit+compile clean. `--gate` fails only if a baseline-passing test regresses to a
# failure — so known negatives / library / triage-backlog files need no skip-list,
# and the gate stays low-maintenance (re-baseline when the pass set intentionally
# grows, e.g. after fixing an emit bug). Heavy (~20-30 min); per-session / pre-release.
# pins: BUG-303 -- with --examples this sweep IS that bug's regression test. The defect was
# a GUI-path emit (a capture-lambda reaching a stdlib callback as a FUNCTION POINTER), and
# examples/ is the only corpus carrying one. panel_smoke went from broken to a locked-in
# baseline entry here; nothing under test/ can reach the path, because the closure-thunk
# route is only taken for stdlib callback consumers.
set -u
export PATH="/c/Users/Sean/.zvm/bin:$PATH"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
# shellcheck source=tools/zig_build_lib.sh
. "$REPO/tools/zig_build_lib.sh"
GATE=0; UPDATE=0; EXAMPLES=0
for a in "$@"; do case "$a" in
  --gate) GATE=1;;
  --update-baseline) UPDATE=1;;
  --examples) EXAMPLES=1;;
esac; done

# Corpus and baseline move TOGETHER, in one place. Split apart, the gate could be
# pointed at one corpus while comparing against the other's baseline -- which would
# report confident nonsense in both directions rather than failing.
if [ "$EXAMPLES" = 1 ]; then
  CORPUS_DIR="examples"; CORPUS_LABEL="examples-sweep (examples/*.zbr)"
  BASELINE="$REPO/tools/examples_sweep_baseline.txt"
  OUT="${TMPDIR:-/tmp}/zebra_examples_sweep"
else
  CORPUS_DIR="test"; CORPUS_LABEL="full-sweep (test/*.zbr)"
  BASELINE="$REPO/tools/full_sweep_baseline.txt"
  OUT="${TMPDIR:-/tmp}/zebra_full_sweep"
fi
rm -rf "$OUT"; mkdir -p "$OUT"

check_one() {
  local rel="$1"; local name; name=$(basename "$rel" .zbr)
  local wdir="$OUT/w-$name"; rm -rf "$wdir"; mkdir -p "$wdir"
  if ! timeout 40 "$ZEBRA" --emit-zig "$REPO/$rel" --output-dir "$wdir" >/dev/null 2>&1; then
    echo "EMITFAIL $name"; rm -rf "$wdir"; return
  fi
  local main="$wdir/$name.zig"
  if [ ! -f "$main" ] || ! grep -q "pub fn main" "$main"; then
    echo "NOMAIN $name"; rm -rf "$wdir"; return
  fi
  local berr="$wdir/build.err"
  # BUG-302: zig can fail because it could not read its OWN stdlib, which is not a
  # verdict on our emitted code. zbr_zig_build retries exactly that case and nothing
  # else; see tools/zig_build_lib.sh for the receipt.
  zbr_zig_build "$main" "$berr" 90
  local rc=$?
  [ "${ZBR_RETRIES:-0}" -gt 0 ] && echo "$name" >> "$OUT/retries.txt"
  if [ $rc -eq 0 ]; then
    echo "PASS $name"
  # A DEPENDENCY THAT WAS NEVER EMITTED IS NOT A BROKEN PROGRAM, and calling it one
  # is worse than not checking at all -- a gate that libels a working file is a gate
  # people learn to disbelieve. `--output-dir` emits SIBLING deps (verified: bug082_lib
  # lands next to bug082_test) but not deps resolved through a SEARCH PATH, so e.g.
  # examples/lsystem.zbr -- which runs correctly end to end -- emits an @import of a
  # math.zig that is never written. Bucketed separately and never gated.
  elif grep -q "unable to load .*FileNotFound" "$berr"; then
    echo "DEPMISS $name"
  elif zbr_zig_infra_error "$berr"; then
    # Survived all three tries. Still not a verdict on our code, so it must not be
    # counted as one -- but it is not a pass either, and it gets named loudly.
    cp "$berr" "$OUT/infra-$name.err" 2>/dev/null
    echo "INFRA $name"
  else
    echo "CFAIL $name"
  fi
  rm -rf "$wdir"
}
export -f check_one zbr_zig_build zbr_zig_infra_error; export ZEBRA OUT REPO

# TRACKED files only -- a filesystem glob makes this gate's result depend on whatever
# untracked scratch is lying around (see tools/corpus_ls.sh). Found 2026-08-01 with
# examples/zz_red_main.zbr sitting in the swept directory, untracked and invisible to
# anyone reading the commit.
bash "$REPO/tools/corpus_ls.sh" "$CORPUS_DIR" \
  | xargs -P "${JOBS:-2}" -I{} bash -c 'check_one "$@"' _ {} > "$OUT/results.txt" 2>/dev/null

grep '^PASS ' "$OUT/results.txt" | awk '{print $2}' | sort > "$OUT/pass.txt"
echo "── $CORPUS_LABEL ──"
for b in PASS CFAIL DEPMISS EMITFAIL NOMAIN INFRA; do echo "$b: $(grep -c "^$b " "$OUT/results.txt")"; done
# ALWAYS printed, zero included: a number that only appears when it is bad is a number
# nobody has a baseline for.
_retries=0
[ -f "$OUT/retries.txt" ] && _retries=$(wc -l < "$OUT/retries.txt" | tr -d ' ')
echo "zig-infra retries: $_retries (transient stdlib read failures -- BUG-302)"
[ "$_retries" -gt 0 ] && echo "  retried: $(sort "$OUT/retries.txt" | uniq -c | tr '\n' ' ')"
if grep -q '^INFRA ' "$OUT/results.txt"; then
  echo "  x INFRA (zig could not read its own stdlib after 3 tries): $(grep -c '^INFRA ' "$OUT/results.txt")"
  grep '^INFRA ' "$OUT/results.txt" | awk '{print "      " $2}'
fi

# NAME what is not passing, not just count it. On test/ the non-passing set is large
# and mostly deliberate (negative tests, library modules), so a count is right there.
# On examples/ it is small and every entry is a question worth answering -- a GUI
# example that needs its own scaffold, or a genuinely broken sample. A bare count
# there would let "3 CFAIL" sit unread forever, which is the silent-cap failure this
# repo keeps re-learning.
if [ "$EXAMPLES" = 1 ]; then
  notpass=$(grep -vE "^PASS " "$OUT/results.txt" | sort)
  if [ -n "$notpass" ]; then
    echo "  not in the passing set (NOT gated -- each is a question, not a pass):"
    echo "$notpass" | sed "s/^/    /"
  fi
fi

if [ "$UPDATE" = 1 ]; then
  cp "$OUT/pass.txt" "$BASELINE"
  echo "baseline updated: $(wc -l < "$BASELINE") passing tests -> $BASELINE"
  exit 0
fi

if [ "$GATE" = 1 ]; then
  [ -f "$BASELINE" ] || { echo "no baseline — run: bash tools/full_sweep.sh --update-baseline"; exit 2; }
  reg=$(comm -23 "$BASELINE" "$OUT/pass.txt")
  if [ -n "$reg" ]; then
    echo "✗ REGRESSION — baseline-passing tests that now FAIL:"; echo "$reg"; exit 1
  fi
  newp=$(comm -13 "$BASELINE" "$OUT/pass.txt")
  [ -n "$newp" ] && { echo "· new passes (run --update-baseline to lock them in):"; echo "$newp"; }

  # ── ABSOLUTE leg: every POSITIVE test must pass, baseline or no baseline ──────
  #
  # This is compile_check's property, asserted here because the work is identical and
  # was being done TWICE. Measured 2026-08-19: compile_check's 278 files are a strict
  # SUBSET of this sweep's corpus (499) with zero unique entries, and both run the same
  # `zig build-exe -fno-emit-bin -lc` over the same selfhost emit. So a FULL tier
  # emitted and compiled those 278 files twice, for ~8 minutes.
  #
  # WHAT WOULD HAVE BEEN LOST by simply dropping compile_check, and why this leg exists:
  # the two gates differ in KIND, not just corpus. This sweep is RELATIVE (regression vs
  # a baseline), so a file outside the baseline cannot make it red however broken it is.
  # compile_check is ABSOLUTE (0 FAILED) over the positive set. Dropping it without this
  # leg would have quietly traded an absolute guarantee for a relative one.
  #
  # The set comes from tools/positive_set.sh -- the same enumerator compile_check uses,
  # extracted so the two cannot drift on what "positive" means.
  # UNITS: results.txt/pass.txt hold BARE BASENAMES ("allocate_slice4_test"), while the
  # enumerator returns PATHS ("test/allocate_slice4_test.zbr"). Compare basenames or the
  # leg matches nothing and reports the entire positive set as failing -- which is
  # exactly what the first version did. It failed LOUDLY (all 276), which is the
  # forgiving kind of wrong; a units bug that mismatched only SOME entries would have
  # looked like a plausible finding.
  # One `comm` rather than a grep-per-file loop: 276 process spawns is seconds of pure
  # overhead on Git Bash, and pass.txt is already sorted by the sweep above.
  # THE POSITIVE SET IS A test/ SET, so this leg is meaningless under --examples: it
  # would compare the 276 test files against the EXAMPLES pass list and report every
  # one of them as a MUST-PASS failure. That is exactly what it did on the night it
  # landed -- `examples_sweep` could not pass at all -- and the reason nobody saw it is
  # that the commit verified full_sweep and not its --examples sibling. Running two
  # corpora through one script is still right (the emit/build/baseline logic cannot
  # drift between them), but every LEG has to say which corpus it is about.
  if [ "$EXAMPLES" = 0 ]; then
    POSN=$(bash "$REPO/tools/positive_set.sh" | wc -l | tr -d ' ')
    posfail=$(comm -23     <(bash "$REPO/tools/positive_set.sh" | sed 's|.*/||; s|\.zbr$||' | sort -u)     "$OUT/pass.txt")
    if [ -n "$posfail" ]; then
      echo "✗ POSITIVE-SET FAILURE — these are registered as MUST-PASS and did not:"
      printf '%s' "$posfail" | sed 's/^/    /'
      echo "  (this is compile_check's absolute leg; it does not care about the baseline)"
      exit 1
    fi

    echo "✓ full-sweep gate PASS — 0 regressions vs baseline ($(wc -l < "$BASELINE") tests); positive set $POSN/$POSN pass"
  else
    # NAME THE MISSING LEG rather than reprinting the test/ sweep's sentence. An
    # operator reading two identical PASS lines would reasonably assume both corpora
    # got both assertions.
    echo "✓ full-sweep gate PASS — 0 regressions vs baseline ($(wc -l < "$BASELINE") examples); RELATIVE leg only (the positive set is a test/ set)"
  fi
  exit 0
fi
