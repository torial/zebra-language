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
echo "$(r 0)" | grep -q "text(ticks 0  saved 0  tab -1) table(##rows 3 rows: .*) text(selected -1  activated -1)" || fail="${fail:-frame 0 should show no ticks, three rows, nothing selected or activated (the class defaults)}"
echo "$(r 3)" | grep -q "text(ticks 2 " || fail="${fail:-frame 3 should show two ticks}"
echo "$(r 4)" | grep -q "activated 1)" || fail="${fail:-frame 4 should show row 1 activated}"
echo "$(r 5)" | grep -q "text(selected 2  activated 1)" || fail="${fail:-frame 5 should show row 2 selected}"
[ -z "$fail" ] || { echo "v_gui_check: table FAILED -- $fail:"; cat "$OUT/table_run.txt"; exit 6; }
echo "v_gui_check: table ok -- three rows, the timer ticked, a row activated and another selected (6 frames)"

# the cases from here need the FORK checkout (zig-libui-ng/libui: trees, the
# toolbar, tooltips, the clipboard); the plain libui-ng has none of them
if ! grep -q "uiNewTree" "$ZEBRA_LIBUI_NG/ui.h"; then
  echo "v_gui_check: $ZEBRA_LIBUI_NG is not the fork (no uiNewTree in its ui.h): the tree, toolbar and clipboard cases need C:/Projects/zig-libui-ng/libui"; exit 2
fi

# 5. a tree (examples/tree_smoke.zbr): a node selected, another activated, a
# folder expanded through the model, then Close all folding every folder
build_and_run tree examples/tree_smoke.zbr "treesel:files=src/main.zbr;treeact:files=docs/README.md;treeexp:files=docs=1;click:Close all;tick;quit"
u() { sed -n "$((1 + $1))p" "$OUT/tree_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/tree_run.txt")" = 6 ] || fail="6 frames expected, $(wc -l < "$OUT/tree_run.txt") drawn"
echo "$(u 0)" | grep -q "tree(files src/\[+main.zbr Parser.zbr gui/\[-tree.zbr\]\] docs/\[-README.md\] build.zbr)" || fail="${fail:-frame 0 should draw the tree with src open and the rest closed}"
echo "$(u 2)" | grep -q "text(selected: src/main.zbr  opened: )" || fail="${fail:-frame 2 should show the selection}"
echo "$(u 3)" | grep -q "opened: docs/README.md)" || fail="${fail:-frame 3 should show the activation}"
echo "$(u 4)" | grep -q "docs/\[+README.md\]" || fail="${fail:-frame 4 should show docs expanded through the model}"
echo "$(u 5)" | grep -q "src/\[-main.zbr Parser.zbr gui/\[-tree.zbr\]\] docs/\[-README.md\]" || fail="${fail:-frame 5 should show every folder closed}"
[ -z "$fail" ] || { echo "v_gui_check: tree FAILED -- $fail:"; cat "$OUT/tree_run.txt"; exit 6; }
echo "v_gui_check: tree ok -- selected, activated, expanded through the model, all closed (6 frames)"

# 6. the toolbar (examples/toolbar_smoke.zbr): Build, Run (Stop enabled while
# running), Stop, then Clear (the item that appears after the first click)
build_and_run toolbar examples/toolbar_smoke.zbr "tool:Build;tool:Run;tool:Stop;tick;tool:Clear;tick;quit"
w() { sed -n "$((1 + $1))p" "$OUT/toolbar_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/toolbar_run.txt")" = 7 ] || fail="7 frames expected, $(wc -l < "$OUT/toolbar_run.txt") drawn"
echo "$(w 0)" | grep -q "toolbar(Build Run Stop(off)) text(state: idle)" || fail="${fail:-frame 0 should show Stop disabled and the state idle}"
echo "$(w 2)" | grep -q "toolbar(Build Run Stop(off) | Clear) text(state: built) text(clicks: 1)" || fail="${fail:-frame 2 should show the Clear item appear after Build}"
echo "$(w 3)" | grep -q "toolbar(Build Run Stop | Clear) text(state: running)" || fail="${fail:-frame 3 should show Stop enabled while running}"
echo "$(w 6)" | grep -q "toolbar(Build Run Stop(off)) text(state: ) text(clicks: 0)" || fail="${fail:-frame 6 should show the strip cleared}"
[ -z "$fail" ] || { echo "v_gui_check: toolbar FAILED -- $fail:"; cat "$OUT/toolbar_run.txt"; exit 6; }
echo "v_gui_check: toolbar ok -- items sent, enabled per frame, an item appearing and going (7 frames)"

