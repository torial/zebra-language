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
#
# The baseline (tools/full_sweep_baseline.txt) is the set of tests that currently
# emit+compile clean. `--gate` fails only if a baseline-passing test regresses to a
# failure — so known negatives / library / triage-backlog files need no skip-list,
# and the gate stays low-maintenance (re-baseline when the pass set intentionally
# grows, e.g. after fixing an emit bug). Heavy (~20-30 min); per-session / pre-release.
set -u
export PATH="/c/Users/Sean/.zvm/bin:$PATH"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
BASELINE="$REPO/tools/full_sweep_baseline.txt"
OUT="${TMPDIR:-/tmp}/zebra_full_sweep"; rm -rf "$OUT"; mkdir -p "$OUT"
GATE=0; UPDATE=0
for a in "$@"; do case "$a" in --gate) GATE=1;; --update-baseline) UPDATE=1;; esac; done

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
  if timeout 90 zig build-exe -fno-emit-bin -lc "$main" >/dev/null 2>&1; then
    echo "PASS $name"
  else
    echo "CFAIL $name"
  fi
  rm -rf "$wdir"
}
export -f check_one; export ZEBRA OUT REPO

ls "$REPO"/test/*.zbr | sed "s#$REPO/##" \
  | xargs -P "${JOBS:-2}" -I{} bash -c 'check_one "$@"' _ {} > "$OUT/results.txt" 2>/dev/null

grep '^PASS ' "$OUT/results.txt" | awk '{print $2}' | sort > "$OUT/pass.txt"
echo "── full-sweep (test/*.zbr) ──"
for b in PASS CFAIL EMITFAIL NOMAIN; do echo "$b: $(grep -c "^$b " "$OUT/results.txt")"; done

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
  echo "✓ full-sweep gate PASS — 0 regressions vs baseline ($(wc -l < "$BASELINE") tests)"
  exit 0
fi
