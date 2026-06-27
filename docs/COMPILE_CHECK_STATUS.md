# Compile-check status (emitted-Zig type-checking)

*Started 2026-06-25. `tools/compile_check.sh` emits every positive-smoke test and
runs `zig build-exe -fno-emit-bin -lc` on the result — i.e. it type-checks the Zig
that user programs actually emit, which the emit-only smoke suite never did. See
[[project_smoke_no_compile_check]].*

## Current: 140 passed, **1 FAILED**, 1 skipped (down from 16 at discovery)

*Update 2026-06-26: tc_iface_i2i FIXED (interface→interface upcast in var-init).
Both compilers now give every sub-interface vtable an `__as_<Super>: *const
<Super>.VTable` pointer (wired by the transitive `implements` closure) plus
inherited base-method forwarders, so an erased `IFoo` value re-projects to any
super-interface `IBase` in O(1): `var b: IBase = f` →
`.{ .ptr = f.ptr, .vtable = f.vtable.__as_IBase }`. Bootstrap round-trip
byte-identical; gate green.*

> **Two findings from the i2i work (correcting earlier notes):**
> 1. The claim below that "the 3 `tc_iface_*` share one root cause" is **wrong**.
>    `tc_iface_i2i` (erased interface→interface upcast — needs the vtable
>    representation change above) and `tc_iface_generic` (generic classes never
>    emit interface vtables at all) are **independent** fixes. `tc_iface_transitive`
>    was a third, already fixed.
> 2. There was a **bootstrap/selfhost divergence**: the d79ab68 transitive
>    concrete→interface coercion (`var b: IBase = d` for concrete `d`) lived only
>    in selfhost/CodeGen.zbr; the bootstrap (src/) could not compile
>    `tc_iface_transitive`. The i2i work added the transitive concrete-class vtable
>    emission to src/ too, narrowing that gap (the bootstrap now emits the super
>    vtables; full concrete→interface ident coercion in src/ is still selfhost-only).
> 3. **Selfhost codegen gotcha (recorded for future ports):** values obtained from
>    `List.at()` are not tracked as `str` for `${}` string interpolation (they
>    format via Zig's `{any}` → byte-array), and `Type_.named` in the selfhost AST
>    carries the name string directly (not a Symbol). Use separate `w.emit()` calls
>    for `.at()`-derived names.

*Update 2026-06-26: ws_smoke FIXED (commit caf477c) — all three of its 0.16 layers
are now clear: TLS Client.Options (ca union + entropy/realtime_now, 339f145),
Io.net.listen→IpAddress.listen method (a379b30), and the WS handler stored as a
`*const fn(*_WsConn) void` pointer instead of a comptime-only `fn` type (caf477c,
mirrors the working _http_serve pattern). compile-check 6→5; bootstrap gate
byte-identical; pushed to origin/main.*

*Update 2026-06-25: cleared 10 of the 16. Also fixed since the table below:
stdlib_misc (Windows setenv extern + DateTime.timestamp),
stdlib_str/stdlib_additions (tokenize→List(str), timestamp/weekday read-only),
tc_iface_transitive (concreteClassOf + transitive vtable closure).*

> **ENVIRONMENT NOTE (2026-06-26, post-reboot relevant):** builds began failing with
> `lld-link: could not open '…\AppData\Local\zig\o\<hash>\compiler_rt.lib / ntdll.lib /
> kernel32.lib': No such file or directory`. This is **global-cache corruption**, not a
> code problem. Deleting only the cache's `o/` (outputs) subdir does **not** fix it —
> the `h/` **manifests** still claim those import-libs exist, so Zig skips regenerating
> them and goes straight to link. **Fix:** delete the *entire* global cache dir
> `rm -rf "C:/Users/Sean/AppData/Local/zig"` (plus local `.zig-cache`), then rebuild
> (first build is a full std recompile, a few minutes). Likely the same condition behind
> the laptop's degraded/locked-up network state that prompted the reboot. After reboot,
> the cache is already gone/fresh, so the first `zig build` will just be slow, not broken.

### Remaining 1 — method_chain (see below)

### tc_iface_generic — FIXED 2026-06-26
Generic classes emitted **no** interface vtables, so coercing a generic instance to an
interface referenced an undeclared vtable. Fix (both compilers): emit per-instantiation
shims + `_vtable_<Iface>` *inside* the generic `struct` body (`genIfaceVtableInStruct`,
shims reference `@This()` so each `Box(i64)` monomorphization gets its own), including
the transitive super-interface closure; the coercion references `&Box(i64)._vtable_<Iface>`
(reconstructing the instantiation from the ctor's type args). AST-shape divergence handled
per compiler: the bootstrap parses `Box(int)(42)` as one `.call` with `type_args`; the
selfhost as nested calls. Compiles + runs.

### bug091_dispatch — FIXED 2026-06-26
The instrumented hunt (the earlier "mc_params resolves nil" theory was wrong) showed the
call never reached the default arg path at all: `genMemberCall` has an **earlier**
user-method dispatch branch (`CodeGen.zbr` ~9444, added so a user method named
`append`/`add`/etc. isn't mis-routed to stdlib heuristics) that emitted the call with
**inline args and no addr-of**, then returned — bypassing the default path's three-case
addr-of/pass/deref convention. So `this.helperList(items)` / `f.helperList(items2)`
passed the `List` by value (compile error + a latent runtime bug — appends hit a copy).
Fix: apply the same three-case convention in that branch, resolving params/body via the
`um_cname + "." + mname` key. Now emits `&items`, compiles, runs. (The param side was
already `*std.ArrayList` via `paramNeedsAddrOf`; only the call site was wrong.) Lesson:
when only *some* call shapes are wrong, look for an early-return dispatch branch, not
just the canonical path.

- **method_chain** — THE ONLY REMAINING compile-check failure. Root cause (fully
  diagnosed 2026-06-26): non-mutating methods (`getVal`, `withVal`, `doubled` — the last
  two use the `this except` idiom, which reads self and returns a *new* value) emit a
  `self: *Builder` receiver instead of `*const Builder`. Both compilers emit a `*const`
  receiver **only** for `@pure`-marked methods (selfhost genMethod ~2976; bootstrap
  src/CodeGen.zig ~5320) — there is no automatic non-mutation analysis. **`methodMutatesSelf`
  is a dead import**: `use CgHelpers exposing … methodMutatesSelf` resolves to nothing —
  it is referenced but never defined or called. Tasks #139–141 ("add methodMutatesSelf",
  "emit *const when not mutating") did not survive.

  The failure surfaces across several patterns once any single one is patched:
  - call-arg-position chains (`acceptBuilder(makeBuilder(5).withVal(30))`) — the rvalue
    receiver is `*const`;
  - `acceptBuilder(b: Builder)` → `b.getVal()` — `b` is a by-value (const) param.

  **The correct fix is auto-`*const`:** define a conservative `methodMutatesSelf` (a
  method mutates self iff its body assigns a self-field, does `self.* = …`, takes
  `&self`, or calls a mutating method on self) and emit `*const Owner` when it returns
  false. This fixes *all* the patterns at once (a `*const` receiver is callable on
  const values, rvalues, and `var`s alike) and needs no chain materialisation. It must
  land in **both** compilers (the bootstrap fails too — not a convergence fix).

  **Why deferred to a focused session (not done autonomously 2026-06-26):** it changes
  the method receiver-mutability model and must be wired into the *self-compiling*
  compiler's own `genMethod` — a wrong "pure" verdict on any mutating compiler method
  makes the regenerated compiler fail to build. The round-trip gate + rebuild ARE a
  strong safety net (a bad verdict can't silently ship), so this is tractable and
  bounded — but it warrants deliberate work with the analysis validated against the full
  compiler, ideally in the loop. A narrow call-arg materialisation alone was tried and
  reverted: it fixed the chain patterns but not `b.getVal()` (const-param receiver), so
  it does not close the test.

### allocate_slice5 — FIXED 2026-06-26
The earlier `cur_alloc_uid` save/restore theory (and its "bare-field-write
regeneration quirk") was the wrong tree. The real story: the **bootstrap was already
correct** — it names arena temporaries by *nesting depth* (`_parent_alloc_{depth}`,
where `depth` rides the indented generator and is therefore naturally scoped), so a
copy-out in an outer block resolves to the outer allocator after an inner block closes.
The **selfhost had diverged** to a global counter (`_saved_alloc_{arena_counter}`) and
`genCopyOut` read `arena_counter - 1` (the most-recently-*opened* block), which is out
of scope by the time the outer copy-out runs. Fix: converge the selfhost onto the
bootstrap's depth-based naming (`allocate_depth` was already correctly scoped — only
the copy-out reached past it) and delete the dead `arena_counter`. No new field, no
save/restore, no bare-field-write. Selfhost emit is now byte-identical to the bootstrap
for allocate blocks; the 5-case test compiles and runs.

Run: `bash tools/compile_check.sh` (selfhost) — not yet wired into `zig build`
(would block) until the remaining 3 are green.

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
