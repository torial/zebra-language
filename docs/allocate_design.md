# `allocate` block — design document

**Status:** All slices complete (Slices 1–4: 2026-05-12; Slice 5: 2026-05-17; Slice 6: 2026-05-17)  
**Milestone:** 0.14

---

## Goal

Replace the current single-purpose `arena` block with a general-purpose
`allocate <expr>` block that can redirect the implicit `_allocator` to any
`AllocatorSource`-compatible value for the duration of a lexical scope.

---

## Syntax

```zebra
allocate <expr>
    <body>
```

`<expr>` must be a value that implements `AllocatorSource` (see below).
The compiler saves `_allocator`, sets it to `expr.allocator()`, runs `<body>`,
then restores `_allocator` and calls `expr.deinit()`.

The old `arena` keyword has been removed (Slice 6).  Use `allocate Arena()`
instead.  The lexer still recognises `arena` so the parser can emit a helpful
error message rather than a cryptic `UnexpectedCharacter` crash.

---

## `AllocatorSource` interface

```zebra
interface AllocatorSource
    def allocator(): Allocator
    def deinit()          # default no-op — singletons don't need cleanup
```

The compiler calls `.allocator()` at block entry and `.deinit()` at block
exit (via `defer`).  Any user-defined class implementing these two methods
can be used as an allocator context.

---

## `Allocator` as a Zebra type

`Allocator` is a new primitive Zebra type mapping to `std.mem.Allocator`.
It is opaque — you cannot construct one directly, only receive one from
`.allocator()` on an `AllocatorSource`.  It can be stored in variables and
passed to functions.

TypeChecker: new `Type.allocator` variant, analogous to `Type.string`.  
Codegen: emits `std.mem.Allocator` in Zig.

---

## Stdlib named wrappers

All wrappers implement `AllocatorSource`.

| Zebra name | Zig backing | Scoped? | Notes |
|------------|-------------|---------|-------|
| `Arena()` | `std.heap.ArenaAllocator.init(_allocator)` | ✓ | replacement for the removed `arena` keyword |
| `Debug()` | `std.heap.DebugAllocator(.{}){}` | ✓ | leak detection; `GeneralPurposeAllocator` alias |
| `Page()` | `std.heap.page_allocator` (singleton) | ✗ | no-op `deinit` |
| `Smp()` | `std.heap.smp_allocator` (singleton) | ✗ | no-op `deinit` |
| `C()` | `std.heap.c_allocator` (singleton) | ✗ | no-op `deinit` |
| `FixedBuffer(buf)` | `std.heap.FixedBufferAllocator.init(buf)` | ✓ | `buf` is a `[]byte` |
| `ThreadSafe(inner)` | `std.heap.ThreadSafeAllocator{ .child_allocator = inner.allocator() }` | ✓ | wraps another `AllocatorSource` |
| `Pool(T)()` | `std.heap.MemoryPool(T).init(_allocator)` | ✓ | single-type pool |
| `StackFallback(N)()` | `std.heap.stackFallback(N, _allocator)` | ✓ | comptime N; spills to current `_allocator` |

`Wasm` and `Sbrk` are intentionally omitted — platform-specific and niche.

---

## Copy-out (`<-`) interaction

`<-` semantics are conditional on **scope-boundedness** of the current allocator:

- Inside a **scoped** `allocate` block (Arena, Debug, FixedBuffer, Pool,
  StackFallback, StackFallback): `<-` deep-copies the value into the *parent*
  allocator so it survives `deinit`.  Same behavior as the old `arena` block.
- Inside a **non-scoped** block (Page, Smp, C) or a **borrowed** expression:
  `<-` degenerates to a plain assignment.  No deep-copy needed — the allocator
  outlives the scope anyway.

**Implementation:** `StmtAllocate` carries an `is_scoped: bool` field.  The
codegen for `<-` checks `allocate_depth > 0 and current_allocate_is_scoped`
instead of the current `arena_depth > 0`.

Named wrappers declare their scoped status to the compiler via the type name.
User-defined `AllocatorSource` values are **always treated as non-scoped** (safe
conservative default — the user manages lifetime).

---

## Open questions

- [ ] `FixedBuffer(buf)` — should `buf` be `[]byte` or `zig"[N]u8"`?  A
  fixed-size stack buffer is most useful, but comptime size means `zig"..."` 
  escapes.  Initial implementation uses a runtime `[]byte` slice.
- [ ] `ThreadSafe(inner)` argument type — `AllocatorSource` or raw `Allocator`?
  Likely `AllocatorSource` so the inner wrapper's lifetime is also managed.
- [ ] `Pool(T)` — does `T` need to be a concrete Zebra type, or can it be a
  type parameter?  Deferring generic pools until generic allocators are clearer.
- [x] Migration path for existing `arena` sites — all user-facing `.zbr` files
  already use `allocate Arena()`; `arena` keyword removed in Slice 6 (2026-05-17).

---

## Implementation slices

1. ~~**Slice 1** — `Allocator` as a primitive Zebra type (TC + codegen, both backends)~~ **DONE** (commit c90040c)
2. ~~**Slice 2** — `allocate <expr>` borrow mode (no named types, no scoped deinit)~~ **DONE** (commit c90040c)
3. ~~**Slice 3** — `Arena` stdlib wrapper; confirm `AllocatorSource` interface path~~ **DONE** (commit 18bccac)
4. ~~**Slice 4** — remaining named wrappers (Page, Smp, Debug, FixedBuffer, ThreadSafe, Pool, StackFallback)~~ **DONE** (commit 18bccac)
5. ~~**Slice 5** — copy-out reconciliation (`is_scoped` flag, `allocate_depth` replaces `arena_depth`)~~ **DONE** (commit 18c58ac)
6. ~~**Slice 6** — `arena` → `allocate Arena()` unification + deprecation sweep~~ **DONE** (commit 4477d73, 2026-05-17)

All slices complete.  The remaining open work is the full `<-` deep-copy for `List`/classes
(tracked in NEXT_STEPS.md §14b) and `Chan(T)` channels (§14c).
