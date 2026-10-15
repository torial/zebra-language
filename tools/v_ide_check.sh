#!/usr/bin/env bash
# v_ide_check.sh -- zebra-ide's headless tests and the IDE itself through the V
# target (2026-10-15). Each test is emitted in the IDE's own tree (the modules
# resolve beside it), the .v moved OUT of that tree at once (Sean's repo stays
# clean), built with V 0.5.2 through llvm-mingw's clang, and run from the
# directory the IDE's own gate runs it from (src/), expecting the line that
# gate expects. A test that names Gui or CodeEditor is emitted with the
# libui_ng section and built with the GUI flags (the V target has no headless
# section). Exit 0 only when every case passes; a case that cannot run says why.
#   IDE=<zebra-ide checkout> ZEBRA=<zebra.exe> V=<v.exe> CLANG=<clang.exe>
#   ZEBRA_LIBUI_NG=<the fork's libui> bash tools/v_ide_check.sh
set -u
IDE=${IDE:-/c/Projects/zebra-ide}
ZEBRA=${ZEBRA:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/zebra.exe}
V=${V:-v}
CLANG=${CLANG:-clang}
export ZEBRA_LIBUI_NG=${ZEBRA_LIBUI_NG:-C:/Projects/zig-libui-ng/libui}
OUT=${OUT:-/c/tmp/ide_v/check}
mkdir -p "$OUT"
[ -d "$IDE/src" ] || { echo "v_ide_check: no $IDE/src (IDE=<zebra-ide checkout>)"; exit 2; }
[ -f "$ZEBRA" ] || { echo "v_ide_check: no $ZEBRA"; exit 2; }
[ -z "$(cd "$IDE" && git status --short)" ] || { echo "v_ide_check: $IDE is not clean before the run: refusing to emit into it"; cd "$IDE" && git status --short; exit 2; }
MANIFEST="$OUT/app.manifest"
sed -n '/<?xml/,/<\/assembly>/p' "$(dirname "$ZEBRA")/../../selfhost/main.zbr" | sed 's/^.*<?xml/<?xml/' > "$MANIFEST"
grep -q "Common-Controls" "$MANIFEST" || { echo "v_ide_check: the manifest text was not found in selfhost/main.zbr"; exit 3; }
fail=0
# case <name> <gui|plain> <expect-regex> <mode last|any> [--test]
case_() {
  local name=$1 kind=$2 pat=$3 mode=$4
  printf "── %s: " "$name"
  local flags=""; [ "$kind" = gui ] && flags="--gui-backend=libui_ng"
  (cd "$IDE" && "$ZEBRA" --target v $flags "src/$name.zbr" > "$OUT/${name}_emit.txt" 2>&1)
  local vf="$IDE/src/${name}_prog.v"; [ -f "$vf" ] || vf="$IDE/src/$name.v"
  if [ ! -f "$vf" ]; then echo "FAIL -- no emission:"; head -3 "$OUT/${name}_emit.txt" | sed 's/^/    | /'; fail=1; return; fi
  mv "$vf" "$OUT/${name}_prog.v"   # (a *_test.v is a V test file: the emitter names it _prog, and so does this)
  [ -z "$(cd "$IDE" && git status --short)" ] || { echo "FAIL -- the IDE tree is not clean after the emit"; (cd "$IDE" && git status --short); fail=1; return; }
  if grep -q "^  refused" "$OUT/${name}_emit.txt"; then echo "FAIL -- refused:"; grep -A6 refused "$OUT/${name}_emit.txt" | sed 's/^/    | /'; fail=1; return; fi
  local bflags="-gc none"
  if [ "$kind" = gui ]; then bflags="-subsystem console -gc none -enable-globals"; cp "$MANIFEST" "$OUT/$name.exe.manifest"; fi
  "$V" -cc "$CLANG" -cflags "-Wno-incompatible-pointer-types" $bflags -o "$OUT/$name.exe" "$OUT/${name}_prog.v" > "$OUT/${name}_build.txt" 2>&1
  if [ ! -f "$OUT/$name.exe" ] || grep -q "error:" "$OUT/${name}_build.txt"; then echo "FAIL -- the V build:"; grep "error:" "$OUT/${name}_build.txt" | head -5 | cut -c1-200 | sed 's/^/    | /'; fail=1; return; fi
  local out; out=$(cd "$IDE/src" && ZGUI_SCRIPT=quit "$OUT/$name.exe" 2>&1); local rc=$?
  local hay="$out"; [ "$mode" = last ] && hay=$(printf '%s\n' "$out" | grep -av "^\s*$" | tail -1)
  if printf '%s\n' "$hay" | grep -aq -- "$pat"; then echo "PASS ($pat)"; else echo "FAIL (exit $rc) -- expected $pat:"; printf '%s\n' "$out" | tail -8 | cut -c1-200 | sed 's/^/    | /'; fail=1; fi
}
case_ sci_test      plain "sci_test: ok"      last
case_ buffers_test  plain "buffers_test: ok"  last
case_ textops_test  plain "textops_test: ok"  last
case_ ignore_test   plain "ignore_test: ok"   last
case_ keys_test     gui   "keys_test: ok"     last
case_ coverage_test plain "^4 passed, 0 failed" any
case_ icons_test    gui   "^3 passed, 0 failed" any
echo "── ide.zbr: the IDE itself, emitted with the libui_ng section and built"
(cd "$IDE" && "$ZEBRA" --target v --gui-backend=libui_ng src/ide.zbr > "$OUT/ide_emit.txt" 2>&1)
if [ -f "$IDE/src/ide.v" ]; then mv "$IDE/src/ide.v" "$OUT/ide.v"; else echo "FAIL -- no emission"; fail=1; fi
[ -z "$(cd "$IDE" && git status --short)" ] || { echo "FAIL -- the IDE tree is not clean after the emit"; fail=1; }
if grep -q "^  refused" "$OUT/ide_emit.txt"; then echo "FAIL -- refused:"; grep -A20 refused "$OUT/ide_emit.txt" | sed 's/^/    | /'; fail=1
elif [ -f "$OUT/ide.v" ]; then
  cp "$MANIFEST" "$OUT/ide.exe.manifest"
  "$V" -cc "$CLANG" -cflags "-Wno-incompatible-pointer-types" -subsystem console -gc none -enable-globals -o "$OUT/ide.exe" "$OUT/ide.v" > "$OUT/ide_build.txt" 2>&1
  if [ ! -f "$OUT/ide.exe" ] || grep -q "error:" "$OUT/ide_build.txt"; then echo "FAIL -- the V build:"; grep "error:" "$OUT/ide_build.txt" | head -8 | cut -c1-200 | sed 's/^/    | /'; fail=1
  else
    echo "PASS -- $OUT/ide.exe ($(stat -c %s "$OUT/ide.exe") bytes)"
    # the IDE run scripted from its own directory: four ticks and quit. Without
    # a compiler to spawn, the status line says it could not start `zebra lsp`
    # and the program goes on (V's os.Process would have ended it: the runtime
    # resolves the program first); with ZEBRA_COMPILER naming one, the status
    # line reaches "zebra lsp" -- the LSP conversation over the piped process.
    printf "── ide.exe without a compiler: "
    out=$(cd "$IDE" && PATH=/nonexistent ZEBRA_COMPILER= ZGUI_SCRIPT="tick;tick;quit" ZGUI_TRACE=1 "$OUT/ide.exe" 2>"$OUT/ide_err1.txt"); rc=$?
    if [ $rc = 0 ] && printf '%s
