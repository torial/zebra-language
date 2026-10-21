#!/bin/bash
# The CLANG lane (2026-10-14; into the repo 2026-10-20 with the release
# flags and a fresh emit): eleven engine roots emitted to V by this
# checkout's zebra.exe, built with llvm-mingw's clang (C:/Projects/llvm-mingw,
# clang 23, x86_64-w64-windows-gnu, lld) under V 0.5.2 or V master, debug or
# the release shape, run from the engine root, diffed against the harness
# control (the Zig build's output, `N ms` normalised). No wrapper: V sees a
# file named clang.exe and drives its clang path. 0.5.2 needs
# -Wno-incompatible-pointer-types under a clang 22+ (u32* for LPDWORD in its
# generated C; fixed on master 75da3f80).
#
#   tools/v_clang_lane.sh 052|master [prod|boehm]
#
# The release shape (`prod`) is `-prod -prealloc`: V's bump allocator with
# the optimizer, measured 2026-10-20 at 1.1x the Zig ReleaseFast build on the
# compiler's own emit (1.76 s / 402 MB against 1.57 s / 360 MB) where -prod
# alone was 1.7x. A prealloc build never frees, so it is the shape for a
# compiler run or a test; `boehm` (`-prod -gc boehm`) is the long-running
# shape (a game server), a tenth slower and the smallest process. tcc cannot
# compile the prealloc C, which is why this lane is clang's.
#
# Each root is emitted afresh (`zebra --target v --module-path zbra`) into
# $VD/eng/<name>.v before its build, so the lane reads the emitter as it is,
# not a stored emission; a root it cannot find or emit is said and skipped.
source "$(dirname "${BASH_SOURCE[0]}")/zig_toolchain.sh"   # the PINNED zig, also standalone (hazard_lint H14)
ver=$1; mode=$2
VD=${VD:-/c/Projects/v-dist}
CL=${CLANG:-/c/Projects/llvm-mingw/bin/clang.exe}
ENGINE=${ENGINE:-/c/Projects/GameEngine}
ZEBRA=${ZEBRA:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/zebra.exe}
case "$ver" in
  052) V=${V052:-$VD/v/v.exe}; suf=""; extra="-cflags -Wno-incompatible-pointer-types" ;;
  # master: the os module's WriteFile caller passes &u32 for &C.DWORD (vlang/v#30587);
  # clang 22+ errors on it. The flag keeps the lane whole until the fix lands; drop it then.
  master) V=${VMASTER:-/c/Projects/v-master/v.exe}; suf="_master"; extra="-cflags -Wno-error=incompatible-pointer-types" ;;
  *) echo "usage: tools/v_clang_lane.sh 052|master [prod|boehm]"; exit 2 ;;
esac
case "$mode" in
  prod) pflag="-prod -prealloc" ;;
  boehm) pflag="-prod -gc boehm" ;;
  "") pflag="" ;;
  *) echo "usage: tools/v_clang_lane.sh 052|master [prod|boehm]"; exit 2 ;;
esac
[ -x "$V" ] || { echo "no $V"; exit 1; }
[ -x "$CL" ] || { echo "no $CL"; exit 1; }
[ -x "$ZEBRA" ] || { echo "no $ZEBRA (build the checkout, or ZEBRA=<path>)"; exit 1; }
cd "$ENGINE" || exit 9
mkdir -p "$VD/eng/clang_src"
echo "clang lane: $($V version), ${mode:-debug}${pflag:+ ($pflag)}, $($CL --version | head -1), emitter $ZEBRA"
for b in signal_test instance_test tween_test health_test tags_test guiscene_test guitree_test player_handler_test round_test datastore_test demo_test; do
  # the root's source: zbra/<name>.zbr, else game/mm/<name>.zbr
  src_zbr=""
  for d in zbra game/mm game/tuon game; do [ -f "$d/$b.zbr" ] && { src_zbr="$d/$b.zbr"; break; }; done
  [ -n "$src_zbr" ] || { echo "$b: no source $b.zbr under zbra/ or game/"; continue; }
  if [ -n "$suf" ]; then f=${b%_test}$suf; else f=$b; fi
  # a fresh emission: a *_test root is written as <stem>_prog.v beside its
  # source (a file named *_test.v is a test file to V), moved under the lane's name
  "$ZEBRA" --target v --module-path zbra "$src_zbr" > "$VD/eng/emit_$f.log" 2>&1
  stem=$(basename "$src_zbr" .zbr); dir=$(dirname "$src_zbr")
  case "$stem" in *_test) emitted="$dir/${stem}_prog.v" ;; *) emitted="$dir/$stem.v" ;; esac
  [ -f "$emitted" ] || { echo "$b: EMIT FAILED:"; grep -E "refused|error" "$VD/eng/emit_$f.log" | head -3 | cut -c1-160; continue; }
  mv "$emitted" "$VD/eng/$f.v"
  if grep -q "^    " "$VD/eng/emit_$f.log"; then echo "$b: refused:"; grep "^    " "$VD/eng/emit_$f.log" | head -3 | cut -c1-160; continue; fi
  tag=${f}_clang${mode:+_$mode}
  src="$VD/eng/clang_src/${b%_test}_prog.v"; cp "$VD/eng/$f.v" "$src"
  { time $V $pflag -cc "$CL" $extra -gc none -enable-globals -o "$VD/eng/$tag.exe" "$src" > "$VD/eng/build_$tag.log" 2>&1; } 2>&1 | grep real | sed "s/^/  $b build /"
  printf "%s under %s clang %s: " $b $ver "${mode:-debug}"
  if [ ! -f "$VD/eng/$tag.exe" ]; then echo "BUILD FAILED ($(grep -c 'error' "$VD/eng/build_$tag.log") error lines)"; grep -E 'error' "$VD/eng/build_$tag.log" | head -2 | cut -c1-160; continue; fi
  "$VD/eng/$tag.exe" 2>"$VD/eng/err_$tag.txt" | sed -E 's/[0-9]+ ms/N ms/g' > "$VD/eng/out_$tag.txt"
  if diff -q "$VD/eng/out_$tag.txt" "$VD/eng/control_${b}_norm.txt" >/dev/null; then echo "IDENTICAL ($(wc -l < "$VD/eng/control_$b.txt") lines)"; else echo "DIFFERS"; diff "$VD/eng/out_$tag.txt" "$VD/eng/control_${b}_norm.txt" | head -6 | cut -c1-160; fi
done
