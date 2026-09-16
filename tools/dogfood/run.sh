#!/usr/bin/env bash
# tools/dogfood/run.sh — dogfood sweep.
#
# Hand-directed complement to the fuzzer (fuzz/): each probe is a small, realistic
# program exercising a stdlib/idiom COMBINATION that the generator does not produce.
# Every probe is emitted and compile-checked (zig build-obj), then classified:
#
#   clean                     emits + compiles                 (the pattern works)
#   GAP                       the compiler rejects it          (a gap in the language)
#   EMIT-FAIL                 fails to emit                    (usually a probe syntax error)
#
# DIFFERENTIAL until 2026-09-16: every probe went through BOTH compilers and the
# verdicts DIVERGE self-fails / DIVERGE boot-fails named the one that disagreed
# (BUG-173/177/179 were found that way). The bootstrap is retired
# (docs/design/bootstrap_sunset.md Step 3), so this is a validity sweep now.
#
# Prereqs: zig-out/bin/zebra[.exe] built; zig on PATH (or set ZIG).
# Usage:  bash tools/dogfood/run.sh
set -u
ZIG="${ZIG:-$(command -v zig || echo /c/Users/Sean/.zvm/bin/zig.exe)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SELF="$REPO/zig-out/bin/zebra.exe"; [[ -x "$SELF" ]] || SELF="$REPO/zig-out/bin/zebra"
P="$SCRIPT_DIR/probes"
W="$(mktemp -d 2>/dev/null || echo /tmp/dogfood-work)"; rm -rf "$W"; mkdir -p "$W"

classify () {
  local name="$1" f="$2"
  local sd="$W/${name}_self"; mkdir -p "$sd"
  local semit=1 scomp=1
  if "$SELF" --emit-zig "$f" --output-dir "$sd" >/dev/null 2>"$sd/e.err"; then semit=0
    # the emit is <name>.zig plus zebra_rt.zig beside it (runtime-module shape); build the root
    ( cd "$sd" && "$ZIG" build-obj "$name.zig" -femit-bin=m.o -lc 2>bo.err ) && scomp=0
  fi
  local verdict
  if   [[ $semit -eq 0 && $scomp -eq 0 ]]; then verdict="clean"
  elif [[ $semit -ne 0 ]]; then verdict="EMIT-FAIL (likely probe syntax): $(grep -m1 -i error "$sd/e.err" | cut -c1-80)"
  else verdict=">>> GAP: emitted, zig refused: $(grep -m1 'error:' "$sd/bo.err" | cut -c1-80)"; fi
  printf "%-26s %s\n" "$name" "$verdict"
}

for f in "$P"/*.zbr; do
  [[ -e "$f" ]] || continue
  classify "$(basename "$f" .zbr)" "$f"
done
