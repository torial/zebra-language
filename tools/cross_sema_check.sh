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
#   x86_64-macos, aarch64-macos   never analysed by anything before 2026-10-04 (libc is
#                           implicit on Darwin). Sema only: nothing here links or runs it.
#
# TWO LEGS per target. PROGRAMS: five runtime-covering programs, emitted and analysed --
# this instantiates the generic runtime (_ZbrList(T)...) the way user code does. RUNTIME
# DECLARATIONS: the emitted zebra_rt.zig with every declaration referenced, recursing into
# its own container types (tools/fixtures/refall_rec.zig) -- this reaches the NON-generic
# helpers no listed program happens to call. Its control is planted every run: a
# @compileError inside a method of a nested struct must be reported, or the leg REFUSES
# (exit 2), because a walk that stopped reaching methods reports a clean runtime.
#
# RECEIPT: the Zig 0.17 toolchain commit (0079ced) passed every gate on Windows and went red
# on its first Linux CI build: `std.os.linux.waitpid` takes `*i32` in 0.17 (`*u32` in 0.16),
# in sys.spawn's isRunning, a branch only a Linux no-libc build analyses. This tool, run on
# that commit, names the same line.
#
# Blind to: runtime behaviour (a wrong syscall that compiles), macOS, and any branch the
# programs below never instantiate AND that is generic (the declarations leg cannot
# instantiate generics). Grow the program set when a generic target-specific path is added.
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
[ ${#targets[@]} -eq 0 ] && targets=(x86_64-windows-gnu x86_64-linux x86_64-linux-gnu x86_64-macos aarch64-macos)
# test/dynlib_roundtrip/host.zbr: Zig's std.DynLib has no Windows arm, so the runtime carries
# a kernel32 loader that ONLY the windows target analyses (a program that never calls
# DynLib.open never instantiates it).
[ ${#files[@]} -eq 0 ] && files=(test/sys_spawn_piped_test.zbr test/sys_process_exit_code_test.zbr test/bug335_json_query_in_method_test.zbr examples/showcase.zbr test/dynlib_roundtrip/host.zbr)
fail=0; checked=0; rtchecked=0; rt=""
tmp=$(mktemp -d)
for f in "${files[@]}"; do
  name=${f##*/}; name=${name%.zbr}
  d="$tmp/$name"; mkdir -p "$d"
  # --output-dir explicitly: --emit-zig alone writes to the TEMP dir.
  "$ZEBRA" --emit-zig --output-dir "$d" "$f" >/dev/null 2>&1
  z="$d/$name.zig"
  if [ ! -f "$z" ]; then echo "FAIL (emit): $f"; fail=1; continue; fi
  [ -z "$rt" ] && [ -f "$d/zebra_rt.zig" ] && rt="$d/zebra_rt.zig"
  for t in "${targets[@]}"; do
    libc=(); case "$t" in *-linux-gnu) libc=(-lc) ;; esac
    if out=$(cd "$d" && zig build-exe -target "$t" "${libc[@]}" -fno-emit-bin "$name.zig" 2>&1); then
      echo "PASS: $f ($t sema)"; checked=$((checked + 1))
    else
      echo "FAIL ($t sema): $f"; echo "$out" | head -12; fail=1
    fi
  done
done
# --- runtime-declarations leg --------------------------------------------------------
rd="$tmp/_rtdecls"; mkdir -p "$rd"
cp "$REPO/tools/fixtures/refall_rec.zig" "$rd/"
if [ -z "$rt" ]; then
  echo "cross-sema: REFUSING -- no program emitted a zebra_rt.zig for the declarations leg"; rm -rf "$tmp"; exit 2
fi
cp "$rt" "$rd/zebra_rt.zig"
printf 'test { @import("refall_rec.zig").refAllRec(@import("zebra_rt.zig"), "zebra_rt.", 4); }
' > "$rd/decls.zig"
# The control: the same runtime plus a planted error two containers deep.
{ cat "$rt"; printf '
pub const _ZzProbeOuter = struct {
    pub const Inner = struct {
        pub fn f() void { @compileError("CROSS-SEMA PLANTED PROBE"); }
    };
};
'; } > "$rd/planted.zig"
printf 'test { @import("refall_rec.zig").refAllRec(@import("planted.zig"), "planted.", 4); }
' > "$rd/control.zig"
if out=$(cd "$rd" && zig test -target x86_64-linux -fno-emit-bin control.zig 2>&1) || ! grep -q 'CROSS-SEMA PLANTED PROBE' <<< "$out"; then
  echo "cross-sema: REFUSING -- the planted nested-method error was NOT reported; the declarations walk is blind"
  echo "$out" | head -8; rm -rf "$tmp"; exit 2
fi
for t in "${targets[@]}"; do
  libc=(); case "$t" in *-linux-gnu) libc=(-lc) ;; esac
  if out=$(cd "$rd" && zig test -target "$t" "${libc[@]}" -fno-emit-bin decls.zig 2>&1); then
    echo "PASS: runtime declarations ($t sema)"; rtchecked=$((rtchecked + 1))
  else
    echo "FAIL ($t sema): runtime declarations"; echo "$out" | head -12; fail=1
  fi
done
rm -rf "$tmp"
# A run that analysed nothing must not read as clean.
if [ "$fail" -eq 0 ] && [ "$checked" -eq 0 ]; then
  echo "cross-sema: REFUSING -- no program was analysed"; exit 2
fi
if [ "$fail" -eq 0 ]; then
  echo "cross-sema: PASS -- $checked program x target + $rtchecked runtime-declaration analyses (${#files[@]} programs, ${#targets[@]} targets; planted control caught)"
else
  echo "cross-sema: FAILED"
fi
exit $fail