# 7. tooltips and the clipboard (examples/tooltip_clipboard_smoke.zbr): the
# field set, copied, pasted back through the system clipboard (which this
# case OVERWRITES with the text), a node of an iconed tree picked
build_and_run clip examples/tooltip_clipboard_smoke.zbr "set:Text=zebra on v;click:Copy;click:Paste;tick;treesel:files=src/todo;tick;quit"
c() { sed -n "$((1 + $1))p" "$OUT/clip_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/clip_run.txt")" = 7 ] || fail="7 frames expected, $(wc -l < "$OUT/clip_run.txt") drawn"
echo "$(c 4)" | grep -q "text(pasted: zebra on v)" || fail="${fail:-frame 4 should show the text pasted back from the clipboard}"
echo "$(c 6)" | grep -q "text(picked: src/todo)" || fail="${fail:-frame 6 should show the tree node picked}"
[ -z "$fail" ] || { echo "v_gui_check: clip FAILED -- $fail:"; cat "$OUT/clip_run.txt"; exit 6; }
echo "v_gui_check: clip ok -- copied and pasted through the clipboard, a tree node picked (7 frames)"

# 8. the dialogs (examples/file_dialog_smoke.zbr): Open File answered, Save
# File cancelled (the status stays), Open Folder answered, an alert and an
# error shown -- scripted, a dialog's answer comes from `dialog:` and the
# trace records what opened
build_and_run dialogs examples/file_dialog_smoke.zbr "dialog:C:/tmp/a.txt;click:Open File;tick;dialog:;click:Save File;tick;dialog:C:/tmp;click:Open Folder;tick;click:Show Alert;tick;click:Show Error;tick;quit"   # hazard-ok:H12 a scripted dialog ANSWER (data the test asserts), not a scratch path anything writes
d() { sed -n "$((1 + $1))p" "$OUT/dialogs_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/dialogs_run.txt")" = 14 ] || fail="14 frames expected, $(wc -l < "$OUT/dialogs_run.txt") drawn"
echo "$(d 3)" | grep -q "dialogs(open_file)" || fail="${fail:-frame 3 should record the open dialog}"
echo "$(d 4)" | grep -q "text(Status: Opened: C:/tmp/a.txt)" || fail="${fail:-frame 4 should show the opened path}"   # hazard-ok:H12 a scripted dialog ANSWER (data the test asserts), not a scratch path anything writes
echo "$(d 6)" | grep -q "dialogs(save_file) text(File Dialog Smoke Test) text(Status: Opened: C:/tmp/a.txt)" || fail="${fail:-frame 6 should record the save dialog with the status unchanged}"   # hazard-ok:H12 a scripted dialog ANSWER (data the test asserts), not a scratch path anything writes
echo "$(d 7)" | grep -q "text(Status: Opened: C:/tmp/a.txt)" || fail="${fail:-frame 7 should keep the status after the cancelled save}"   # hazard-ok:H12 a scripted dialog ANSWER (data the test asserts), not a scratch path anything writes
echo "$(d 10)" | grep -q "text(Status: Folder: C:/tmp)" || fail="${fail:-frame 10 should show the folder}"
echo "$(d 11)" | grep -q "dialogs(msgbox(File Dialogs))" || fail="${fail:-frame 11 should record the alert}"
echo "$(d 13)" | grep -q "dialogs(msgbox_error(Error))" || fail="${fail:-frame 13 should record the error box}"
[ -z "$fail" ] || { echo "v_gui_check: dialogs FAILED -- $fail:"; cat "$OUT/dialogs_run.txt"; exit 6; }
echo "v_gui_check: dialogs ok -- open answered, save cancelled, folder answered, an alert and an error recorded (14 frames)"

# 9. the editable combobox (examples/combobox_editable_smoke.zbr): a path typed,
# then Last (the model picks the last recent item)
build_and_run editcombo examples/combobox_editable_smoke.zbr "set:Open=lib/x.zbr;click:Last;tick;quit"
e() { sed -n "$((1 + $1))p" "$OUT/editcombo_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/editcombo_run.txt")" = 4 ] || fail="4 frames expected, $(wc -l < "$OUT/editcombo_run.txt") drawn"
echo "$(e 2)" | grep -q "editcombo(Open=lib/x.zbr) text(path: lib/x.zbr)" || fail="${fail:-frame 2 should show the typed path}"
echo "$(e 3)" | grep -q "text(path: src/main.zbr)" || fail="${fail:-frame 3 should show the last recent item}"
[ -z "$fail" ] || { echo "v_gui_check: editcombo FAILED -- $fail:"; cat "$OUT/editcombo_run.txt"; exit 6; }
echo "v_gui_check: editcombo ok -- a path typed, the last recent picked (4 frames)"

