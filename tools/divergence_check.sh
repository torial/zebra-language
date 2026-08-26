#!/usr/bin/env bash
# divergence_check.sh — the independent witness for selfhost-vs-bootstrap DIVERGENCE.
#
# The existing gates (round-trip, smoke, compile_check) all EMIT with one compiler,
# so a case where the self-hosted compiler DISAGREES with the bootstrap is invisible
# to them — round-trip only proves the selfhost is self-consistent, not that it
# matches the reference. This harness closes that blind spot: it emits every corpus
# file with BOTH `zebra-bootstrap.exe` and `zebra.exe`, compile-checks each output
# with `zig build-exe -fno-emit-bin`, and reports where the two disagree.
#
#   SELFHOST GAP  = bootstrap handles it, selfhost does not  (selfhost lags — the
#                   File.listDir / Math.log / List(float32) class; matters most as
#                   the bootstrap sunsets toward 1.0).
#   BOOTSTRAP GAP = selfhost handles it, bootstrap does not  (bootstrap lags — e.g.
#                   SIMD / f32x8, which the bootstrap never learned).
#
# Bootstrap emits to STDOUT (no --output-dir), so it can only materialize a single
# root file. Files with a local `use` (multi-module) are therefore selfhost-only
# here and reported separately, not as divergences.
#
# Usage:
#   bash tools/divergence_check.sh                # test/ + examples/ (report only)
#   bash tools/divergence_check.sh --only json    # names containing 'json'
#   bash tools/divergence_check.sh --gate         # exit 1 if any SELFHOST gap (regression)
#   JOBS=4 bash tools/divergence_check.sh         # parallelism (default 4)
#
#   RESUMABLE (for a machine or harness that cannot hold a ~25 min run):
#     bash tools/divergence_check.sh --gate --results R.txt   # run a pass, append, resume
#     ...re-run until it reports "0 file(s) this pass"...
#     bash tools/divergence_check.sh --gate --results R.txt --classify   # score it
#   --max N sizes a pass. --classify skips corpus enumeration (~2 min here) and scores
#   what is already on disk.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/zbr-divergence"
# shellcheck source=tools/zig_build_lib.sh
. "$REPO/tools/zig_build_lib.sh"

# BUG-302 one layer up. An EMITFAIL used to discard the compiler's stderr and then name
# the file as having failed to emit -- a verdict with its evidence deleted.
_keep_emit_err() {   # $1 = wdir, $2 = name
  [ -s "$1/emit.err" ] || return 0
  mkdir -p "$OUT/evidence" 2>/dev/null
  cp "$1/emit.err" "$OUT/evidence/$2.emit.err" 2>/dev/null
}
BOOT="$REPO/zig-out/bin/zebra-bootstrap.exe"
SELF="$REPO/zig-out/bin/zebra.exe"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

# emit+compile one file with one compiler; echo a status token.
#   EMITFAIL | NOMAIN | CPASS | CFAIL
emit_and_check() { # $1=compiler $2=mode(boot|self) $3=absfile $4=workdir
  local zebra="$1" mode="$2" f="$3" wdir="$4"
  local name; name=$(basename "$f" .zbr)
  local main="$wdir/$name.zig"
  rm -rf "$wdir"; mkdir -p "$wdir"
  if [ "$mode" = boot ]; then
    # BUG-302 one layer up: keep the compiler's own account of the failure. See the
    # note in full_sweep.check_one.
    "$zebra" --emit-zig "$f" > "$main" 2>"$wdir/emit.err" || { _keep_emit_err "$wdir" "$name"; echo EMITFAIL; return; }
  else
    "$zebra" --emit-zig "$f" --output-dir "$wdir" >/dev/null 2>"$wdir/emit.err" || { _keep_emit_err "$wdir" "$name"; echo EMITFAIL; return; }
  fi
  [ -s "$main" ] || { echo EMITFAIL; return; }
  grep -q "pub fn main" "$main" || { echo NOMAIN; return; }
  # BUG-302: this line used to be `... >/dev/null 2>&1 ... else echo CFAIL`, which
  # discarded the error AND called every failure a verdict on our code. A transient
  # "zig cannot read its own stdlib" therefore surfaced as a SELFHOST GAP -- the gate's
  # loudest possible claim, meaning "the selfhost regressed against the reference".
  # Occurrence 6 (2026-08-22) reported exactly two such phantom gaps.
  local berr="$wdir/build.err"
  zbr_zig_build "$main" "$berr" 90
  local _rc=$?
  # Workers are separate processes, so the count accumulates in a file (see the summary).
  [ "${ZBR_RETRIES:-0}" -gt 0 ] && printf '%s\n' "$name" >> "$OUT/retries.txt"
  if [ $_rc -eq 0 ]; then echo CPASS
  elif zbr_zig_infra_error "$berr"; then echo CINFRA
  else echo CFAIL; fi
}