' "$out" | grep -aq "could not start"; then echo "PASS (the status says it could not start, exit 0)"; else echo "FAIL (exit $rc; expected the could-not-start status):"; printf '%s
' "$out" | grep -ao "text(   Ln[^)]*)" | tail -2 | cut -c1-200 | sed 's/^/    | /'; head -3 "$OUT/ide_err1.txt" | sed 's/^/    | /'; fail=1; fi
    ZC=${ZEBRA_COMPILER:-/c/Projects/zebra-language/zig-out/bin/zebra.exe}
    printf "── ide.exe with ZEBRA_COMPILER=%s: " "$ZC"
    if [ ! -f "$ZC" ]; then echo "SKIP (no compiler at $ZC; ZEBRA_COMPILER=<zebra.exe> names one)"; else
      out=$(cd "$IDE" && ZEBRA_COMPILER="$ZC" ZGUI_SCRIPT="tick;tick;tick;tick;quit" ZGUI_TRACE=1 "$OUT/ide.exe" 2>"$OUT/ide_err2.txt"); rc=$?
      if [ $rc = 0 ] && printf '%s
' "$out" | grep -aq "zebra   zebra lsp   errors"; then echo "PASS (the status line reached zebra lsp: the LSP answered over the pipes)"; else echo "FAIL (exit $rc; expected the lsp status):"; printf '%s
' "$out" | grep -ao "text(   Ln[^)]*)" | tail -2 | cut -c1-200 | sed 's/^/    | /'; head -3 "$OUT/ide_err2.txt" | sed 's/^/    | /'; fail=1; fi
    fi
  fi
fi
[ "$fail" = 0 ] && echo "v_ide_check: ok" || { echo "v_ide_check: FAILED"; exit 1; }
