#!/bin/bash
# The libui-ng backend on the V target, witnessed (2026-10-14): each example
# emitted with `--target v --gui-backend=libui_ng`, built with a mingw clang
# against libui-ng's ReleaseFast archive, run headless by ZGUI_SCRIPT, and its
# per-frame trace compared with what the actions must produce. Exit 0 only
# when every case drew what was expected; anything else names the case and
# the step.
#
#   ZEBRA_LIBUI_NG=C:/Projects/libui-ng CLANG=C:/Projects/llvm-mingw/bin/clang.exe \
#     bash tools/v_gui_check.sh
#
# Needs: zig-out/bin/zebra.exe (the V-target compiler), $ZEBRA_LIBUI_NG with
# zig-out-fast/lib/ui.lib (`zig build -Doptimize=ReleaseFast -p zig-out-fast`
# there), a V (v.exe on PATH or $V), a mingw-targeted clang ($CLANG).
set -u
cd "$(dirname "$0")/.." || exit 9
V=${V:-v}
CLANG=${CLANG:-clang}
: "${ZEBRA_LIBUI_NG:?set ZEBRA_LIBUI_NG to a libui-ng checkout with zig-out-fast/lib/ui.lib}"
[ -f "$ZEBRA_LIBUI_NG/zig-out-fast/lib/ui.lib" ] || { echo "v_gui_check: no $ZEBRA_LIBUI_NG/zig-out-fast/lib/ui.lib (zig build -Doptimize=ReleaseFast -p zig-out-fast in libui-ng)"; exit 2; }
OUT=${OUT:-.zig-cache/v_gui_check}; mkdir -p "$OUT"
export ZEBRA_LIBUI_NG
# the Common-Controls v6 manifest, from the Zig scaffold's text in selfhost/main.zbr
sed -n '/^def luiManifest/,/^def /p' selfhost/main.zbr | sed -n '/<?xml/,/<\/assembly>/p' | sed 's/^.*<?xml/<?xml/' > "$OUT/app.manifest"
grep -q "Common-Controls" "$OUT/app.manifest" || { echo "v_gui_check: the manifest text was not found in selfhost/main.zbr"; exit 3; }

# build_and_run <name> <example.zbr> <script>: the trace in $OUT/<name>_run.txt
build_and_run() {
  local name=$1 src=$2 script=$3
  cp "$src" "$OUT/$name.zbr"
  zig-out/bin/zebra.exe --target v --gui-backend=libui_ng "$OUT/$name.zbr" > "$OUT/${name}_emit.txt" 2>&1 || { echo "v_gui_check: $name: the emit failed:"; head -5 "$OUT/${name}_emit.txt"; exit 3; }
  grep -q "the libui_ng section" "$OUT/${name}_emit.txt" || { echo "v_gui_check: $name: the emit did not append the section:"; head -3 "$OUT/${name}_emit.txt"; exit 3; }
  cp "$OUT/app.manifest" "$OUT/$name.exe.manifest"
  "$V" -cc "$CLANG" -cflags "-Wno-incompatible-pointer-types" -subsystem console -gc none -enable-globals -o "$OUT/$name.exe" "$OUT/$name.v" > "$OUT/${name}_build.txt" 2>&1
  [ -f "$OUT/$name.exe" ] || { echo "v_gui_check: $name: the V build failed:"; grep -E "error" "$OUT/${name}_build.txt" | head -6 | cut -c1-200; exit 4; }
  ZGUI_SCRIPT="$script" ZGUI_TRACE=1 "$OUT/$name.exe" > "$OUT/${name}_run.txt" 2> "$OUT/${name}_err.txt"; local rc=$?
  [ $rc = 0 ] || { echo "v_gui_check: $name: the program exited $rc:"; head -3 "$OUT/${name}_err.txt"; exit 5; }
}

