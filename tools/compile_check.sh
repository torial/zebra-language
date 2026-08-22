#!/usr/bin/env bash
# compile_check.sh — type-check the Zig that the compiler EMITS for each positive
# test, not just that emission succeeds. The smoke suite only runs `--emit-zig`, so
# emitted Zig that doesn't compile (stale stdlib APIs, codegen bugs) slips past it.
# This closes that gap: emit every positive-smoke test and run `zig build-exe
# -fno-emit-bin` (semantic analysis, no linking) on the result.
#
# Test set is derived from tools/selfhost_smoke.sh's POSITIVE entries
# (smoke / smoke_turbo / smoke_test / smoke_run / smoke_run_bootstrap / smoke_warn),
# which excludes negative tests (smoke_*_fail) and library-only modules.
#
# Usage:
#   bash tools/compile_check.sh                 # selfhost (zebra.exe), all tests
#   bash tools/compile_check.sh --bootstrap     # bootstrap (zebra-bootstrap.exe)
#   bash tools/compile_check.sh --single-file   # emit each test with --single-file, then check
#   bash tools/compile_check.sh --no-runtime-module # emit with the INLINE runtime, then check
#   bash tools/compile_check.sh --only hashmap   # only tests whose name contains 'hashmap'
#   JOBS=8 bash tools/compile_check.sh           # override parallelism (default 4)
#
# --single-file mode: appends --single-file to the emit, so it checks the namespaced
# `const _Mod = struct {…}` shape (docs/single_file_emit_design.md §7a/§7b). The selfhost
# does the full multi-module merge (Phase 2: deps become `const _mod_X = struct {…}` in one
# file), so cross-module tests ARE checked there. The bootstrap is single-module only for
# now (Phase 2 is selfhost-first), so `--bootstrap --single-file` still skips multi-module.
# A clean run matches the multi-file baseline test-for-test (zero regressions).
#
# Parallelism: per-test emit+typecheck is independent, so the worklist is fanned out
# across $JOBS workers (each in its own temp dir — parallel-safe). Measured ~3x at
# JOBS=4. Per build-exe is ~95% std/preamble semantic analysis (caching barely helps),
# so the real lever is parallelism, not cache. Tune JOBS to RAM: each worker is a few
# hundred MB; on a 4GB-free host JOBS=4 is comfortable.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/zig_build_lib.sh
. "$REPO/tools/zig_build_lib.sh"
SMOKE="$REPO/tools/selfhost_smoke.sh"
OUT="${TMPDIR:-/tmp}/zbr-compile-check"

# Tests that legitimately can't be compile-checked standalone (need external
# source/C files the emit step doesn't materialize). Not bugs — harness limits.
SKIP=" c_interop_test zig_interop_test forgot_parens_test "

# Bootstrap mode emits to STDOUT (the bootstrap CLI has no --output-dir), so it can
# only materialize the single root file — multi-file tests whose deps are separate
# modules can't be checked this way. Skip them in --bootstrap mode only (they pass
# under the selfhost, whose --output-dir emits the deps alongside the root).
BOOTSTRAP_SKIP=" crossmod_hatopt_test crossmod_optret_test crossmod_struct_pat_test crossmod_types_test crossmod_arith_test crossmod_infer_test crossmod_expose_test val_test test_module_test "

# The bootstrap's --single-file is single-module only (Phase 2 is selfhost-first): its dep
# modules are still emitted unwrapped, so multi-module programs don't line up. Skip them
# under --bootstrap --single-file only. The `*crossmod*` glob (applied below) covers the
# crossmod_* family + bug168_crossmod_prim_return_test; these are the remaining multi-module
# tests that don't match that glob. The SELFHOST does the full merge, so it skips nothing here.
SINGLE_FILE_SKIP=" val_test test_module_test "

zebra_for() { # $1 = mode
  if [ "$1" = bootstrap ]; then echo "$REPO/zig-out/bin/zebra-bootstrap.exe"
  else echo "$REPO/zig-out/bin/zebra.exe"; fi
}

