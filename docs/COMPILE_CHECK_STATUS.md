# Compile-check status (emitted-Zig type-checking)

*Started 2026-06-25. `tools/compile_check.sh` emits every positive-smoke test and
runs `zig build-exe -fno-emit-bin -lc` on the result — i.e. it type-checks the Zig
that user programs actually emit, which the emit-only smoke suite never did. See
[[project_smoke_no_compile_check]].*

## Current: 135 passed, **6 FAILED**, 1 skipped (down from 16 at discovery)

*Update 2026-06-25: cleared 10 of the 16. Also fixed since the table below: ws_smoke's
sibling layers, stdlib_misc (Windows setenv extern + DateTime.timestamp),
stdlib_str/stdlib_additions (tokenize→List(str), timestamp/weekday read-only),
tc_iface_transitive (concreteClassOf + transitive vtable closure).*

### Remaining 6
- **tc_iface_i2i**, **tc_iface_generic** — deeper language-feature gaps (see table).
- **ws_smoke** — 0.16 TLS `Client.Options.ca` union shape.
- **allocate_slice5** — allocate/copy-out `_saved_alloc_N` uid mismatch. **Root cause
  confirmed:** a copy-out (`<-`) *after* a nested allocate block dupes to the inner
  block's (out-of-scope) `_saved_alloc_N` because `genCopyOut` reads the most-recent
  uid (`arena_counter - 1`), not the lexically-enclosing block's. The right fix is a
  save/restore of an enclosing-block uid around `genAllocate`'s `ig.genStmts`.
  **Blocked (2026-06-26):** the save/restore was written in CodeGen.zbr but the
  bootstrap **did not regenerate** the bare field-writes (`cur_alloc_uid = n` /
  `= _saved_cur_alloc`) into CodeGen.zig — only the member-access write
  (`ig.cur_alloc_uid = n`) survived. That's a *separate* codegen quirk (bare
  field-assignment after a local `var` decl appears to be dropped/shadowed) and must
  be understood before the allocate fix can land. Reverted to keep the tree clean.
- **bug091_dispatch** — List passed to a method that fills it via pointer; mutation-
  via-arg not detected (var emitted but never directly mutated).
- **method_chain** — chained temp is `*const T` where callee wants `*T`.

Run: `bash tools/compile_check.sh` (selfhost) — not yet wired into `zig build`
(would block) until the 9 are green.

### Fixed this session (16 → 9), all gated (round-trip byte-identical + smoke 174/174)
- Zig 0.16 API: `Io.Clock.monotonic`→`.awake`; `Certificate.Bundle{}`→`.empty`;
  `statFile(io,p)`→`statFile(io,p,.{})` + `Stat.mtime`→`.toMilliseconds()`
  (File.size/isFile/modtime); `Dir.Walker.next(io)`; `Bundle.rescan(gpa,io,now)`;
  `realpathAlloc`→`process.currentPathAlloc` (sys.cwd) / `fs.path.resolve` (Path.absolute).
- Codegen: `Random.weighted` was unmapped (emitted @compileError) → maps to
  `_random_weighted`.
- selfhost mutation analysis (`CgHelpers.isReadOnlyMethod` deny-list) missing
  any/all/lastIndexOf/indexOfFrom/encodeBase64/decodeBase64/*IgnoreCase/tokenize →
  spurious `var` → Zig "never mutated".
- selfhost TC: `str.tokenize()` was typed `string_` but returns `List(str)` →
  `.count()` mis-dispatched to str-count.
- `ArrayListUnmanaged = .{}` → `.empty` (2 regex sites).

### Remaining 9 (diagnosed — for a supervised session)

| Test | Root cause | Depth |
|---|---|---|
| **stdlib_misc** | `std.os.windows.kernel32.SetEnvironmentVariableW` removed from 0.16 bindings; `_sys_setenv` Windows path needs a local `extern "kernel32"` decl with 0.16 `callconv`. | low (Windows-specific) |
| **ws_smoke** | 0.16 TLS `Client.Options.ca` became a union; `.ca = .{ .bundle = ca }` no longer matches. Needs the new Options.ca shape. | medium (TLS API churn) |
| **stdlib_additions** | `DateTime.timestamp()` unmapped on emitted `_DateTime` (method missing or renamed). | low |
| **allocate_slice5** | `allocate{}` copy-out (`<-`) emits `_saved_alloc_5` but the allocator was saved under a different uid → undeclared identifier. uid-threading bug in the allocate/copyout codegen. | medium |
| **bug091_dispatch** | `var items = List()` filled only by passing to a method that mutates it via pointer (`this.helperList(items)`); mutation-via-arg isn't detected, so Zig sees `var items` never directly mutated. Needs arg-passed-to-mutating-param detection (or List-param-by-ref var promotion). | medium |
| **method_chain** | `acceptBuilder(makeBuilder(5).withVal(30))` — the chained temp is `*const T` but the callee wants `*T`. Method-chain-temp mutability (relates to the `methodMutatesSelf` / `*const Owner` work). | medium |
| **tc_iface_i2i** | `var b: IBase = f` where `f: IFoo` (IFoo implements IBase) — interface→interface upcast not emitted (different fat-pointer struct types). | high (interface coercion) |
| **tc_iface_transitive** | `var b: IBase = d` where `d: *Dog` — concrete→interface coercion not emitted in var-init. | high (interface coercion) |
| **tc_iface_generic** | `var b: Printable = Box(i64).init(42)` — concrete (generic)→interface coercion not emitted in var-init. | high (interface coercion) |

The 3 `tc_iface_*` share one root cause (interface upcast/coercion in assignment/
var-init must construct the target fat-pointer) — one fix likely clears all three.

## Architectural note
The bootstrap (`src/CodeGen.zig`) uses an **allow-list of mutating methods** (default
non-mutating); the selfhost (`CgHelpers.isReadOnlyMethod`) still uses a **deny-list**.
The deny-list is the recurring source of "never mutated" gaps. Unifying selfhost onto
the allow-list would prevent future recurrences — but watch the `sort`/`reverse`
divergence (selfhost treats them read-only to avoid never-mutated on sort-only lists).

## Next steps
1. Clear the remaining 9 (start with the 3 iface — one fix), each gated by
   compile-check + bootstrap gate + smoke.
2. Wire `compile-check` into `zig build` (blocking) once green.
3. Consider extending it to the bootstrap emit (`--bootstrap`) for full parity,
   and to the broader `test/*.zbr` set beyond positive-smoke.
