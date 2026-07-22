#!/usr/bin/env bash
# selfcompile_check.sh — the selfhost `zebra.exe` must be able to compile its OWN driver,
# `selfhost/main.zbr`, into Zig that COMPILES. This was BUG-181 (resolved 2026-07-22): the
# selfhost's codegen diverged from the bootstrap on ~8 patterns in its own source, emitting
# invalid Zig. No other gate catches this — the committed selfhost/*.zig is produced by the
# BOOTSTRAP (regen authority), and selfhost_smoke/compile_check only run small fixtures.
#
# This gate: emit selfhost/main.zbr with zebra.exe (--emit-zig --output-dir), then run
# `zig build-exe -fno-emit-bin` (semantic analysis, no link) on the emitted main.zig.
#
# Usage:  bash tools/selfcompile_check.sh
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
OUT="${TMPDIR:-/tmp}/zbr-selfcompile"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"   # ensure zig + zebra are reachable standalone

[ -x "$ZEBRA" ] || { echo "selfcompile-check: zig-out/bin/zebra.exe missing — run 'zig build' first" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"

# 1. Self-emit: zebra.exe compiles its own driver + all transitive modules to $OUT/*.zig.
if ! "$ZEBRA" --emit-zig --output-dir "$OUT" "$REPO/selfhost/main.zbr" >/dev/null 2>"$OUT/emit.err"; then
  echo "selfcompile-check: FAIL — zebra.exe could not emit selfhost/main.zbr" >&2
  grep -v "^wrote " "$OUT/emit.err" | tail -20 >&2
  exit 1
fi
[ -s "$OUT/main.zig" ] || { echo "selfcompile-check: FAIL — no main.zig emitted" >&2; exit 1; }

# 2. Compile the emitted Zig (semantic analysis; the emitted compiler is large, no link).
if zig build-exe -fno-emit-bin -lc "$OUT/main.zig" >"$OUT/build.err" 2>&1; then
  echo "selfcompile-check: PASS — zebra.exe self-compiles selfhost/main.zbr to compiling Zig"
  exit 0
else
  echo "selfcompile-check: FAIL — the self-emitted main.zig does not compile (BUG-181 regression)" >&2
  grep -E ':[0-9]+:[0-9]+: error:' "$OUT/build.err" | sed -E 's#.*/([A-Za-z]+\.zig:[0-9]+:[0-9]+):#\1:#' | sort -u | head -30 >&2
  exit 1
fi
