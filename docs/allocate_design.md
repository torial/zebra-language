# `allocate` block — design document

**Status:** in-progress design (2026-05-11)  
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

`arena` is sugar for `allocate Arena()` and will be deprecated once
all existing sites are migrated.

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
| `Arena()` | `std.heap.ArenaAllocator.init(_allocator)` | ✓ | replaces `arena` keyword |
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
  allocator so it survives `deinit`.  Same behavior as today's `arena`.
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
- [ ] Migration path for existing `arena` sites — `arena` stays as an alias
  until a `--warn-deprecated` pass flags it.

---

## Implementation slices

1. **Slice 1** — `Allocator` as a primitive Zebra type (TC + codegen, both backends)
2. **Slice 2** — `allocate <expr>` borrow mode (no named types, no scoped deinit)
3. **Slice 3** — `Arena` stdlib wrapper; confirm `AllocatorSource` interface path
4. **Slice 4** — remaining named wrappers (Page, Smp, Debug, FixedBuffer, ThreadSafe, Pool, StackFallback)
5. **Slice 5** — copy-out reconciliation (`is_scoped` flag, `allocate_depth` replaces `arena_depth`)
6. **Slice 6** — `arena` → `allocate Arena()` unification + deprecation sweep

Slices 1–3 are the MVP.  Slices 4–6 complete the milestone.
