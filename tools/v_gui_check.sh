#!/bin/bash
# The libui-ng proof of concept on the V target, witnessed (2026-10-14):
# examples/counter.zbr emitted with `--target v --gui-backend=libui_ng`,
# built with a mingw clang against libui-ng's ReleaseFast archive, run
# headless by ZGUI_SCRIPT, and its per-frame trace compared with the counts
# the clicks must produce. Exit 0 only when the window drew every expected
# frame; anything else names the step.
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
cp examples/counter.zbr "$OUT/counter.zbr"
zig-out/bin/zebra.exe --target v --gui-backend=libui_ng "$OUT/counter.zbr" > "$OUT/emit.txt" 2>&1 || { echo "v_gui_check: the emit failed:"; head -5 "$OUT/emit.txt"; exit 3; }
grep -q "the libui_ng section" "$OUT/emit.txt" || { echo "v_gui_check: the emit did not append the section:"; head -3 "$OUT/emit.txt"; exit 3; }
# the Common-Controls v6 manifest, from the Zig scaffold's text in selfhost/main.zbr
sed -n '/^def luiManifest/,/^def /p' selfhost/main.zbr | sed -n '/<?xml/,/<\/assembly>/p' | sed 's/^.*<?xml/<?xml/' > "$OUT/counter.exe.manifest"
grep -q "Common-Controls" "$OUT/counter.exe.manifest" || { echo "v_gui_check: the manifest text was not found in selfhost/main.zbr"; exit 3; }
export ZEBRA_LIBUI_NG
"$V" -cc "$CLANG" -cflags "-Wno-incompatible-pointer-types" -subsystem console -gc none -enable-globals -o "$OUT/counter.exe" "$OUT/counter.v" > "$OUT/build.txt" 2>&1
[ -f "$OUT/counter.exe" ] || { echo "v_gui_check: the V build failed:"; grep -E "error" "$OUT/build.txt" | head -6 | cut -c1-200; exit 4; }
ZGUI_SCRIPT="click:+;click:+;click:-;click:Reset;click:+;quit" ZGUI_TRACE=1 "$OUT/counter.exe" > "$OUT/run.txt" 2> "$OUT/run_err.txt"; rc=$?
[ $rc = 0 ] || { echo "v_gui_check: the program exited $rc:"; head -3 "$OUT/run_err.txt"; exit 5; }
# the counts the clicks must draw: the first frame, then each click's effect a frame later
expected="0 0 1 2 1 0"
got=$(grep -oE "text\(Count: [0-9]+\)" "$OUT/run.txt" | grep -oE "[0-9]+" | tr '\n' ' ' | sed 's/ $//')
if [ "$got" != "$expected" ]; then echo "v_gui_check: FAILED -- the frames drew counts [$got], expected [$expected]:"; cat "$OUT/run.txt"; exit 6; fi
echo "v_gui_check: ok -- the counter through the V target and libui-ng drew counts [$got] for + + - Reset + ($(wc -l < "$OUT/run.txt") frames)"
