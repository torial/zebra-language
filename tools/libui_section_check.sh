#!/usr/bin/env bash
# libui_section_check.sh — semantic-compile the libui_ng GUI backend WITHOUT
# linking or a Windows box. Generates the libui_ng project for an example and runs
# `zig build-obj -fno-emit-bin` against the REAL zig-libui-ng bindings (their
# extern fns need no library until link time). This catches wrong binding
# signatures (e.g. SetMargined(bool) vs 1) that `zig ast-check` cannot, in <1 s.
#
# Usage: tools/libui_section_check.sh [example.zbr ...]
#   LIBUI_BINDINGS=/path/to/zig-libui-ng/src   (default: C:\Projects\zig-libui-ng\src
#   on the laptop; /home/claude/libui-bindings in the cloud container)
# Not a runtime witness: only `zig build` + running the example on Windows is.
set -u
cd "$(dirname "$0")/.."
ZEBRA=${ZEBRA:-./zig-out/bin/zebra}
[ -x "$ZEBRA" ] || ZEBRA=./zig-out/bin/zebra.exe
B=${LIBUI_BINDINGS:-}
if [ -z "$B" ]; then
  for cand in /home/claude/libui-bindings "/c/Projects/zig-libui-ng/src" "C:/Projects/zig-libui-ng/src"; do
    [ -f "$cand/ui.zig" ] && { B=$cand; break; }
  done
fi
[ -f "${B:-/nonexistent}/ui.zig" ] || { echo "libui_section_check: no bindings (set LIBUI_BINDINGS)"; exit 2; }
examples=("$@"); [ ${#examples[@]} -eq 0 ] && examples=(examples/tabs_sci_smoke.zbr examples/styler_smoke.zbr examples/editor_min.zbr examples/editor_events_smoke.zbr)
fail=0
for ex in "${examples[@]}"; do
  name=$(basename "$ex" .zbr); proj="${name}_gui_libui_ng"
  rm -rf "$proj"
  # zebra also tries to `zig build` the project (which fetches the bindings — may
  # fail offline); we only need the emitted src/main.zig, so key on that.
  "$ZEBRA" --gui-backend=libui_ng "$ex" >/dev/null 2>&1
  if [ ! -f "$proj/src/main.zig" ]; then echo "FAIL (codegen): $ex"; fail=1; continue; fi
  if (cd "$proj" && zig build-obj -target x86_64-windows-gnu -fno-emit-bin --dep ui --dep sci -Mroot=src/main.zig --dep ui -Msci="$B/sci.zig" -Mui="$B/ui.zig" 2>&1 | head -30 | grep -q "error:"); then
    echo "FAIL (sema): $ex"; (cd "$proj" && zig build-obj -target x86_64-windows-gnu -fno-emit-bin --dep ui --dep sci -Mroot=src/main.zig --dep ui -Msci="$B/sci.zig" -Mui="$B/ui.zig" 2>&1 | head -30); fail=1
  else
    echo "PASS: $ex (libui_ng section compiles against $B)"
  fi
  rm -rf "$proj"
done
exit $fail
