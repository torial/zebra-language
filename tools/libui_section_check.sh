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
# pins: BUG-343 gui_modules_smoke.zbr `use`s a module named `sci`, compiled against the real libui_ng section
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
examples=("$@"); [ ${#examples[@]} -eq 0 ] && examples=(examples/tabs_sci_smoke.zbr examples/styler_smoke.zbr examples/editor_min.zbr examples/editor_events_smoke.zbr examples/panel_smoke.zbr examples/gui_modules_smoke.zbr)
fail=0
for ex in "${examples[@]}"; do
  name=$(basename "$ex" .zbr)
  # Emit into a scratch dir, not the repo root: `--output-dir .` left <name>.zig, sci.zig
  # and zebra_rt.zig beside the sources on every run (found 2026-09-10; root-clean only
  # watches compiled artifacts, so nothing said so).
  scratch=$(mktemp -d); proj="$scratch/${name}_gui_libui_ng"
  # `--scaffold-only`: write the project, do not `zig build` it. Without it the compiler
  # builds AND RUNS the app -- on Linux that fails fast (no bindings fetch), which is
  # why nobody noticed; on Windows with the bindings fetchable it LAUNCHED the GUI and
  # the first --daily there sat behind a window for 25 minutes (2026-09-10).
  "$ZEBRA" --gui-backend=libui_ng --scaffold-only --output-dir "$scratch" "$ex" >/dev/null 2>&1
  if [ ! -f "$proj/src/main.zig" ]; then echo "FAIL (codegen): $ex"; fail=1; continue; fi
  # 2026-09-09: the GUI section is pub-marked into the shared zebra_rt.zig by a CLOSED list
  # of declaration forms (rtPubMarkSection). A form not on that list is silently private
  # (refuter). Every column-0 declaration in the section region must be `pub` — exact
  # marker lines, not substrings (a prose comment on line 5 mentions the marker).
  if [ -f "$proj/src/zebra_rt.zig" ]; then
    priv=$(awk '/^\/\/ === STDLIB_PREAMBLE_GUI_START ===$/{f=1;next} /^\/\/ === STDLIB_PREAMBLE_GUI_END ===$/{f=0} f' "$proj/src/zebra_rt.zig" \
           | grep -nE '^(fn|inline fn|const|var|threadlocal var|extern fn|export fn|extern var|export var|usingnamespace) ' | head -5)
    if [ -n "$priv" ]; then echo "FAIL (private section decl in zebra_rt.zig): $ex"; echo "$priv" | sed 's/^/    /'; fail=1; continue; fi
  else
    echo "FAIL (no zebra_rt.zig in the scaffold — runtime-module emission is off for GUI?): $ex"; fail=1; continue
  fi
  if (cd "$proj" && zig build-obj -target x86_64-windows-gnu -fno-emit-bin --dep ui --dep sci -Mroot=src/main.zig --dep ui -Msci="$B/sci.zig" -Mui="$B/ui.zig" 2>&1 | head -30 | grep -q "error:"); then
    echo "FAIL (sema): $ex"; (cd "$proj" && zig build-obj -target x86_64-windows-gnu -fno-emit-bin --dep ui --dep sci -Mroot=src/main.zig --dep ui -Msci="$B/sci.zig" -Mui="$B/ui.zig" 2>&1 | head -30); fail=1
  else
    echo "PASS: $ex (libui_ng section compiles against $B)"
  fi
  rm -rf "$scratch"
done
if [ "$fail" = 0 ]; then echo "libui-section: ${#examples[@]}/${#examples[@]} examples compile against the bindings"; else echo "libui-section: FAILED"; fi
exit $fail
