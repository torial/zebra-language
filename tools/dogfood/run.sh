#!/usr/bin/env bash
# tools/dogfood/run.sh — differential dogfood sweep.
#
# Hand-directed complement to the fuzzer (fuzz/): each probe is a small, realistic
# program exercising a stdlib/idiom COMBINATION that the generator does not produce.
# Every probe is emitted by BOTH compilers and compile-checked (zig build-obj), then
# classified:
#
#   clean                     both emit + both compile        (the pattern works)
#   SHARED-GAP                both reject                      (a real gap in the language)
#   DIVERGE self-fails        bootstrap ok, selfhost rejects   (converge selfhost — cf. BUG-173/177)
#   DIVERGE boot-fails        selfhost ok, bootstrap rejects   (selfhost-ahead — cf. BUG-179)
#   BOTH-EMIT-FAIL            both fail to emit                (usually a probe syntax error)
#
# The round-trip gate (bootstrap_check.sh) verifies selfhost self-consistency but
# NOT selfhost-vs-bootstrap equivalence; this sweep is the differential net for that.
#
# Prereqs: zig-out/bin/{zebra,zebra-bootstrap}.exe built; zig on PATH (or set ZIG).
# Usage:  bash tools/dogfood/run.sh
set -u
ZIG="${ZIG:-/c/Users/Sean/.zvm/bin/zig.exe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOT="$REPO/zig-out/bin/zebra-bootstrap.exe"
SELF="$REPO/zig-out/bin/zebra.exe"
P="$SCRIPT_DIR/probes"
W="$(mktemp -d 2>/dev/null || echo /tmp/dogfood-work)"; rm -rf "$W"; mkdir -p "$W"

classify () {
  local name="$1" f="$2"
  local bd="$W/${name}_boot" sd="$W/${name}_self"; mkdir -p "$bd" "$sd"
  local bemit=1 bcomp=1 semit=1 scomp=1
  if "$BOOT" --emit-zig "$f" > "$bd/m.zig" 2>"$bd/e.err"; then bemit=0
    ( cd "$bd" && "$ZIG" build-obj m.zig -femit-bin=m.o 2>bo.err ) && bcomp=0
  fi
  if "$SELF" --emit-zig "$f" --output-dir "$sd" >/dev/null 2>"$sd/e.err"; then semit=0
    cp "$sd/"*.zig "$sd/m.zig" 2>/dev/null
    ( cd "$sd" && "$ZIG" build-obj m.zig -femit-bin=m.o 2>bo.err ) && scomp=0
  fi
  local bok=$(( bemit==0 && bcomp==0 )) sok=$(( semit==0 && scomp==0 ))
  local verdict
  if   [[ $bok -eq 1 && $sok -eq 1 ]]; then verdict="clean"
  elif [[ $bemit -ne 0 && $semit -ne 0 ]]; then verdict="BOTH-EMIT-FAIL (likely probe syntax)"
  elif [[ $bok -eq 0 && $sok -eq 0 ]]; then verdict="SHARED-GAP (both reject)"
  elif [[ $bok -eq 1 && $sok -eq 0 ]]; then verdict=">>> DIVERGE: self-fails (boot ok)"
  elif [[ $bok -eq 0 && $sok -eq 1 ]]; then verdict=">>> DIVERGE: boot-fails (self ok)"
  else verdict="mixed"; fi
  printf "%-26s %s\n" "$name" "$verdict"
}

for f in "$P"/*.zbr; do
  [[ -e "$f" ]] || continue
  classify "$(basename "$f" .zbr)" "$f"
done