if [ "${1:-}" = "--worker" ]; then
  f="$2"; name=$(basename "$f" .zbr)
  # multi-module (has a local `use`) → bootstrap can't materialize deps via stdout.
  if grep -qE '^use ' "$f"; then
    s=$(emit_and_check "$SELF" self "$f" "$OUT/ws-$name")
    echo "$name|MULTI|$s"; exit 0
  fi
  b=$(emit_and_check "$BOOT" boot "$f" "$OUT/wb-$name")
  s=$(emit_and_check "$SELF" self "$f" "$OUT/ws-$name")
  echo "$name|$b|$s"; exit 0
fi

ONLY=""; GATE=0; RESULTS=""; MAX=0; CLASSIFY=0
while [ $# -gt 0 ]; do case "$1" in
  --only) ONLY="${2:-}"; shift 2;;
  --gate) GATE=1; shift;;   # exit non-zero if any SELFHOST gap exists (regression signal)
  # RESUMABLE MODE. `--results FILE` accumulates one `name|boot|self` line per file and
  # SKIPS anything already recorded, so an interrupted run loses only the file it was on.
  # `--max N` stops after N fresh files, sizing a pass to whatever window is available.
  # Re-invoke until it reports 0 this pass; it then classifies over the complete set.
  #
  # This costs almost nothing to add because the per-file unit ALREADY existed and was
  # already stateless: `--worker <file>` emits with both compilers and prints one line.
  # The gate was atomic only because the driver held every result in a shell variable.
  #
  # WHY IT MATTERS BEYOND ONE BAD AFTERNOON: this is the heaviest gate here (~25 min at
  # JOBS=2), and CLAUDE.md already records `gates.sh --full` being killed by the harness
  # TWICE on 2026-08-11, losing every heavy witness. All-or-nothing turns any
  # interruption into a total loss — a property of the tool, not of the machine it runs on.
  #
  # CORRECTION 2026-08-14, and it matters because it was my stated reason for building
  # this. I claimed background runs here "die silently within ~2 minutes", from a
  # liveness probe (`ps -W | grep -c zebra-language`) that returns 0 WHETHER OR NOT a
  # worker is running — verified by starting a known-live worker and watching it still
  # print 0. A broken probe pointing at the reassuring answer, exactly as CLAUDE.md's
  # instrument rules predict.
  #
  # What actually happened: one run survived THREE HOURS and died only when I EDITED
  # THIS FILE while it was executing — bash re-reads a script as it runs, so the edit
  # corrupted the live instance (`syntax error near unexpected token` from a flag that
  # did not exist when it started). Some of the "harness kills" were plausibly me.
  #
  # The feature still earns its place on the 2026-08-11 receipt above and on the
  # all-or-nothing argument. But do NOT cite "runs die in 2 minutes here" — that was
  # measured with an instrument that could not see.
  --results) RESULTS="${2:-}"; shift 2;;
  --max) MAX="${2:-0}"; shift 2;;
  # score an existing results file without touching the corpus
  --classify) CLASSIFY=1; shift;;
  *) shift;;
esac; done
JOBS="${JOBS:-4}"; mkdir -p "$OUT"
# Per-RUN counter. $OUT is not cleared between runs here (unlike full_sweep), so
# without this the BUG-302 retry count would report every retry since the temp dir was
# created -- a number that only ever grows and is wrong from the second run onward.
rm -f "$OUT/retries.txt"

# --classify: score an existing --results file WITHOUT re-enumerating the corpus.
# Enumeration plus the per-file skip loop costs ~2 minutes here (490 files, and every
# `basename`/`grep` is a process spawn on Windows), which is fine once per pass and
# absurd when the answer is already on disk. It also makes the refusal below testable
# in under a second instead of never.
if [ -n "$RESULTS" ] && [ "$CLASSIFY" = 1 ]; then
  [ -f "$RESULTS" ] || { echo "divergence: REFUSING — no results file at $RESULTS" >&2; exit 2; }
  files=""
  nqueued=0
  skip_scan=1
fi

