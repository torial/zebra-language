# Runtime module emission — design note (#1)

**Status:** designed and **spiked end-to-end**; implementation not started.
**Date:** 2026-07-28
**Supersedes nothing.** Adjacent to `single_file_emit_design.md` but a *different*
change: that one combines **modules**; this one stops copy-pasting the **runtime**.

---

## 1. What it is

Today the compiler splices `selfhost/stdlib_preamble.zig` — 3,767 lines, 186 KB —
**verbatim into every emitted program**. A two-line Zebra hello-world emits 3,791
lines of Zig, of which 3,767 are preamble.

The change: ship the preamble as a **runtime module** that emitted programs
`@import`, instead of inlining it.

## 2. Why — and explicitly NOT for speed

Measured 2026-07-28, so nobody re-derives it:

| | |
|---|---|
| Zebra front end, hello-world | 0.057 s |
| `zig build-exe`, **trivial 5-line Zig**, LLVM | 5.2 s |
| `zig build-exe`, Zebra's 3,790-line emit, LLVM | 6.2 s |
| `zig build-exe`, trivial Zig, `-fno-llvm -fno-lld` | 0.94 s |
| `zig build-exe`, Zebra's emit, `-fno-llvm -fno-lld` | 1.15 s |

**Zig's own floor dominates.** The whole preamble costs ~1 s on LLVM and ~0.2 s on
the fast backend. An earlier version of this note claimed the preamble drove compile
latency; measuring the floor refuted it. **This change is not a performance change.**

It is worth doing for three things, each of which arrived independently from a
different bug:

1. **Error locations.** Errors land in generated code — `_str_concat` at line 3779 of
   a file the user never wrote (BUG-215, BUG-218). With a ~30-line emitted file there
   is almost nowhere for an error to land except user code.
2. **Namespace isolation.** Closes **BUG-220 completely**, including the
   `@export`/`@node_export` residual that the `_zbr_fn_` prefix cannot reach — because
   preamble parameters leave the user's file scope entirely and can no longer shadow
   anything.
3. **BUG-221 — module init is not transitive.** See §4; this change *dissolves* it.

## 3. Spike results (2026-07-28) — what is proven

A real emitted hello-world was split by script into `zebra_rt.zig` + `prog.zig` and
compiled. Findings, in order of how much they shape the design:

### ✅ PROVEN — `@import` shares file-scope state across modules, at any depth

Three modules (`top` → `mid` → `leaf`) all `@import("rt.zig")`; `top` sets
`rt.shared_value = 41`, `leaf` bumps it, `top` reads **42**. One instance, shared.

**This is the whole reason BUG-221 dissolves.** Put `_allocator`/`_io` in the runtime
module and every user module at every depth sees the same ones — no
`_initAllocator`/`_initIo` fan-out to propagate, and nothing to get wrong.

### ✅ PROVEN — the split itself works and is dramatic

```
before:  hw.zig        3,791 lines
after:   zebra_rt.zig  3,770 lines   (compiled once, shared)
         prog.zig         30 lines   ← the user's program
```

**126× smaller** user file. 395 preamble decls needed `pub`; 398 symbols exported; the
hello-world referenced **6** of them.

### ❌ CONSTRAINT — `usingnamespace` is gone in Zig 0.16

`pub usingnamespace @import("zebra_rt.zig");` → *"expected function or variable
declaration after pub"*. So symbols must be brought in **explicitly**.

### ❌ CONSTRAINT — a mutable `var` CANNOT be aliased across modules

```zig
const aliased = rt.shared_value;   // error: unable to resolve comptime value
rt.shared_value = 7;               // fine
```

Aliasing (`const X = _rt.X;`) works for `fn` and `const` but **not** for `var` — the
initializer of a container-level constant must be comptime-known.

**Consequence, and it is the main implementation cost:** the **19 mutable preamble
vars** (`_allocator`, `_io`, `_args`, `_error_ctx`, `_arena`, …) must be **qualified**
at every use site in emitted code — `_rt._allocator`, not `_allocator`. Functions and
consts can still be aliased cheaply.

This cuts *toward* correctness rather than against it: qualifying is precisely what
makes them shared, which is what fixes BUG-221. But it is a real codegen change
touching every site that emits one of those names.

### ❌ CONSTRAINT — there is a backward dependency to break

The preamble's `_initIo` calls `_initModuleVars()`, which **codegen emits into the
user file**. So the runtime module calls into generated code:

```
zebra_rt.zig:81: error: use of undeclared identifier '_initModuleVars'
```

Options: pass it as a function pointer set at startup; have the user's `main` call it
directly (it already does) and drop the call from `_initIo`; or keep a
settable `?*const fn () void` hook in the runtime module. **The second is simplest**
and should be checked first — `main` already emits `_initModuleVars();`.

## 4. What this dissolves

| Bug | How |
|---|---|
| **BUG-220** residual (`@export`/`@node_export` keep source names, so still collidable) | preamble params leave user file scope — nothing to shadow |
| **BUG-221** (module init not transitive; 3-module program with I/O segfaults) | one shared `_allocator`/`_io` — no fan-out at all |
| BUG-215/218-class error locations | errors land in a 30-line file, not a 3,790-line one |

Three bugs, one change, each discovered independently. That convergence is the
strongest argument for doing it.

## 5. Implementation sketch

1. **`stdlib_preamble.zig` → `zebra_rt.zig`**: mark the 395 top-level decls `pub`
   (mechanical). Keep the GUI-backend section selection (`guiSelectPreamble`) — it now
   selects into the runtime module rather than the emitted program.
2. **Codegen — qualify the 19 vars.** The real work. Every emit site writing
   `_allocator`/`_io`/`_error_ctx`/… writes `_rt.` + name instead.
3. **Codegen — emit the header** instead of the preamble: `const _rt =
   @import("zebra_rt.zig");` plus one `const X = _rt.X;` per referenced fn/const.
   Referenced-set can be computed by scanning the emitted user text (a post-pass), so
   no new tracking is needed in codegen.
4. **Write `zebra_rt.zig`** next to the emitted `.zig` so the relative `@import`
   resolves; the GUI scaffold paths need the same.
5. **Break the `_initModuleVars` backward dependency** (§3).
6. Delete the `_initAllocator`/`_initIo` fan-out — BUG-221 goes with it.

## 6. Risks and gates

- **Blast radius is every emitted program.** `compile_check` (independent witness) and
  `full_sweep` are the load-bearing gates; `divergence` will show large bootstrap gaps
  (expected — the bootstrap keeps inlining) which are informational, not regressions.
- **Round-trip** should hold: selfhost-A and selfhost-B both emit the new shape.
  Verify early — it is the cheapest signal that the change is self-consistent.
- **GameEngine** compiles 28/29 today (2026-07-28 baseline, the 29th non-compiling by
  design); re-run after, since it is the largest external corpus.
- Sequencing suggestion: do step 1 + step 3 with vars still inlined (proves the
  import/alias machinery), then step 2, then step 6.
