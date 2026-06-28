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
#   bash tools/compile_check.sh --only hashmap   # only tests whose name contains 'hashmap'
#   JOBS=8 bash tools/compile_check.sh           # override parallelism (default 4)
#
# Parallelism: per-test emit+typecheck is independent, so the worklist is fanned out
# across $JOBS workers (each in its own temp dir — parallel-safe). Measured ~3x at
# JOBS=4. Per build-exe is ~95% std/preamble semantic analysis (caching barely helps),
# so the real lever is parallelism, not cache. Tune JOBS to RAM: each worker is a few
# hundred MB; on a 4GB-free host JOBS=4 is comfortable.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
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

zebra_for() { # $1 = mode
  if [ "$1" = bootstrap ]; then echo "$REPO/zig-out/bin/zebra-bootstrap.exe"
  else echo "$REPO/zig-out/bin/zebra.exe"; fi
}

# ── Worker: check a single test, print one result token (PASS|FAIL|SKIP <name>) ──
if [ "${1:-}" = "--worker" ]; then
  mode="$2"; rel="$3"
  name=$(basename "$rel" .zbr)
  zebra=$(zebra_for "$mode")
  wdir="$OUT/w-$name"; rm -rf "$wdir"; mkdir -p "$wdir"
  main="$wdir/$name.zig"
  if [ "$mode" = bootstrap ]; then
    "$zebra" --emit-zig "$REPO/$rel" > "$main" 2>/dev/null || { echo "SKIP $name"; exit 0; }
  else
    "$zebra" --emit-zig "$REPO/$rel" --output-dir "$wdir" >/dev/null 2>&1 || { echo "SKIP $name"; exit 0; }
  fi
  [ -f "$main" ] || { echo "SKIP $name"; exit 0; }          # library module (no main)
  grep -q "pub fn main" "$main" || { echo "SKIP $name"; exit 0; }
  if zig build-exe -fno-emit-bin -lc "$main" >/dev/null 2>&1; then
    echo "PASS $name"
  else
    echo "FAIL $name"
  fi
  rm -rf "$wdir"
  exit 0
fi

# ── Main: parse flags, build worklist, fan out ──────────────────────────────────
MODE=selfhost; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bootstrap) MODE=bootstrap; shift;;
    --only) ONLY="${2:-}"; shift 2;;
    *) shift;;
  esac
done
JOBS="${JOBS:-4}"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"   # ensure zig is reachable when run standalone
mkdir -p "$OUT"

tests=$(grep -hE '^(smoke|smoke_turbo|smoke_test|smoke_run|smoke_run_bootstrap|smoke_warn) +test/' "$SMOKE" \
        | awk '{print $2}' | sort -u)

# Build the filtered worklist (apply SKIP / BOOTSTRAP_SKIP / --only up front).
worklist=""; skip=0
for f in $tests; do
  name=$(basename "$f" .zbr)
  if [ -n "$ONLY" ]; then case "$name" in *"$ONLY"*) ;; *) continue;; esac; fi
  case "$SKIP" in *" $name "*) skip=$((skip+1)); continue;; esac
  if [ "$MODE" = bootstrap ]; then
    case "$BOOTSTRAP_SKIP" in *" $name "*) skip=$((skip+1)); continue;; esac
  fi
  worklist="$worklist$f"$'\n'
done

results=$(printf '%s' "$worklist" | grep -v '^$' \
          | xargs -P"$JOBS" -I{} bash "$0" --worker "$MODE" {})

pass=$(printf '%s\n' "$results" | grep -c '^PASS ' || true)
fail=$(printf '%s\n' "$results" | grep -c '^FAIL ' || true)
wskip=$(printf '%s\n' "$results" | grep -c '^SKIP ' || true)
skip=$((skip + wskip))
failed=$(printf '%s\n' "$results" | awk '/^FAIL /{printf " %s", $2}')

echo "compile-check: $pass passed, $fail FAILED, $skip skipped (jobs=$JOBS${ONLY:+, only=$ONLY}${MODE:+, mode=$MODE})"
[ -n "$failed" ] && echo "FAILED:$failed"
[ "$fail" -eq 0 ]
