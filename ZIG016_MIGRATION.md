# Zig 0.16 Migration Notes

> Status: **deferred** — do Phase 22 cutover first, then migrate after 0.16.1.
> Ecosystem deps (zgui, zglfw, zopengl) will also need 0.16 ports.

## Why Wait for 0.16.1

The I/O overhaul is the largest stdlib break in Zig's history. 0.16.1 will fix
edge cases before we absorb it. Starting migration mid-Phase-22 cutover is high risk.

---

## High-Impact Changes (preamble + src/main.zig)

### 1. I/O overhaul — `std.Io` parameter everywhere

`fs.Dir`, `fs.File`, `std.io.Writer`, `fmt.format` all now require an `Io`
parameter. This cascades through the preamble (file I/O helpers, `_sys_run`,
print helpers) and `src/main.zig` (child process spawning).

Check: does `std.debug.print` now require `Io`? If yes, every generated Zig
program's `print` call breaks — the preamble's `_zbr_print_*` functions need
updating.

| Old | New |
|-----|-----|
| `fs.File.read(...)` | `std.Io.File.readStreaming(io, ...)` |
| `fs.Dir.openFile(...)` | `std.Io.Dir.openFile(io, ...)` |
| `std.io.fixedBufferStream(...)` | removed — use alternatives |
| `fmt.format(writer, ...)` | `std.Io.Writer.print(...)` |
| `AnyReader` / `GenericReader` | removed |

### 2. Process spawning API — `src/main.zig` lines ~989, ~1084, ~1101

```
Old: var child = std.process.Child.init(&argv, alloc);
     child.stdout_behavior = .Inherit; ...
     const term = try child.spawnAndWait();

New: std.process.spawn(io, &argv, .{ .stdout = .inherit, ... })
     or std.process.run(io, ...)
```

The selfhost preamble's `_sys_run()` also uses `std.process.Child` — update both.

### 3. `@Type` removed

`@Type(.{ .Struct = ... })` etc. are replaced by `@Int(...)`, `@Pointer(...)`,
`@Struct(...)`, etc. Search preamble and any codegen that emits `@Type(`.

### 4. Namespace moves

| Old | New |
|-----|-----|
| `std.Thread.Mutex` | `std.Io.Mutex` |
| `std.time.Instant` | `std.Io.Timestamp` |
| `heap.ThreadSafeAllocator` | removed — use lock-free allocators |

### 5. Build dependency hashes

`zgui`, `zglfw`, `zopengl` hashes in `build.zig.zon` templates will need
updating once those projects publish 0.16-compatible releases.

---

## Lower-Impact Changes

- `@cImport` deprecated → `b.addTranslateC()`. C interop tests use
  `@cInclude` in generated code — check if this path is affected.
- Packed struct/union changes. Generated Zig doesn't use packed types.
- Vector coercion rules. Unlikely to affect generated code.
- "Juicy Main" (`main()` optionally takes `std.process.Init`). Probably
  optional — existing `pub fn main() void` should still compile.

---

## Benefits That Motivate Migrating

| Benefit | Zebra impact |
|---------|-------------|
| Lazy field analysis | Fewer unnecessary type resolutions in generated Zig; faster `zig run` per test |
| Incremental compilation | `zig build test` and `zig build selfhost` faster on repeat runs |
| Windows NtDll completion | Faster `sys.run()` (fewer DLL hops per subprocess) |
| `std.process.run()` convenience | Simpler spawn-and-capture in `src/main.zig` |
| Thread-safe `ArenaAllocator` | Preamble allocator simplification (no explicit lock needed) |
| `--multiline-errors` flag | IDE can request richer error output from `zebra -c` |
| Unit test timeouts | Can add timeout to `zig build test` step in `build.zig` |

The lazy field analysis + incremental compilation are the most directly felt:
they shorten the `zig run` overhead in the parity runner and the selfhost
bootstrap cycle.

---

## Suggested Migration Approach

1. Check 0.16.1 release + ecosystem (zgui/zglfw 0.16 ports ready?)
2. Branch `zig-0.16-port`
3. Update `build.zig.zon` dep hashes for zig-gamedev stack
4. Fix `src/main.zig` process API (`Child.init` → `spawn`)
5. Fix preamble I/O: `fs.File/Dir`, `fmt.format`, `_sys_run`
6. Search preamble + codegen for `@Type(` → split to specialized builtins
7. Run `zig build test` — fix remaining errors
8. Run `zig build bootstrap` — confirm round-trip still green
9. PR + merge

Estimated scope: 1–2 days, mostly mechanical. The `std.Io` parameter threading
is the largest surface but the pattern is uniform.