# 10. a check column (examples/table_check_smoke.zbr): row 1 checked through
# the column's closure, then None and All through the buttons
build_and_run tcheck examples/table_check_smoke.zbr "cellcheck:##files=1=1;click:None;click:All;tick;quit"
k() { sed -n "$((1 + $1))p" "$OUT/tcheck_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/tcheck_run.txt")" = 5 ] || fail="5 frames expected, $(wc -l < "$OUT/tcheck_run.txt") drawn"
echo "$(k 0)" | grep -q "table(##files 3 rows: \[1 main.zbr\] \[0 Parser.zbr\] \[1 README.md\]) text(Save 2 of 3)" || fail="${fail:-frame 0 should show the initial checks}"
echo "$(k 2)" | grep -q "\[1 Parser.zbr\]" || fail="${fail:-frame 2 should show row 1 checked}"
echo "$(k 3)" | grep -q "text(Save 0 of 3)" || fail="${fail:-frame 3 should show none checked}"
echo "$(k 4)" | grep -q "text(Save 3 of 3)" || fail="${fail:-frame 4 should show all checked}"
[ -z "$fail" ] || { echo "v_gui_check: tcheck FAILED -- $fail:"; cat "$OUT/tcheck_run.txt"; exit 6; }
echo "v_gui_check: tcheck ok -- a check cell toggled through its column's closure, None and All (5 frames)"

# 11. an edit column and a button column (examples/table_edit_smoke.zbr): a
# rename, an empty rename refused by update, a row removed by its button
build_and_run tedit examples/table_edit_smoke.zbr "celledit:##names=1=delta;celledit:##names=0=;cellbutton:##names=2;tick;quit"
j() { sed -n "$((1 + $1))p" "$OUT/tedit_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/tedit_run.txt")" = 5 ] || fail="5 frames expected, $(wc -l < "$OUT/tedit_run.txt") drawn"
echo "$(j 2)" | grep -q "\[delta Remove\].*text(3 names; row 1 -> delta)" || fail="${fail:-frame 2 should show the rename}"
echo "$(j 3)" | grep -q "text(3 names; empty name refused for row 0)" || fail="${fail:-frame 3 should show the refusal}"
echo "$(j 4)" | grep -q "table(##names 2 rows: \[alpha Remove\] \[delta Remove\]) text(2 names; removed row 2)" || fail="${fail:-frame 4 should show the row removed}"
[ -z "$fail" ] || { echo "v_gui_check: tedit FAILED -- $fail:"; cat "$OUT/tedit_run.txt"; exit 6; }
echo "v_gui_check: tedit ok -- a cell renamed, an empty rename refused, a row removed by its button (5 frames)"

# 12. an area (examples/area_smoke.zbr): the board painted (a fill, four
# lines, a text), a click in the middle cell, Clear. libui paints
# asynchronously, so the painted words lag the model by one frame: the
# circle the click adds is in the trace the frame after the model shows it
build_and_run area examples/area_smoke.zbr "mouse:board=1,120,120,1;tick;click:Clear;tick;quit"
p() { sed -n "$((1 + $1))p" "$OUT/area_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/area_run.txt")" = 5 ] || fail="5 frames expected, $(wc -l < "$OUT/area_run.txt") drawn"
echo "$(p 0)" | grep -q "area(board fillRect line line line line text)" || fail="${fail:-frame 0 should show the board painted}"
echo "$(p 2)" | grep -q "text(clicks: 1)" || fail="${fail:-frame 2 should count the click}"
grep -q "fillCircle" "$OUT/area_run.txt" || fail="${fail:-some frame should paint the clicked cell}"
echo "$(p 4)" | grep -q "text(clicks: 0)" || fail="${fail:-frame 4 should show the board cleared}"
[ -z "$fail" ] || { echo "v_gui_check: area FAILED -- $fail:"; cat "$OUT/area_run.txt"; exit 6; }
echo "v_gui_check: area ok -- the board painted, a cell clicked and filled, cleared (5 frames)"

