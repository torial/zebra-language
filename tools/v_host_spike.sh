#!/bin/bash
# The V host spike (2026-10-20, the V docket's item 5, first act): the sandbox
# scene -- a window, a camera, a floor, two cubes (one through rlgl's matrix
# stack), a text line -- through vlang/raylib, N frames drawn uncapped, the
# frame time measured, the window closed. Not a port of the host; the
# question it answers is whether the binding builds and links against the
# raylib the engine already builds, and what a frame costs through it.
#
#   tools/v_host_spike.sh [frames]        (300 by default; V=<path> for another V)
#
# What it needs, and where it finds it:
#   - the binding: ~/.vmodules/raylib (git clone https://github.com/vlang/raylib;
#     a header binding of raylib 5.5 that links a system -lraylib);
#   - raylib's library and headers: the ENGINE's own build -- the first
#     raylib.lib under C:/Projects/GameEngine/.zig-cache/o/*/ that carries no
#     UBSan handler references (the Debug build's does, and V's link has no
#     runtime for them; `zig build -Doptimize=ReleaseFast -p zig-out-fast` in
#     the engine makes a clean one), and raylib.h / rlgl.h beside the
#     package's sources in the same cache.
# What it learned (each a line in the build below): V emits a Windows GUI
# entry (wWinMain, MSVC's freopen_s) for a raylib import unless -subsystem
# console; the binding has no rlgl (tools/host_spike/rlgl_ext.v declares the
# seven calls the host uses); `near` and `far` are Windows macros.
source "$(dirname "${BASH_SOURCE[0]}")/zig_toolchain.sh"   # the PINNED zig, also standalone (hazard_lint H14)
frames=${1:-300}
WT=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=${ENGINE:-/c/Projects/GameEngine}
V=${V:-/c/Projects/v-dist/v/v.exe}
CL=${CLANG:-/c/Projects/llvm-mingw/bin/clang.exe}
NM=${NM:-$(dirname "$CL")/llvm-nm.exe}
OUT=${OUT:-$WT/.zig-cache/v_host_spike}
mkdir -p "$OUT/lib" "$OUT/include"
[ -d "$HOME/.vmodules/raylib" ] || { echo "v_host_spike: no ~/.vmodules/raylib (git clone https://github.com/vlang/raylib there)"; exit 2; }
[ -x "$V" ] || { echo "v_host_spike: no V at $V"; exit 2; }
[ -x "$CL" ] || { echo "v_host_spike: no clang at $CL"; exit 2; }
# the engine's release raylib: the first library without sanitizer hooks
lib=""
for f in "$ENGINE"/.zig-cache/o/*/raylib.lib; do
  [ -f "$f" ] || continue
  if [ "$("$NM" "$f" 2>/dev/null | grep -c '__ubsan_handle')" = 0 ]; then lib="$f"; break; fi
done
[ -n "$lib" ] || { echo "v_host_spike: no sanitizer-free raylib.lib under $ENGINE/.zig-cache/o (build the engine ReleaseFast: zig build -Doptimize=ReleaseFast -p zig-out-fast)"; exit 2; }
hdr=$(ls "$ENGINE"/.zig-cache/o/*/raylib.h 2>/dev/null | head -1)
[ -n "$hdr" ] || { echo "v_host_spike: no raylib.h under $ENGINE/.zig-cache/o"; exit 2; }
cp "$lib" "$OUT/lib/libraylib.a"; cp "$hdr" "$(dirname "$hdr")/rlgl.h" "$OUT/include/"
echo "v_host_spike: $("$V" version), $("$CL" --version | head -1 | cut -c1-40), raylib $(grep -o 'RAYLIB_VERSION  "[^"]*"' "$OUT/include/raylib.h" | cut -d'"' -f2) from $lib"
rm -f "$OUT/sandbox.exe"
"$V" -cc "$CL" -subsystem console -cflags "-Wno-incompatible-pointer-types -I$(cd "$OUT/include" && pwd -W)" -ldflags "-L$(cd "$OUT/lib" && pwd -W) -lgdi32 -lwinmm -luser32 -lshell32 -lopengl32" -gc none -o "$OUT/sandbox.exe" "$WT/tools/host_spike" > "$OUT/build.txt" 2>&1
[ -f "$OUT/sandbox.exe" ] || { echo "v_host_spike: the V build failed:"; grep -E "error" "$OUT/build.txt" | head -6 | cut -c1-200; exit 3; }
echo "  built: $(stat -c %s "$OUT/sandbox.exe") bytes"
timeout 120 "$OUT/sandbox.exe" "$frames" > "$OUT/run.txt" 2>&1; rc=$?
cat "$OUT/run.txt" | tail -2
[ "$rc" = 0 ] && grep -q "^spike: $frames frames" "$OUT/run.txt" && grep -q "cull near 0.05 far 4000" "$OUT/run.txt" && { echo "v_host_spike: ok -- $frames frames drawn through vlang/raylib, rlgl answered (cull 0.05 .. 4000)"; exit 0; }
echo "v_host_spike: FAILED (exit $rc)"; exit 1
