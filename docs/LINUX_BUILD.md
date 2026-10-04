<!-- doc-status: live -->
# Building Zebra on Linux (and in a container)

*Landed 2026-09-06 (branch `linux-build`, Fable 5.1). Before this, the repo built only
on Windows: two POSIX-only compile errors and three `.exe`-hardcoded gate scripts.*

## Steps

```bash
pip install ziglang==0.16.0            # ziglang.org may be unreachable from a sandbox; PyPI carries the binary
# NOTE (2026-10-03): the repo pins Zig 0.17.0 (.zig-version) and PyPI's ziglang has NO 0.17.0
# yet. Until it does, a sandbox that can only reach PyPI runs the tools on 0.16 EXPLICITLY:
#   export ZEBRA_ZIG_VERSION=0.16.0
# which works only while the tree still builds under both (docs/design/zig017_migration.md,
# until Phase C). Where ziglang.org is reachable, download 0.17.0 instead.
printf '#!/bin/sh\nexec python3 -m ziglang "$@"\n' > ~/bin/zig && chmod +x ~/bin/zig
export PATH=$HOME/bin:$PATH
zig build                              # ~10 s: zig-out/bin/zebra + zebra-bootstrap (no .exe suffix)
zig build test-zig                     # 131 unit + integration tests
bash tools/selfhost_smoke.sh           # 400 fixtures, ~5 min on 2 cores
bash tools/bootstrap_check.sh          # level-2 round trip; PASS byte-identical on Linux
```

Measured 2026-09-06 in a 2-core container: build 12 s, `test-zig` green, smoke 400/400,
round trip clean. `escape_hatches_check.sh` is red on main on every platform (BUG-279
leg 3, pre-existing) — it is the one `zig build test` step that fails.

## What had to change (why, not just what)

1. **Environment on POSIX (Zig 0.16).** `std.posix.getenv/setenv` are gone and
   `std.process.Environ{ .block = .global }` exists only on Windows. The runtime now
   owns `_environ`, filled by the emitted `main()` from `_zinit.minimal.environ`
   (codegen emits the line), and `_sys_getenv` reads it via
   `getPosix`. `_sys_setenv` on POSIX keeps an in-process override map consulted first
   by `_sys_getenv` (and also calls libc `setenv` when libc is linked), so set-then-get
   behaves the same on every platform. (The bootstrap's `Debugger.zig` got the same
   via `process_environ`; retired with `src/` 2026-09-16.)
2. **Panics leaked Zig internals on POSIX.** A runtime `assert` printed a Zig stack
   trace pointing at the emitted `.zig` and `std/start.zig`; Windows never did, and
   `test/bug259_runtime_exit_code_test.zbr` asserts it must not. Emitted programs now
   declare `pub const panic = std.debug.FullPanic(_zbr_rt._zebra_panic)`: same
   one-line `thread N panic: msg` header (output_sweep normalises it), exit 1, no
   trace. `ZEBRA_PANIC_TRACE=1` restores the full trace for compiler debugging.
3. **Gate scripts hardcoded `zebra.exe`.** `selfhost_smoke.sh`, `compile_check.sh`,
   `bootstrap_check.sh` now fall back to the suffix-less binary. On 2026-09-26 the QUICK
   tier started running on Linux in CI (`quick-linux` in gates-quick.yml), and its first run
   named the rest: every gate tool that set `ZEBRA=.../zebra.exe` (13 shell, 4 Python) now
   falls back to `zebra` when the `.exe` is absent, and zbr_vocab.py accepts a GNU/Linux
   bash when it is itself running on Linux (its WSL guard only matters on Windows).

## Not done

GUI backends (libui-ng needs GTK on Linux; not vendored); `zig build test` as a whole
(escape_hatches, see above); the remaining `.exe` scripts.
