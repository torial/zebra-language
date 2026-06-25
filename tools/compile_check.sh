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
# Usage:  bash tools/compile_check.sh            # selfhost (zebra.exe)
#         bash tools/compile_check.sh --bootstrap # bootstrap (zebra-bootstrap.exe)
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
[ "${1:-}" = "--bootstrap" ] && ZEBRA="$REPO/zig-out/bin/zebra-bootstrap.exe"
SMOKE="$REPO/tools/selfhost_smoke.sh"
OUT="${TMPDIR:-/tmp}/zbr-compile-check"
mkdir -p "$OUT"

# Tests that legitimately can't be compile-checked standalone (need external
# source/C files the emit step doesn't materialize). Not bugs — harness limits.
SKIP=" c_interop_test zig_interop_test forgot_parens_test "

tests=$(grep -hE '^(smoke|smoke_turbo|smoke_test|smoke_run|smoke_run_bootstrap|smoke_warn) +test/' "$SMOKE" \
        | awk '{print $2}' | sort -u)

pass=0; fail=0; skip=0; failed=""
for f in $tests; do
  name=$(basename "$f" .zbr)
  case "$SKIP" in *" $name "*) skip=$((skip+1)); continue;; esac
  rm -f "$OUT"/*.zig 2>/dev/null
  if ! "$ZEBRA" --emit-zig "$REPO/$f" --output-dir "$OUT" >/dev/null 2>&1; then
    # front-end (emit) failure — separate concern; smoke already covers it
    continue
  fi
  main="$OUT/$name.zig"
  [ -f "$main" ] || continue           # library module (no main emitted) — skip
  grep -q "pub fn main" "$main" || { skip=$((skip+1)); continue; }
  if zig build-exe -fno-emit-bin -lc "$main" >/dev/null 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed="$failed $name"
  fi
done

echo "compile-check: $pass passed, $fail FAILED, $skip skipped"
[ -n "$failed" ] && echo "FAILED:$failed"
[ "$fail" -eq 0 ]