# TRACKED files only; see tools/corpus_ls.sh for why a glob is wrong here.
if [ "${skip_scan:-0}" != 1 ]; then
files=$(bash "$REPO/tools/corpus_ls.sh" --abs test examples)
fi
worklist=""; nqueued=0
for f in $files; do
  name=$(basename "$f" .zbr)
  [ -n "$ONLY" ] && { case "$name" in *"$ONLY"*) ;; *) continue;; esac; }
  # Resume: a name already recorded is not re-run. Anchored on the field separator so
  # `bug28` cannot match `bug283`.
  if [ -n "$RESULTS" ] && [ -f "$RESULTS" ] && grep -q "^$name|" "$RESULTS"; then continue; fi
  if [ "$MAX" -gt 0 ] && [ "$nqueued" -ge "$MAX" ]; then break; fi
  worklist="$worklist$f"$'\n'
  nqueued=$((nqueued + 1))
done

if [ -n "$RESULTS" ]; then
  touch "$RESULTS"
  if [ "$nqueued" -gt 0 ]; then
    # `tee -a` so a KILL mid-pass still leaves every COMPLETED line on disk. Buffering
    # the pass and writing at the end would reproduce the very failure this flag fixes.
    printf '%s' "$worklist" | grep -v '^$' \
      | xargs -P"$JOBS" -I{} bash "$0" --worker {} | tee -a "$RESULTS" >/dev/null
  fi
  total_seen=$(grep -c '|' "$RESULTS" 2>/dev/null || echo 0)
  echo "── resumable: $nqueued file(s) this pass; $total_seen recorded in $RESULTS"
  # Classify ONLY when nothing fresh was queued, i.e. the corpus is fully recorded.
  # A verdict over a PARTIAL set would be the "0 findings because nothing ran" failure
  # this repo has receipts for, and --gate would print a green it has not earned.
  if [ "$nqueued" -gt 0 ]; then
    echo "   more remain — re-run the same command until it reports 0 file(s) this pass."
    exit 0
  fi
  echo "   corpus complete; classifying."
  # A killed pass ORPHANS its `bash --worker` children, and they keep appending here
  # after the driver is gone. Observed 2026-08-14: the file grew 640 -> 657 lines in 20
  # seconds with the driver dead, and `kill_orphans.sh` does not help because it targets
  # compiler processes, not the worker shells. So a resumed run can queue a file an
  # orphan is still working on, and BOTH write a row.
  #
  # Duplicates that AGREE are harmless and are collapsed. Duplicates that DISAGREE mean
  # the measurement was not deterministic for that file, and picking either row would be
  # inventing a verdict -- so REFUSE. A gate that reports a green it has not earned is
  # the one outcome this repo will not tolerate, and every other tool here that can lose
  # its footing (grammar_export, hazard_lint, output_sweep) refuses the same way.
  dis=$(sort -u "$RESULTS" | grep '|' | cut -d'|' -f1 | sort | uniq -d)
  if [ -n "$dis" ]; then
    echo "divergence: REFUSING — these file(s) recorded CONTRADICTORY results across" >&2
    echo "            passes, so no verdict over this results file is trustworthy:" >&2
    printf '              %s\n' $dis >&2
    echo "            Delete $RESULTS and re-run, ideally without interruption." >&2
    exit 2
  fi
  results=$(sort -u "$RESULTS")
else
  results=$(printf '%s' "$worklist" | grep -v '^$' \
            | xargs -P"$JOBS" -I{} bash "$0" --worker {})
fi

# classify
self_gap=""; boot_gap=""; agree_fail=""; multi_selffail=""; infra_names=""
np=0; naf=0; nsg=0; nbg=0; nnomain=0; nmulti=0; nexpected=0; ninfra=0
# Names the smoke suite registers as "the selfhost must REJECT this" (smoke_tc_fail).
MUST_REJECT="$(grep -oE '^smoke_tc_fail +test/[A-Za-z0-9_]+\.zbr' "$REPO/tools/selfhost_smoke.sh" 2>/dev/null                | sed -E 's#^smoke_tc_fail +test/##; s#\.zbr$##')"
while IFS='|' read -r name b s; do
  [ -z "$name" ] && continue
  if [ "$b" = MULTI ]; then
    nmulti=$((nmulti+1))
    [ "$s" = CFAIL ] || [ "$s" = EMITFAIL ] && multi_selffail="$multi_selffail $name($s)"
    continue
  fi
  # normalize NOMAIN (library) — skip from divergence accounting
  if [ "$b" = NOMAIN ] || [ "$s" = NOMAIN ]; then nnomain=$((nnomain+1)); continue; fi
  # BUG-302: zig could not read its OWN stdlib, three tries running. That says nothing
  # about either compiler, so it cannot be scored as a gap in either direction -- but it
  # is NAMED below rather than silently dropped, because a rising count is the signal
  # that the environment is degrading.
  if [ "$b" = CINFRA ] || [ "$s" = CINFRA ]; then
    ninfra=$((ninfra+1)); infra_names="$infra_names $name"; continue
  fi
  # A file the SELFHOST IS SUPPOSED TO REJECT is not a gap when it rejects it.
  #
  # This gate reads "bootstrap OK, selfhost fails" as "the selfhost regressed against
  # the reference", which was true while the selfhost only ever lagged. BUG-142 broke
  # that assumption: too-few/too-many arguments are now a hard ERROR in the selfhost and
  # the bootstrap never had the check at all, so arg_count_test — a NEGATIVE test —
  # showed up as a selfhost gap for doing exactly what it is registered to do.
  #
  # DERIVED, not hand-listed: the names come from `smoke_tc_fail` registrations in
  # selfhost_smoke.sh, which is where the suite already declares "the selfhost must
  # reject this". A hand-maintained skip list would rot and silently shrink coverage —
  # the same argument output_sweep.sh makes for deriving its exclusions.
  if [ "$s" != CPASS ] && printf '%s