# 1. the counter: + + - Reset +, the first frame then each click's effect a frame later
build_and_run counter examples/counter.zbr "click:+;click:+;click:-;click:Reset;click:+;quit"
expected="0 0 1 2 1 0"
got=$(grep -oE "text\(Count: [0-9]+\)" "$OUT/counter_run.txt" | grep -oE "[0-9]+" | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$expected" ] || { echo "v_gui_check: counter FAILED -- the frames drew counts [$got], expected [$expected]:"; cat "$OUT/counter_run.txt"; exit 6; }
echo "v_gui_check: counter ok -- counts [$got] for + + - Reset + ($(wc -l < "$OUT/counter_run.txt") frames)"

# 2. the form: a field set, a spinbox spun, a toggle flipped (each updated in
# place), the Advanced toggle adding its row (a rebuild) and taking it away
build_and_run form examples/form_smoke.zbr "set:Host name=box;spin:Port=443;toggle:Use TLS;toggle:Advanced;tick;spin:Timeout (s)=5;toggle:Advanced;tick;quit"
f() { sed -n "$((1 + $1))p" "$OUT/form_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/form_run.txt")" = 9 ] || fail="9 frames expected, $(wc -l < "$OUT/form_run.txt") drawn"
echo "$(f 2)" | grep -q "field(Host name=box)" || fail="${fail:-frame 2 should show the host name set}"
echo "$(f 3)" | grep -q "spinbox(Port=443)" || fail="${fail:-frame 3 should show the port spun}"
echo "$(f 4)" | grep -q "toggle(Use TLS=off)" || fail="${fail:-frame 4 should show TLS off}"
echo "$(f 5)" | grep -q "spinbox(Timeout (s)=30) toggle(Use TLS=off) toggle(Advanced=on)" || fail="${fail:-frame 5 should show the Timeout row added by the rebuild}"
echo "$(f 7)" | grep -q "spinbox(Timeout (s)=5)" || fail="${fail:-frame 7 should show the timeout spun}"
echo "$(f 8)" | grep -q "toggle(Advanced=off)" && ! echo "$(f 8)" | grep -q "Timeout" || fail="${fail:-frame 8 should show the Timeout row gone}"
echo "$(f 8)" | grep -q "text(box:443 tls=false)" || fail="${fail:-the text of frame 8 should carry every change}"
[ -z "$fail" ] || { echo "v_gui_check: form FAILED -- $fail:"; cat "$OUT/form_run.txt"; exit 6; }
echo "v_gui_check: form ok -- field, spinbox, toggle updated in place; the Advanced row added and removed through the rebuild (9 frames)"

# 3. tabs, a menu, a combobox and a radio (examples/gui_tabs_smoke.zbr, a `using`
# block round the view): the menu item sent, the second page picked, the radio
# picked, the first page again, the combobox picked, a frame to draw it, quit
build_and_run tabs examples/gui_tabs_smoke.zbr "menu:Open;tab:##tabs=1;pick:Size=2;tab:##tabs=0;pick:Colour=2;tick;quit"
t() { sed -n "$((1 + $1))p" "$OUT/tabs_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/tabs_run.txt")" = 7 ] || fail="7 frames expected, $(wc -l < "$OUT/tabs_run.txt") drawn"
echo "$(t 0)" | grep -q "begin_menu(File) menu_item(Open) menu_separator() menu_quit() end_menu()" || fail="${fail:-frame 0 should declare the menu}"
echo "$(t 2)" | grep -q "text(opened 1 colour 0 size 1) tabs(##tabs=1)" || fail="${fail:-frame 2 should show the menu item sent and the second page}"
echo "$(t 4)" | grep -q "size 2) tabs(##tabs=0)" || fail="${fail:-frame 4 should show the radio picked and the first page again}"
echo "$(t 6)" | grep -q "text(opened 1 colour 2 size 2)" || fail="${fail:-frame 6 should show the combobox picked}"
echo "$(t 6)" | grep -q "combobox(Colour=2)" || fail="${fail:-the combobox of frame 6 should read 2}"
[ -z "$fail" ] || { echo "v_gui_check: tabs FAILED -- $fail:"; cat "$OUT/tabs_run.txt"; exit 6; }
echo "v_gui_check: tabs ok -- a menu item sent, pages switched, a radio and a combobox picked, through a using block (7 frames)"

# 4. a table fed immediate-mode, a timer, a double-click and a selection
# (examples/table_strip_smoke.zbr; its Msg is a plain int, its model a class
# with field defaults): the timer ticked twice, row 1 double-clicked, row 2
# selected, a frame to draw it, quit
build_and_run table examples/table_strip_smoke.zbr "tick;tick;dblclick:##rows=1;select:##rows=2;tick;quit"
r() { sed -n "$((1 + $1))p" "$OUT/table_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/table_run.txt")" = 6 ] || fail="6 frames expected, $(wc -l < "$OUT/table_run.txt") drawn"
echo "$(r 0)" | grep -q "text(ticks 0  saved 0  tab -1) table(##rows 3 rows) text(selected -1  activated -1)" || fail="${fail:-frame 0 should show no ticks, three rows, nothing selected or activated (the class defaults)}"
echo "$(r 3)" | grep -q "text(ticks 2 " || fail="${fail:-frame 3 should show two ticks}"
echo "$(r 4)" | grep -q "activated 1)" || fail="${fail:-frame 4 should show row 1 activated}"
echo "$(r 5)" | grep -q "text(selected 2  activated 1)" || fail="${fail:-frame 5 should show row 2 selected}"
[ -z "$fail" ] || { echo "v_gui_check: table FAILED -- $fail:"; cat "$OUT/table_run.txt"; exit 6; }
echo "v_gui_check: table ok -- three rows, the timer ticked, a row activated and another selected (6 frames)"
echo "v_gui_check: ok"