# ── Worker: check a single test, print one result token (PASS|FAIL|SKIP <name>) ──
if [ "${1:-}" = "--worker" ]; then
  mode="$2"; rel="$3"
  name=$(basename "$rel" .zbr)
  zebra=$(zebra_for "$mode")
  # CC_SINGLE_FILE / CC_INLINE_RT are exported by the main process. Runtime-module
  # emission is the DEFAULT as of 2026-07-28, so the interesting second mode is the
  # inline runtime (still reachable via --no-runtime-module, and what the GUI and
  # node-addon paths fall back to), not the split one.
  sf_flag=""; [ "${CC_SINGLE_FILE:-0}" = 1 ] && sf_flag="--single-file"
  [ "${CC_INLINE_RT:-0}" = 1 ] && sf_flag="--no-runtime-module"
  wdir="$OUT/w-$name"; rm -rf "$wdir"; mkdir -p "$wdir"
  main="$wdir/$name.zig"
  if [ "$mode" = bootstrap ]; then
    "$zebra" $sf_flag --emit-zig "$REPO/$rel" > "$main" 2>/dev/null || { echo "EMITFAIL $name"; exit 0; }
  else
    "$zebra" $sf_flag --emit-zig "$REPO/$rel" --output-dir "$wdir" >/dev/null 2>&1 || { echo "EMITFAIL $name"; exit 0; }
  fi
  [ -f "$main" ] || { echo "SKIP $name"; exit 0; }          # library module (no main)
  grep -q "pub fn main" "$main" || { echo "SKIP $name"; exit 0; }
  # BUG-302: a failure to read ZIG'S OWN stdlib is not a verdict on our emitted code.
  # Retried by the shared predicate; a persistent one is reported as INFRA so it cannot
  # be read as "the compiler emitted bad Zig".
  berr="$wdir/build.err"
  zbr_zig_build "$main" "$berr" 90
  _rc=$?
  [ "${ZBR_RETRIES:-0}" -gt 0 ] && printf '%s\n' "$name" >> "$OUT/retries.txt"
  if [ $_rc -eq 0 ]; then
    echo "PASS $name"
  elif zbr_zig_infra_error "$berr"; then
    echo "INFRA $name"
  else
    echo "FAIL $name"
  fi
  rm -rf "$wdir"
  exit 0
fi

# ── Main: parse flags, build worklist, fan out ──────────────────────────────────
MODE=selfhost; ONLY=""; SF=0; RM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bootstrap)   MODE=bootstrap; shift;;
    --single-file) SF=1; shift;;
    --no-runtime-module) RM=1; shift;;
    --only)        ONLY="${2:-}"; shift 2;;
    *) shift;;
  esac
done
JOBS="${JOBS:-4}"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"   # ensure zig is reachable when run standalone
export CC_SINGLE_FILE="$SF"                   # picked up by --worker
export CC_INLINE_RT="$RM"                     # picked up by --worker
mkdir -p "$OUT"
# Per-RUN counter. $OUT is not cleared between runs here (unlike full_sweep), so
# without this the BUG-302 retry count would report every retry since the temp dir was
# created -- a number that only ever grows and is wrong from the second run onward.
rm -f "$OUT/retries.txt"

# The derivation moved to tools/positive_set.sh so full_sweep can assert the identical
# property over the same set. Two copies of "what counts as a positive test" would
# drift silently the first time a registration helper is added.
tests=$(bash "$REPO/tools/positive_set.sh") || exit 2

