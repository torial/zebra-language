# Concurrency & allocation strategies — design research for §28j

**Status:** research / direction-finding (2026-07-23). Not a commitment. Written to
inform the eventual §28j supervised session, per Sean's "step back and see what Zig/Go
do first."

## The problem (recap)

Zebra allocates from **one global arena** (`_allocator`). Arenas bump-allocate and
free all at once — fast, no per-object bookkeeping — but are **not thread-safe**. When
`ThreadPool`/`sys.go` workers allocate concurrently they race on that one arena
(confirmed in code; latent UB, narrow window). The naive fix — make `_allocator`
`threadlocal` (per-thread arena) — stops the *alloc* race but creates a *lifetime* bug:
a worker allocates data, its arena is freed when the worker ends, another thread still
holds the pointer → use-after-free, invisible to every single-threaded gate.

## Where Zebra sits

|                | lifetime model | allocator ergonomics |
|----------------|----------------|----------------------|
| **Go**         | GC (automatic) | implicit (per-P caches, hidden) |
| **Zig**        | manual/scope   | explicit (allocator is a parameter) |
| **Zebra**      | manual/scope (arenas, no GC) | **implicit** (`_allocator` hidden) |

Zebra took Go's *ergonomics* and Zig's *lifetime model*. That combination is the whole
of §28j: Go makes cross-thread sharing safe by construction (the GC tracks
reachability); Zig makes it the caller's explicit problem. Zebra has hidden the
allocator like Go but must manage lifetime like Zig — so it must solve, by hand, the
thing Go's GC solves for free.

## What Zig actually provides (grounded — read from std 0.15.2)

- **`std.heap.ThreadSafeAllocator`** — wraps *any* allocator; a `std.Thread.Mutex`
  around `alloc/resize/remap/free`. ~40 lines. Trivially correct; contention scales
  with alloc frequency. The **cheapest correct floor**.
- **`std.heap.SmpAllocator`** — the production concurrent allocator. Per-thread
  freelists indexed by a `threadlocal thread_index`; metadata array sized to CPU count;
  a lock per slot, grabbed usually-uncontended (rotates to the next slot on collision);
  large allocations mapped directly (no metadata). Crucially, it **handles thread
  exit**: "the data must be recoverable when the thread exits … occasionally one thread
  reclaims another thread's resources." This is Go's per-P `mcache` design rebuilt
  without a GC — and it dissolves the tier-2 lifetime problem that made §28j hard. It's
  a singleton with global state, designed for ReleaseFast + threads.
