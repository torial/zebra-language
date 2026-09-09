#!/usr/bin/env bash
# win_sema_check.sh — THE WINDOWS COMPILE WITNESS WITHOUT WINDOWS (2026-09-07).
# Emits Zebra programs with the selfhost and runs `zig build-exe -target
# x86_64-windows-gnu -fno-emit-bin` on the output: full semantic analysis of every
# `comptime builtin.os.tag == .windows` branch in the runtime, no linking, no laptop.
# It found, on its first run, that the PeekNamedPipe path written blind on 2026-09-06
# compared a Zig-0.16 `windows.BOOL` enum with `0` and did not compile at all.
# Blind to: runtime behaviour (a wrong Win32 call that compiles).
#
# Usage: tools/win_sema_check.sh [file.zbr ...]   (default: a runtime-covering set)
set -u
cd "$(dirname "$0")/.."
ZEBRA=${ZEBRA:-./zig-out/bin/zebra}; [ -x "$ZEBRA" ] || ZEBRA=./zig-out/bin/zebra.exe
files=("$@")
[ ${#files[@]} -eq 0 ] && files=(test/sys_spawn_piped_test.zbr test/sys_process_exit_code_test.zbr test/bug335_json_query_in_method_test.zbr examples/showcase.zbr)
fail=0
tmp=$(mktemp -d)
for f in "${files[@]}"; do
  name=$(basename "$f" .zbr)
  # --output-dir explicitly: --emit-zig alone writes to the TEMP dir (on Linux that was
  # cwd only while TMPDIR was unset — a harness accident, gone since the /tmp fallback).
  "$ZEBRA" --emit-zig --output-dir "$tmp" "$f" >/dev/null 2>&1
  z="$tmp/$name.zig"
  if [ ! -f "$z" ]; then echo "FAIL (emit): $f"; fail=1; continue; fi
  if out=$(cd "$(dirname "$z")" && zig build-exe -target x86_64-windows-gnu -fno-emit-bin "$(basename "$z")" 2>&1); then
    echo "PASS: $f (x86_64-windows-gnu sema)"
  else
    echo "FAIL (win sema): $f"; echo "$out" | head -12; fail=1
  fi
  rm -f "$(dirname "$z")/$name.zig"
done
rm -rf "$tmp"
exit $fail