# 13. a canvas (examples/canvas_smoke.zbr): a press near the dot, a drag, a
# release, an enter, a key (A with ctrl), each named by the model
build_and_run canvas examples/canvas_smoke.zbr "mouse:dot=1,62,58,1;mouse:dot=3,100,90,1;mouse:dot=2,100,90,1;mouse:dot=4,-1,-1,0;key:dot=65,1,1;tick;quit"
q() { sed -n "$((1 + $1))p" "$OUT/canvas_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/canvas_run.txt")" = 7 ] || fail="7 frames expected, $(wc -l < "$OUT/canvas_run.txt") drawn"
echo "$(q 0)" | grep -q "canvas(dot fillRect fillCircle) text(last: nothing yet  at 60.0,60.0)" || fail="${fail:-frame 0 should paint the dot}"
echo "$(q 2)" | grep -q "text(last: press " || fail="${fail:-frame 2 should show the press}"
echo "$(q 3)" | grep -q "text(last: drag  at 100.0,90.0)" || fail="${fail:-frame 3 should show the drag moving the dot}"
echo "$(q 4)" | grep -q "text(last: release " || fail="${fail:-frame 4 should show the release}"
echo "$(q 5)" | grep -q "text(last: enter " || fail="${fail:-frame 5 should show the enter}"
echo "$(q 6)" | grep -q "text(last: key 65 " || fail="${fail:-frame 6 should show the key}"
[ -z "$fail" ] || { echo "v_gui_check: canvas FAILED -- $fail:"; cat "$OUT/canvas_run.txt"; exit 6; }
echo "v_gui_check: canvas ok -- press, drag, release, enter and a key through the canvas's closures (7 frames)"

# 14. the code editor (examples/editor_events_smoke.zbr), over the fork's
# Scintilla shim (zig-libui-ng/zig-out-fast/lib/sci_native.lib): an edit
# appended through Scintilla, a Ctrl+S chord, a margin click, each taken by a
# tick and counted by the model; the style tally is read back from the
# control (SCI_GETSTYLEAT per byte: what it shows, not what the tokenizer
# said) -- "def main()\n    print(\"events\")\n" is def and print as
# keywords (8 bytes), main as a function (4), "events" as a string (8), four
# brackets -- and the appended "def" is restyled by the next frame (11)
[ -f "$ZEBRA_LIBUI_NG/../zig-out-fast/lib/sci_native.lib" ] || { echo "v_gui_check: no $ZEBRA_LIBUI_NG/../zig-out-fast/lib/sci_native.lib (zig build -Doptimize=ReleaseFast -p zig-out-fast in zig-libui-ng, with the install line for sci_native): the editor case needs it"; exit 2; }
build_and_run editor examples/editor_events_smoke.zbr "edtype:def;click:tick;edkey:83,1;click:tick;edmargin:1;click:tick;tick;quit"
v() { sed -n "$((1 + $1))p" "$OUT/editor_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/editor_run.txt")" = 8 ] || fail="8 frames expected, $(wc -l < "$OUT/editor_run.txt") drawn"
echo "$(v 0)" | grep -q "text(modified=0  char=0  margin=-1  key=0 (mods<<16|vk)) editor(3 lines kw=8 cm=0 st=8 nu=0 ty=0 fn=4 op=4 pp=0)" || fail="${fail:-frame 0 should show the editor with its three lines styled and no events}"
echo "$(v 1)" | grep -q "editor(3 lines kw=11 " || fail="${fail:-frame 1 should show the appended def restyled as a keyword}"
echo "$(v 3)" | grep -q "text(modified=1 " || fail="${fail:-frame 3 should count the edit as modified}"
echo "$(v 5)" | grep -q "key=65619 " || fail="${fail:-frame 5 should show the Ctrl+S chord}"
echo "$(v 7)" | grep -q "margin=1 " || fail="${fail:-frame 7 should show the margin line clicked}"
[ -z "$fail" ] || { echo "v_gui_check: editor FAILED -- $fail:"; cat "$OUT/editor_run.txt"; exit 6; }
echo "v_gui_check: editor ok -- an edit, a chord and a margin click through Scintilla, each counted; the text styled, the edit restyled (8 frames)"

# 15. a GUI program of two modules (examples/gui_modules_smoke.zbr with
# examples/sci.zbr): an editor made in the used module and handed across,
# its line count printed before the window, a one-variant union's message
# counted by the GUI
cp examples/sci.zbr "$OUT/sci.zbr"
build_and_run modules examples/gui_modules_smoke.zbr "click:+1;tick;quit"
fail=""
grep -q "^lines=2$" "$OUT/modules_run.txt" || fail="the used module's line count should print lines=2 before the window"
grep -q "text(modules: 2) button(+1)" "$OUT/modules_run.txt" || fail="${fail:-the +1 message should count to 2}"
[ -z "$fail" ] || { echo "v_gui_check: modules FAILED -- $fail:"; cat "$OUT/modules_run.txt"; exit 6; }
echo "v_gui_check: modules ok -- two modules, an editor handed across, a one-variant union counted"