- **`std.heap.ArenaAllocator`** — what Zebra uses today (bump + bulk-free).
- **`std.heap.memory_pool`** — fixed-size object pool (≈ Zebra's `ObjectPool(T)`).

## What Go does

Tiered, tcmalloc-derived: per-P **`mcache`** (thread-local, lock-free fast path) →
per-size-class **`mcentral`** (locked) → global **`mheap`** (locked). Goroutines are
M:N green threads; escape analysis picks stack vs heap. The load-bearing difference:
**the GC owns lifetime**, so data allocated on one goroutine and read on another is
safe with zero programmer effort. Zebra cannot copy this half without a GC.

## Two other grains worth stealing from

- **Erlang/BEAM — share-nothing.** Per-process heaps; messages between processes are
  **copied**, never shared by reference. No cross-process lifetime problem *because
  there is no cross-process sharing.* **Zebra already leans this way**: `Chan(T)` with
  `<-` deep-copy and `<<-` copy-out are share-nothing primitives.
- **Rust — type-tracked sharing.** `Send`/`Sync` mark what may cross threads; `Arc<T>`
  for shared ownership. Zebra has no borrow checker, but the *concept* — an explicit
  marker for "this data crosses threads" — is the shape a `shared`/`Smp()` annotation
  would take if Zebra goes the shared-state route.

## The fork this clarifies

§28j is not one design; it's a **choice of concurrency grain**, and the allocator falls
out of it:

1. **Share-nothing (primary, fits Zebra's existing grain).** Per-thread arenas (tier 1,
   small change). Cross-thread data is **copied** — which `Chan(T)`/`<<-` already do.
   No shared tier, no cross-thread lifetime problem. Cost: copying (fine for
   message-sized data; poor for large shared structures). **This sidesteps the hardest
   part of §28j entirely** and matches the language Zebra already is.
2. **Shared-state (when genuinely needed).** For the cases share-nothing can't serve
   (a big read-mostly table many workers touch), route those allocations to a
   thread-safe tier. Zebra does **not** need to invent it: `ThreadSafeAllocator`
   (mutex, ship-now) or `SmpAllocator` (production, per-thread-cache, handles
   thread-exit) are both in std. The "new shared-handle API" (`Smp()` / a `shared`
   block) becomes a thin routing annotation over an existing allocator, not a new
   allocator.
3. **Task/request-scoped arenas.** Orthogonal and cheap: give each connection/task its
   own arena, freed at task end (common in Go/Rust servers). Composes with (1).

## Audit result (2026-07-23): share-nothing is NOT already free for reference types

The share-nothing recommendation below rests on "cross-thread data is copied." I audited
the actual channel path (`_Chan(T).send`, in the emitted preamble):

```zig
pub fn send(self: *Self, val: T) void {
    ...
    self.buf.append(_alloc, val) catch @panic("OOM");   // <- SHALLOW bit-copy of val
    ...
}
```

`val` is bit-copied into the channel buffer (buffer itself on `page_allocator`, so it
survives — good). But for a reference type — `Chan(str)` (`str` = `[]const u8`, a slice)
or `Chan(SomeStruct)` with `str`/`^T` fields — the **bit-copy duplicates the
slice/pointer, not the pointed-to bytes**, which still live in the *sender's* arena.
Worker sends a `str`, worker's arena is freed on thread exit, receiver reads dangling
memory. So **share-nothing holds today only for primitive `T`; reference types leak the
sender's arena across the channel.** (`<<-` copy-out is the one path that *does* deep-copy,
via `_zbr_deep_copy` — the machinery exists, it's just not wired into `_Chan.send`.)

**Consequence for the estimate:** the share-nothing path is not "already done, just
audit it" — it needs `_Chan.send` (and `recv`, for the receive-into-my-arena direction)
to **deep-copy reference payloads** using the existing `_zbr_deep_copy`. That's bounded
*wiring* (the deep-copy is written, tested by `<<-`), not invention — but it is real work
that the earlier "scope dropped, mostly an audit" read under-counted. Net: the risky
*allocator invention* still drops (adopt Zig's std); the share-nothing correctness work
is a specific, bounded channel-deep-copy task rather than free.

## Recommendation (for the §28j session, not yet committed)

Lead with **share-nothing (1) + task-scoped arenas (3)** as the default model — it fits
`Chan(T)`/`<<-`, needs only per-thread arenas, and avoids the use-after-free class by
construction. Provide a **thread-safe fallback tier (2)** for real shared state by
adopting a std allocator (`ThreadSafeAllocator` first for correctness; `SmpAllocator`
if/when contention matters), exposed as a small opt-in annotation rather than a new
allocator implementation.

**This meaningfully shrinks §28j.** The earlier estimate ("design + wire a novel
two-tier allocator + shared-handle API", medium-large, high-risk) drops because: tier 1
is a small `threadlocal` change; tier 2 is a *library choice* (Zig already wrote it,
including the hard thread-exit reclamation); and much of the cross-thread path may
already be correct via `Chan(T)` copy semantics — which needs *auditing*, not building.
The residual real work is: (a) per-thread arena wiring, (b) an audit that every
cross-thread data path copies, (c) a **threaded-lifetime test** in the gate set (still
essential — it's the only thing that can see cross-thread UAF), (d) the opt-in shared
annotation. Still supervised (concurrency UB), but smaller and lower-invention.

**Strategic dependency (unchanged):** value scales with whether Zebra adds an evented
`std.Io` runtime (green threads → C10k). Threaded-only today; xsync.zig
([[project_xsync_concurrency]]) is vendorable prior art for cancellation-safe
primitives and would close BUG-154 regardless of which grain wins.

## Confidence

Zig details are grounded (read from `std` 0.15.2). Go's `mcache/mcentral/mheap` and the
GC-owns-lifetime point are from working knowledge, not re-verified against Go source
here — the architectural claim is safe, but treat specifics as ~90%. The
share-nothing-fits-Zebra claim is the load-bearing judgment and is checkable against the
existing `Chan(T)`/`<<-` semantics.