# Build the filtered worklist (apply SKIP / BOOTSTRAP_SKIP / --only up front).
worklist=""; skip=0
for f in $tests; do
  name=$(basename "$f" .zbr)
  if [ -n "$ONLY" ]; then case "$name" in *"$ONLY"*) ;; *) continue;; esac; fi
  case "$SKIP" in *" $name "*) skip=$((skip+1)); continue;; esac
  if [ "$MODE" = bootstrap ]; then
    case "$BOOTSTRAP_SKIP" in *" $name "*) skip=$((skip+1)); continue;; esac
  fi
  if [ "$SF" = 1 ] && [ "$MODE" = bootstrap ]; then
    # Bootstrap single-file is single-module only (Phase 2 is selfhost-first): drop the
    # multi-module tests. The selfhost merges them, so it checks the full corpus.
    case "$name" in *crossmod*) skip=$((skip+1)); continue;; esac
    case "$SINGLE_FILE_SKIP" in *" $name "*) skip=$((skip+1)); continue;; esac
  fi
  worklist="$worklist$f"$'\n'
done

results=$(printf '%s' "$worklist" | grep -v '^$' \
          | xargs -P"$JOBS" -I{} bash "$0" --worker "$MODE" {})

pass=$(printf '%s\n' "$results" | grep -c '^PASS ' || true)
cfail=$(printf '%s
' "$results" | grep -c '^FAIL ' || true)
# EMITFAIL IS A FAILURE, and it used to be counted as a SKIP -- a false green in this
# gate. Every file in the worklist is a POSITIVE test the smoke suite declares must
# succeed; if the compiler cannot EMIT it, that is the most serious result possible
# here, and it was landing in the same bucket as "library module, no main".
#
# Found 2026-08-19 while merging this gate's property into full_sweep: a tier run said
# "275 passed, 0 FAILED, 1 skipped" where standalone gave 276/0/0. The difference was
# one transient emit failure under load, absorbed silently into the skip count with
# "0 FAILED" printed beside it. A real emit regression would hide identically.
# full_sweep already separates EMITFAIL from NOMAIN; this now does too.
emitfail=$(printf '%s
' "$results" | grep -c '^EMITFAIL ' || true)
fail=$((cfail + emitfail))
wskip=$(printf '%s\n' "$results" | grep -c '^SKIP ' || true)
skip=$((skip + wskip))
failed=$(printf '%s\n' "$results" | awk '/^FAIL /{printf " %s", $2}')

# An INFRA line lands in none of the counters above, so it must be surfaced explicitly or
# a file that quietly stopped being checked disappears -- the silent-cap failure the
# EMITFAIL split exists to prevent.
infra=$(printf '%s
' "$results" | grep -c '^INFRA ' || true)
# BUG-302 counts ride ON the summary line, not after it: gates.sh shows a gate's LAST
# line, so a trailing echo displaced the numbers people actually read. Still emitted
# every run -- when both are zero the clause is omitted, which is the only case where
# silence is not hiding anything.
_cretries=0
[ -f "$OUT/retries.txt" ] && _cretries=$(wc -l < "$OUT/retries.txt" | tr -d ' ')
_infra_note=""
if [ "$_cretries" != "0" ] || [ "$infra" != "0" ]; then
  _infra_note=", zig-infra ${_cretries} retried/${infra} persistent"
fi
echo "compile-check: $pass passed, $fail FAILED ($cfail compile, $emitfail emit), $skip skipped${_infra_note} (jobs=$JOBS${ONLY:+, only=$ONLY}${MODE:+, mode=$MODE}$([ "$SF" = 1 ] && echo ", single-file"))"
[ -n "$failed" ] && echo "FAILED (emitted, but zig refused):$failed"
emitfailed=$(printf '%s
' "$results" | awk '/^EMITFAIL /{printf " %s", $2}')
[ -n "$emitfailed" ] && echo "EMITFAIL (compiler could not emit a MUST-PASS test):$emitfailed"
_cretries=0
[ -f "$OUT/retries.txt" ] && _cretries=$(wc -l < "$OUT/retries.txt" | tr -d ' ')
if [ "$infra" -gt 0 ]; then
  printf '%s
' "$results" | awk '/^INFRA /{printf "   %s
", $2}'
fi
[ "$fail" -eq 0 ]