# 16. the styler's three controls (examples/styler_smoke.zbr, the IDE plan's):
# each editor's style tally read back from its control. C: the # inside a
# string is STRING and #include is PREPROC, never COMMENT (cm=33 is the block
# comment and the trailing one; a # read as a comment would make it 48).
# Zig: the two \\ lines are STRING (13 of the 25) and @import is FUNC (7 of
# the 16). Zebra: the ${} interpolation stays inside the STRING (27 bytes)
# and # is a comment (11). Counted by hand from the example's texts.
build_and_run styler examples/styler_smoke.zbr "tick;quit"
y() { sed -n "$((1 + $1))p" "$OUT/styler_run.txt"; }
fail=""
echo "$(y 0)" | grep -q "page(greet.zbr) editor(4 lines kw=9 cm=11 st=27 nu=0 ty=0 fn=5 op=4 pp=0)" || fail="the zebra editor should style def and return, the comment and the interpolated string"
echo "$(y 0)" | grep -q "page(main.c) editor(8 lines kw=22 cm=33 st=20 nu=6 ty=0 fn=4 op=10 pp=18)" || fail="${fail:-the c editor should style #include as preproc and the # in the string as string}"
echo "$(y 0)" | grep -q "page(main.zig) editor(9 lines kw=19 cm=0 st=25 nu=0 ty=0 fn=16 op=17 pp=0)" || fail="${fail:-the zig editor should style the multiline-string lines and @import}"
[ -z "$fail" ] || { echo "v_gui_check: styler FAILED -- $fail:"; cat "$OUT/styler_run.txt"; exit 6; }
echo "v_gui_check: styler ok -- zebra, c and zig styled as the IDE plan's three controls say (the tallies read back from Scintilla)"

# 17. the hatch (examples/sci_hatch_smoke.zbr): sci() before the control
# exists reads 0; Set sends SCI_SETTEXT through sciStr and reads
# SCI_GETLENGTH back (14, the text's bytes); the set moved the end-styled
# watermark back, so the commit's restyle styles the C comment: cm=13 (the
# thirteen before the newline), read back from the control
build_and_run hatch examples/sci_hatch_smoke.zbr "click:Set;tick;tick;quit"
z() { sed -n "$((1 + $1))p" "$OUT/hatch_run.txt"; }
fail=""
[ "$(wc -l < "$OUT/hatch_run.txt")" = 4 ] || fail="4 frames expected, $(wc -l < "$OUT/hatch_run.txt") drawn"
echo "$(z 0)" | grep -q "text(early=0 len=-1) editor(1 lines kw=0 cm=0 " || fail="${fail:-frame 0 should read 0 from the hatch before the control and show the editor empty}"
echo "$(z 2)" | grep -q "text(early=0 len=14) editor(2 lines kw=0 cm=13 st=0 " || fail="${fail:-frame 2 should show the length read back through the hatch and the set text restyled as a comment}"
[ -z "$fail" ] || { echo "v_gui_check: hatch FAILED -- $fail:"; cat "$OUT/hatch_run.txt"; exit 6; }
echo "v_gui_check: hatch ok -- a Scintilla message sent and one read back through sci / sciStr, the set text restyled (4 frames)"

# 18. window hotkeys and minSize (examples/table_strip_smoke.zbr): a Ctrl+S
# key-down to the window's hook is taken by the view and sent as a message
# (saved 1 a frame later); the side pane's minSize is applied to the
# container built the frame before (the trace says what was applied; the
# control's own minimum is not read back)
build_and_run strip examples/table_strip_smoke.zbr "winkey:83,1;tick;tick;quit"
x() { sed -n "$((1 + $1))p" "$OUT/strip_run.txt"; }
fail=""
echo "$(x 0)" | grep -q "text(ticks 0  saved 0 " || fail="frame 0 should show nothing saved"
echo "$(x 2)" | grep -q "saved 1 " || fail="${fail:-frame 2 should show the Ctrl+S chord taken and sent}"
echo "$(x 1)" | grep -q "begin_vbox(##side min 240x0)" || fail="${fail:-frame 1 should say the side pane minimum size was applied}"
[ -z "$fail" ] || { echo "v_gui_check: strip FAILED -- $fail:"; cat "$OUT/strip_run.txt"; exit 6; }
echo "v_gui_check: strip ok -- a window chord taken through the hook, the side pane given its minimum (4 frames)"
echo "v_gui_check: ok"
