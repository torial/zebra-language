<!-- doc-status: design -->
# The Zebra memory model — what a concurrent program may rely on

**Status:** ADOPTED 2026-10-06 (Sean: "I approve the memory_model.md"). Every **G** row
below binds from 1.0 as part of the stability promise (`docs/design/stability_policy.md`
§2); **C** rows stay free to change. Drafted the same day. Written because NEXT_STEPS_to_1.0 ("THE
WRITTEN MEMORY MODEL") lists five questions whose answers existed only as folklore plus one
hazard test, and because the switch to reference containers (BUG-501 1d, `cfd2bc8`) changed
the answer to one of them. Every row below names the MECHANISM in the runtime
(`selfhost/stdlib_preamble.zig`) that makes it true, and its WITNESS: a fixture that would
go red if it stopped being true, or "none" said out loud.

Each row is tagged:

- **G** — part of the 1.0 promise (`docs/design/stability_policy.md` §2); all of them,
  as adopted 2026-10-06.
- **C** — current behaviour, stated so nobody has to read the runtime, and free to change.

## 1. Where threads come from

A Zebra program has one thread unless it starts more. Five things start them:

| source | threads | joined? |
|---|---|---|
| `sys.go(def() ...)` | one per call, detached | no — signal completion through a `Chan` or `Atomic` |
| `ThreadPool(n)` | `n` workers, started at construction, detached | `pool.wait()` waits for the submitted tasks, not the workers |
| `Http.serve`, `Ws.serve`, `Tcp.serve` | one per accepted connection | no |

The serve functions are the easy ones to miss: a handler runs on many threads at once, so
anything it shares with other connections is shared state in the sense of §3 (BUG-154).

`--single-threaded` commits a program to no threads: the allocator's lock compiles out,
and every one of the five sources above is refused at compile time, naming the file and
line (`recordThreadSpawn` in CodeGen). **G**

## 2. What orders a write before a read (happens-before)

A write made on one thread is guaranteed visible to a read on another only when one of
these edges lies between them. Nothing else orders anything.

| edge | guarantee | mechanism | tag | witness |
|---|---|---|---|---|
| spawn | everything the spawner did before `sys.go(...)` / `pool.submit(...)` is visible to the new task when it starts | OS thread creation; the pool's queue mutex | **G** | `test/boundary/memory_model_probe.zbr` (R1, R3) |
| `Chan` | everything the sender did before `send(v)` is visible to the receiver once the matching `recv()` returns `v` | one mutex + two condition variables per channel | **G** | `memory_model_probe` (R1, R2), `test/chan_thread_test.zbr` |
| `Chan.close()` | everything before `close()` is visible to a receiver whose `recv()` returns `nil` because of it | same mutex | **G** | none (from the code) |
| `ThreadPool.wait()` | everything every submitted task did is visible after `wait()` returns | `in_flight` decremented under the pool mutex; `wait` reads it under the same mutex | **G** | `memory_model_probe` (R3, R4) |
| `Atomic(T)` | every operation is sequentially consistent: one total order all threads agree on | Zig `.seq_cst` on every load, store, add, sub, swap, compare-and-swap | **G** | `memory_model_probe` (R5, counts only — ordering itself is not observable deterministically) |
| `sys.go` finishing | **nothing.** A detached thread's writes are visible only through one of the edges above | — | **G** | — |

## 3. What is shared

A `capture` copies the **variable** into the task at spawn time, and `Chan.send` hands
over the **value**. Whether the other side then has its own data depends on the type:

| type | after capture / send | tag | witness |
|---|---|---|---|
| `int`, `float`, `bool`, `byte`, enums | independent copy | **G** | `memory_model_probe` R1 |
| `str` | the same bytes, and that is safe: `str` is immutable (`[]const u8`) | **G** | none needed — no operation writes into a `str` |
| struct, tuple, union | independent copy of the fields; any class instance or container INSIDE it is shared | **G** | `memory_model_probe` R1: a struct of an `int`, and a struct holding a `List` captured into a thread (copy / shared; the pre-switch compiler prints 1 / 0) |
| class instance | **shared** — the same object | **G** | `memory_model_probe` R1 (`Box`) |
| `List`, `HashMap`, `Set` | **shared** — the same container (since 2026-10-06; before that, a half-copy that shared the buffer and not the length) | **G** | `memory_model_probe` R1, R2; red against the pre-switch anchor |
| `StringBuilder` | **shared** -- it became a reference in the same switch, being spelled `_ZbrList(u8)` (found 2026-10-06 after this note was adopted, which first said "still a half-copy"; the pre-switch compiler prints a lost write where this one shares) | **G** | `memory_model_probe` R1: an alias sees the append, and so does a thread that captured it |
| `CsvWriter` | **shared** -- a reference like StringBuilder since 2026-10-09 (BUG-541; before that an independent copy: writes through a copy were lost, and a function could not write to one it was given) | **G** | `bug541_csvwriter_reference_test`: an alias and a parameter both write the one writer |
| `Chan`, `Atomic`, `ThreadPool` | shared — that is what they are for, and they synchronise themselves | **G** | `chan_thread_test`, `memory_model_probe` |

To give another thread its own container, send or capture `xs.copy()` (shallow) or a `<<-`
deep copy.

**No container, class instance or module-level variable synchronises itself.** Two threads
touching the same one, at least one of them writing, with no edge from §2 between the
accesses, is a **data race**, and a data race is undefined behaviour: the program may crash,
lose writes or read torn values, and Zebra checks none of it. **G** (the rule); there is no
witness, because a race cannot be demonstrated deterministically —
`test/arena_concurrency_hazard_test.zbr` shows what one looks like.

Two pieces of runtime state are per-thread and need no care: the error context (what
`catch` reads) and the random generator behind `Random.*`. **C**

## 4. Memory and allocators

| rule | mechanism | tag | witness |
|---|---|---|---|
| Any thread may allocate from the program allocator at any time | one arena behind a mutex (`_TsAlloc`); the lock compiles out under `--single-threaded` | **G** | `test/thread_alloc_stress_test.zbr` |
| Memory from the program allocator lives until the program exits, whichever thread allocated it, so a reference handed to another thread never dangles | the arena is freed once, at exit | **G** | none (from the code) |
| Interning a `str` (storing it into a class field) is thread-safe | the intern pool is locked (BUG-440) | **C** | `test/bug440_intern_thread_race_test.zbr` |
| **An `allocate` block is single-threaded only.** While one is open, no other thread may run Zebra code | the block swaps the GLOBAL `_allocator`, so every thread allocates from the scoped allocator, which is not thread-safe and is freed when the block ends | **G** (the rule) | `test/arena_concurrency_hazard_test.zbr` crashes ~77% of runs |
| A reference received from another thread points into the SENDER's allocator. If the sender allocated it inside an `allocate` block that has ended, it dangles | — | **G** | none |
| `Chan`, `ThreadPool` and their queues use the page allocator, not the program allocator | — | **C** | — |

## 5. Failure

| rule | tag | witness |
|---|---|---|
| A panic on any thread (an assert, an index past the end, an unhandled error) ends the whole program with a non-zero exit. A `ThreadPool.wait()` waiting on the panicking task never returns | **G** | `test/pool_task_panic_test.zbr` (smoke_run_fail: a task indexing an empty list; a `wait()` that returned would print and exit 0) |
| An error raised in a task and not caught there ends the program the same way; errors do not cross threads | **C** | none |

## 6. What this note deliberately does not decide

- **§28j step b** (per-thread arenas, a shared `Smp()` handle) — a design question with its
  own note, `docs/design/concurrency_allocation_design.md`. If it lands, §4 changes and
  this note follows it.
- **An evented runtime** (green threads, `std.Io` async). Out of scope for 1.0.
- **Relaxed atomics.** `Atomic` is seq-cst only; `zig"..."` reaches Zig's own builtins.

## 7. Settled on adoption, and what is still owed

1. **Settled:** the §2 spawn edge is promised for `pool.submit` as well as `sys.go`, as
   written. A future lock-free queue has to keep it.
2. **Paid 2026-10-07:** the fixtures this list owed -- §5's panic row (`test/pool_task_panic_test.zbr`), §3's StringBuilder and struct-holding-a-reference rows (`memory_model_probe` R1, red against the pre-switch compiler where it compiles). Every G row now names a witness except the ones marked "none" by nature (`str` immutability, the data-race rule, and the edges read from the code: `close()`, exit-time freeing).
