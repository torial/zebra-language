#!/usr/bin/env bash
# cross_sema_check.sh — THE OTHER-OS COMPILE WITNESS, registered as `cross-sema` (FAST tier,
# 2026-10-04). Emits Zebra programs with the selfhost and runs `zig build-exe -fno-emit-bin`
# on the output for each target below: full semantic analysis of every
# `comptime builtin.os.tag == ...` / `builtin.link_libc` branch of the runtime that THIS
# host's builds never reach. No linking, no second machine.
#
#   x86_64-windows-gnu      the Win32 branches (was tools/win_sema_check.sh, 2026-09-07,
#                           which found the PeekNamedPipe BOOL-vs-0 comparison and the
#                           kernel32 DynLib loader).
#   x86_64-linux            Linux WITHOUT libc: the raw-syscall branches, which is what the
#                           fast `-fno-llvm -fno-lld` path builds on Linux.
#   x86_64-linux-gnu -lc    Linux WITH libc: the `std.c` branches.
#
# RECEIPT: the Zig 0.17 toolchain commit (0079ced) passed every gate on Windows and went red
# on its first Linux CI build: `std.os.linux.waitpid` takes `*i32` in 0.17 (`*u32` in 0.16),
# in sys.spawn's isRunning, a branch only a Linux no-libc build analyses. This tool, run on
# that commit, names the same line.
#
# Blind to: runtime behaviour (a wrong syscall that compiles), macOS, and any branch the
# programs below never instantiate (Zig analyses lazily -- a runtime helper no program
# calls is not checked). Grow the set when a target-specific branch is added.
#
# Usage: tools/cross_sema_check.sh [--target T]... [file.zbr ...]
#        (default: all three targets over a runtime-covering set)
# pins: BUG-523 the runtime did not compile for Linux without libc under Zig 0.17 (waitpid *i32)
set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
. "$REPO/tools/zig_toolchain.sh"
ZEBRA=${ZEBRA:-./zig-out/bin/zebra}; [ -x "$ZEBRA" ] || ZEBRA=./zig-out/bin/zebra.exe
targets=(); files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --target) targets+=("$2"); shift 2 ;;
    *) files+=("$1"); shift ;;
  esac
done
[ ${#targets[@]} -eq 0 ] && targets=(x86_64-windows-gnu x86_64-linux x86_64-linux-gnu)
# test/dynlib_roundtrip/host.zbr: Zig's std.DynLib has no Windows arm, so the runtime carries
# a kernel32 loader that ONLY the windows target analyses (a program that never calls
# DynLib.open never instantiates it).
[ ${#files[@]} -eq 0 ] && files=(test/sys_spawn_piped_test.zbr test/sys_process_exit_code_test.zbr test/bug335_json_query_in_method_test.zbr examples/showcase.zbr test/dynlib_roundtrip/host.zbr)
fail=0; checked=0
tmp=$(mktemp -d)
for f in "${files[@]}"; do
  name=${f##*/}; name=${name%.zbr}
  d="$tmp/$name"; mkdir -p "$d"
  # --output-dir explicitly: --emit-zig alone writes to the TEMP dir.
  "$ZEBRA" --emit-zig --output-dir "$d" "$f" >/dev/null 2>&1
  z="$d/$name.zig"
  if [ ! -f "$z" ]; then echo "FAIL (emit): $f"; fail=1; continue; fi
  for t in "${targets[@]}"; do
    libc=(); case "$t" in *-linux-gnu) libc=(-lc) ;; esac
    if out=$(cd "$d" && zig build-exe -target "$t" "${libc[@]}" -fno-emit-bin "$name.zig" 2>&1); then
      echo "PASS: $f ($t sema)"; checked=$((checked + 1))
    else
      echo "FAIL ($t sema): $f"; echo "$out" | head -12; fail=1
    fi
  done
done
rm -rf "$tmp"
# A run that analysed nothing must not read as clean.
if [ "$fail" -eq 0 ] && [ "$checked" -eq 0 ]; then
  echo "cross-sema: REFUSING -- no program was analysed"; exit 2
fi
if [ "$fail" -eq 0 ]; then
  echo "cross-sema: PASS -- $checked program x target analyses (${#files[@]} programs, ${#targets[@]} targets)"
else
  echo "cross-sema: FAILED"
fi
exit $fail