' "$MUST_REJECT" | grep -qx "$name"; then
    nexpected=$((nexpected+1)); continue
  fi
  b_ok=0; s_ok=0
  [ "$b" = CPASS ] && b_ok=1
  [ "$s" = CPASS ] && s_ok=1
  if [ "$b_ok" = 1 ] && [ "$s_ok" = 1 ]; then np=$((np+1))
  elif [ "$b_ok" = 1 ] && [ "$s_ok" = 0 ]; then nsg=$((nsg+1)); self_gap="$self_gap $name(self=$s)"
  elif [ "$b_ok" = 0 ] && [ "$s_ok" = 1 ]; then nbg=$((nbg+1)); boot_gap="$boot_gap $name(boot=$b)"
  else naf=$((naf+1)); agree_fail="$agree_fail $name"
  fi
done <<< "$results"

echo "═══ selfhost ↔ bootstrap divergence ═══ (jobs=$JOBS${ONLY:+, only=$ONLY})"
echo "single-module files: $np agree-pass · $naf agree-fail · $nnomain library(no-main) · $nexpected selfhost-rejects-by-design"
echo "multi-module (selfhost-only, bootstrap N/A): $nmulti"
echo
_dretries=0
[ -f "$OUT/retries.txt" ] && _dretries=$(wc -l < "$OUT/retries.txt" | tr -d ' ')
echo "zig-infra retries: $_dretries (transient stdlib read failures -- BUG-302)"
echo "zig-infra (zig could not read its own stdlib; excluded, not a gap): $ninfra"
[ -n "$infra_names" ] && echo "   $infra_names"
echo "▶ SELFHOST GAPS ($nsg) — bootstrap OK, selfhost fails (selfhost lags):"
[ -n "$self_gap" ] && echo "   $self_gap" || echo "   (none)"
echo
echo "▶ BOOTSTRAP GAPS ($nbg) — selfhost OK, bootstrap fails (bootstrap lags):"
[ -n "$boot_gap" ] && echo "   $boot_gap" || echo "   (none)"
echo
echo "· agree-fail (both fail — genuinely-broken test or both lag): $agree_fail"
[ -n "$multi_selffail" ] && { echo; echo "· multi-module selfhost failures (not A/B-checkable): $multi_selffail"; }

# ── Gate ─────────────────────────────────────────────────────────────────────
# The gate signal is SELFHOST GAPS == 0: a single-module program the bootstrap
# (independent witness) compiles but the selfhost does not — i.e. the selfhost
# silently regressed relative to the reference. Cleaned to 0 on 2026-07-22 after
# the post-BUG-181 sweep; --gate holds that line.
#
# Deliberately NOT gated (informational only): BOOTSTRAP GAPS (selfhost LEADS — a
# sunsetting-bootstrap lag, see NEXT_STEPS 5-family triage), agree-fail (negative/
# diagnostic tests that are meant to fail compilation), and multi-module selfhost
# failures (a separate interop/crossmod WIP baseline, not A/B-checkable here).
#
# This is a heavy sweep (both compilers × full corpus × `zig build-exe`), so it is a
# per-SESSION / pre-release gate like compile_check.sh — not a per-commit hook.
if [ "$GATE" = 1 ]; then
  echo
  if [ "$nsg" -eq 0 ]; then
    echo "✓ divergence gate PASS — 0 selfhost gaps (selfhost matches the bootstrap witness)."
  else
    echo "✗ divergence gate FAIL — $nsg selfhost gap(s): the selfhost regressed vs the bootstrap."
    echo "   $self_gap"
    exit 1
  fi
fi
