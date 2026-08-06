<!-- doc-status: design -->
# `extern` — declaring foreign symbols (BUG-258)

**Status:** DONE for static C linking, in both compilers — a `use` of a sibling `.c`
compiles, links and calls in ONE command, gated by a fixture that checks the printed
value. **DLL symbols also work, but only on the LLVM build path (section 8) — the earlier
"unsupported" claim was wrong.** Do not read sections 1-3 as future tense; sections 7-8
are the current state.
**Decided by Sean 2026-08-05:** `extern` is meant to exist, to enable the FFI work.
**Written 2026-08-05 by Opus 5** after verifying BUG-258 in the tree.

---

## 1. What is actually true today (measured, not assumed)

| | `extern def foo(): int` |
|---|---|
| **selfhost** (`zebra.exe`) | rejects: *unexpected top-level token: 'extern'* — **correct** |
| **bootstrap** (`zebra-bootstrap.exe`) | **accepts**, drops the modifier, emits `unreachable; // abstract` |

The bootstrap's output **compiles** (verified by building it to an `.exe`). So an `extern`
declaration today becomes an abstract method that traps in Debug and is **undefined
behaviour under `zebra --release`** (ReleaseFast). That is worse than a clean rejection,
and it means **the selfhost is right and the bootstrap is wrong here** — the same inversion
as BUG-254.

**There is no other way to declare a foreign symbol.** The `zig"…"` escape hatch is
statement-level only; at top level **both** compilers reject it:

    zz_ziglit_top.zbr:1:1: error: unexpected top-level token: 'zig"extern fn strlen(…) usize;"'
    zz_ziglit_top.zbr:1:1: syntax error near 'zig"extern fn strlen(…) usize;"'   (bootstrap)

So the blockage reported against `zebra-sprocket` is real: there is no route from Zebra to
`sqlite3_proc_next_resultset()`.

**Two of the three pieces already exist**, which is what makes this tractable:

- **C-ABI-sized types.** `int8/16/32/64`, `uint8/16/32/64`, `float32/64` all exist and map
  to `i32`, `u8`, … (`src/Builtins.zig:201+`). `int32` is `c_int` on every platform Zebra
  targets, so the ABI is expressible without new syntax.
- **Linking.** `BuildTarget.linkLib` exists in the Build stdlib
  (`src/CodeGen.zig:10059` → `_build_target_link_lib`), reachable from `build.zbr`.
  *Caveat: `BuildTarget` is one of the seven names with no corpus coverage at all
  (see the 0.9-beta checklist §E), so it is declared but unexercised — confirm it works
  before depending on it.*
- **Missing: the declaration itself.** That is this document.

`@cImport(@cInclude("x.h"))` also exists for C deps that ship a header
(`src/CodeGen.zig:4908`). `extern` is for the case with no header, or where you want a
single symbol without pulling a translation unit.

---

## 2. The design decision, and the default

**Default (A): minimal and honest.** `extern def name(params): ret` with **no body** emits

    extern fn name(params) ret;

using the existing Zebra→Zig type mapping and Zig's default C calling convention for
`extern fn`. The author is responsible for two things, both already expressible:

- using ABI-correct types (`int32`, not `int` — `int` is `i64`, which is *not* C's `int`)
- linking the library from `build.zbr` via `BuildTarget.linkLib`

**Rejected (B): the fuller surface** — C-type aliases (`cint`, `csize`, `cstr`), symbol
renaming (`extern def foo(): int = "c_foo"`), calling-convention control, automatic libc
linking. Each is defensible and none is needed to unblock the sprocket work. B is a
feature programme; A is one increment that makes the programme possible. Ship A, and let
real FFI use say which part of B is actually wanted.

**The one thing A must not do is what the bootstrap does now**: accept the declaration and
emit something that compiles but is wrong.

---

## 3. Implementation plan

Ordered so that each step is independently verifiable, and so the tree is never
half-updated (`rebuild.sh --module` refuses a partial regen for exactly this reason).

### 3.1 Selfhost front end

The selfhost parses into a `PNode`/`PMethod` layer carrying explicit booleans, which
`AstBuilder` converts to `Ast.Modifiers`. `Ast.Modifiers` **already has `is_extern`**
(`selfhost/Ast.zbr:63`) — it is declared and never set. So:

1. `selfhost/Parser.zbr` — add `is_extern` to `PMethod` (near `is_export`, line ~358) and
   to its `cue init` (line ~364). Thread it through `parseMethodDecl` (line ~1898) and the
   `PNode.method_` construction (line ~1986).
2. `selfhost/Parser.zbr` — accept `kw_extern` in the top-level modifier position. Note
   `isRecoveryStarter` (line ~886) **already lists `kw_extern`**, so error recovery knows
   about it while the decl dispatcher does not; that asymmetry is the bug.
3. `selfhost/AstBuilder.zbr` — map `PMethod.is_extern` → `Modifiers.is_extern`. Watch the
   positional `Modifiers(...)` constructors (`zmods()`, `zstatic()`, line ~34) — 15
   positional booleans, so an inserted field silently shifts every later argument. **Add at
   the end or use named fields; do not insert in the middle.**

*The signature change is the risk in this step.* `parseMethodDecl` has many call sites and
the booleans are positional. A defaulted parameter (`is_extern: bool = false`) keeps every
existing call correct.

### 3.2 Selfhost codegen

4. `selfhost/CodeGen.zbr` — when `mods.is_extern`, emit `extern fn NAME(params) RET;` and
   **no body**. A body on an extern declaration is a Zig compile error, which is a useful
   property: getting this wrong fails loudly rather than silently.

### 3.3 Bootstrap

5. `src/CodeGen.zig:6141` is the `unreachable; // abstract` site. An extern method must
   take a different branch and emit the declaration. **This is not optional politeness** —
   the bootstrap is the regen authority *and* the `--gui-backend` path, and leaving it
   emitting UB for a now-supported keyword is worse than the current state, because the
   selfhost would start accepting programs the bootstrap silently miscompiles.

### 3.4 Gates

6. `test/` fixtures: a declaration-only extern that **compiles** (link not required if
   never called), and — the important one — a `smoke_run` that actually **calls** a
   foreign function and checks the printed result. Compile-only proves nothing here; the
   whole failure mode of this feature is a declaration that links to nothing or to the
   wrong ABI.
7. A `boundary_check` probe, since this is a language-reference claim.
8. `divergence_check` must stay at 0 selfhost gaps — with step 5 done, both compilers
   emit the same thing.

### 3.5 Docs

9. QUICKSTART §23 currently presents `zig"…"` as *the* escape hatch. It needs an `extern`
   section stating the ABI rule (`int32`, not `int`) and pointing at `BuildTarget.linkLib`.
10. `grammar.txt` needs no edit — it is generated, and `kw_extern` is already in the rule
    table at `src/ZebraGrammar.zig:348,351,370`. This implementation makes the document
    true rather than requiring it to change.

---

## 4. What would make this wrong

Recorded so the implementer checks these rather than rediscovering them:

- **`int` is `i64`, not C's `int`.** An `extern def f(n: int)` against a C `int` parameter
  is an ABI mismatch that links fine and corrupts the stack. This is the single most
  likely way to get a green build and a wrong program, so the doc change (step 9) is part
  of the feature, not follow-up.
- **A compile-only fixture would pass while the feature is broken.** See §3.4.
- **The 15 positional booleans in `Modifiers(...)`.** Inserting a field mid-list shifts
  every argument after it, and they are all `bool`, so nothing type-errors.
- **Symbol name = Zebra name.** With no renaming (decision A), a C symbol that is not a
  legal Zebra identifier cannot be reached. That is a known limit of A, not an oversight;
  it is the first thing to revisit if real use hits it.

---

## 5. Not in scope

Deliberately out, and each would be its own decision:

- `extern` on anything but a `def` (variables, types, classes).
- Varargs (`printf`-style).
- Struct-by-value across the boundary — Zebra structs are not `extern struct`.
- Callbacks from C into Zebra (needs `export` plus a stable calling convention; `export`
  already works, so this is closer than the rest).
- Any `zebra build` change. `BuildTarget.linkLib` is assumed sufficient and **unverified**.

---

## 6. Status 2026-08-05 — declaration DONE, linking NOT

Implemented in both compilers. The emit is correct and verified:

    extern def GetCurrentProcessId(): uint32
      ->  extern fn GetCurrentProcessId() u32;
          const pid: u32 = GetCurrentProcessId();

**Red-team: 20/23.** The 3 remaining are all bootstrap PERMISSIVENESS (it accepts a body
on an extern decl, and `extern var` / `extern class`, where the selfhost correctly
refuses). The shipping compiler rejects all three with a clear message.

### The call-site bug, which only a CALLING probe could find

The declaration emitted unmangled while every REFERENCE still emitted `_zbr_fn_abs`, so
the program failed with `use of undeclared identifier '_zbr_fn_abs'`. Fixed by registering
extern names in `toplevel_export_fns` — the set meaning *"this symbol keeps its real
name"*, which is as true of `extern` as of `export`.

This is precisely what §4 predicted: *"a compile-only fixture would pass while the feature
is broken."* It did. Every declaration-shaped probe was green while no call could compile.

### DECISION A IS INSUFFICIENT ON WINDOWS — measured, and it changes the plan

A bare `extern fn` cannot reach a DLL symbol. `GetCurrentProcessId()` links and then
**segfaults at the call**, with the emitted Zig visibly correct. Zig needs two things this
design does not emit:

    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
                ^^^^^^^^^                      ^^^^^^^^^^^^^^^^
                library name                   calling convention

Both were deferred to "decision B" as *nice-to-have*. On the primary platform they are
**required**, so B's library-name half is no longer optional. Zebra needs a way to say
which library a symbol comes from — some form of `extern("kernel32") def ...` — and Win32
needs its calling convention.

### RESOLVED 2026-08-05 by experiment: it is a DLL-IMPORT gap, not an FFI gap

The question above was run rather than reasoned about, and the answer changes the scope
substantially.

**A bare `extern def` WORKS TODAY against a statically-linked C object.**

    /* zlib_probe.c */  int zebra_probe_add3(int a,int b,int c){return a+b+c;}

    extern def zebra_probe_add3(a: int32, b: int32, c: int32): int32
    def main()
        print(zebra_probe_add3(20, 20, 2))

    $ zig build-exe p.zig zlib_probe.c -lc  &&  ./p.exe
    42

Symbol resolves, ABI is correct (`int32` -> `i32` -> C `int`), value is right. **No new
syntax is required for static C linking** — decision A is sufficient for exactly the case
the sprocket work needs, since a SQLite fork is compiled in rather than loaded as a DLL.

**What does NOT work is a DLL import.** `GetCurrentProcessId()` links and segfaults,
because Zig needs `extern "kernel32" fn ... callconv(.winapi)` and we emit neither. So the
gap is narrow and nameable: **symbols in a shared library**, not FFI generally.

Consequence for the plan: the library-name syntax is no longer needed to unblock anything.
It is a Win32/DLL feature, and can be designed when someone actually needs a DLL symbol —
with the knowledge that the static path already works, which is a much better position to
design from than "FFI is broken".

**Known remaining friction, not yet chased.** Zebra *has* automatic C-source linking —
`use foo` where `foo.c` exists routes it into `c_sources` and on to `zig build-exe`
(`src/main.zig:446-453`) — but a plain `use zlib_probe` alongside the probe resolved to
`zlib_probe.zig` and failed with `unable to load 'zlib_probe.zig': FileNotFound`. So the
manual two-step (emit, then `zig build-exe p.zig lib.c`) works while the one-command path
does not, at least from a temp emit directory. **Root cause found the same day and filed as BUG-260:** the selfhost has NO
C-dependency handling at all — `c_no_header` / `NativeUse` appear nowhere in
`selfhost/*.zbr`. The BOOTSTRAP runs the whole chain in one command and prints 42.
So FFI works in Zebra today; it does not work in the compiler that ships. That is
what stands between this and a gated run-and-compare fixture.

**So `extern` should not be described as working until a probe CALLS a foreign function and
checks the value.** The declaration half is real and useful — it is what the sprocket work
needs to express bindings — but nothing yet proves one resolves.

---

## 7. Status 2026-08-05 (later) — STATIC C LINKING WORKS, END TO END, GATED

The remaining gap closed. `zebra.exe` now compiles, links and runs a C dependency in one
command, and a fixture asserts the printed value rather than the exit code.

    $ zebra.exe test/extern_c_call_test.zbr
    42

**The BUG-261 report above overstated the gap, and the overstatement was expensive** — it
described "no C-dependency handling whatsoever" and "a missing *subsystem*". Reading the
selfhost showed otherwise: the dep walk already found the `.c`, already put it in
`c_sources`, already recorded the header dir in `c_i_dirs`, already passed both to
`zig build-exe`, and already emitted an identical `extern fn` declaration. **One thing was
missing: nothing told the codegen**, so `genUse` fell through to `@import("<dep>.zig")`.
The fix was a native-use registry mirroring `CodeGen.native_uses`, and a branch in
`genUse` — not a subsystem. Sections 1-6 are left unedited as the record of what was
believed at the time; this section is the correction.

Worth keeping as a general lesson: *"feature X appears nowhere in `selfhost/*.zbr`"* was
established by grepping for the **bootstrap's identifier names** (`c_no_header`,
`NativeUse`). The selfhost had the capability under different names. A name-based absence
proof across two independently-written implementations says very little.

### What is covered, and by what

| | | |
|---|---|---|
| `.c` with no header (`extern def` → `extern fn`) | `smoke_run test/extern_c_call_test.zbr "42"` | **gated** |
| `.c` with a header (`@cImport` → `Alias.fn()`) | `smoke_run test/c_interop_test.zbr` | **gated** |
| the emitted Zig type-checks | `compile_check`, `full_sweep` | gated, but see below |
| DLL / shared-library symbol | — | **not supported** |
| native `.zig` dep | — | **broken in the selfhost (BUG-262)** |

**The compile-only gates cannot witness this feature.** They build with `-fno-emit-bin`,
so nothing links; an `extern fn` that resolves to no symbol whatsoever passes them
cleanly. Only the two `smoke_run` registrations exercise a real link. Do not read a green
`compile_check` as evidence that FFI works — it is not evidence either way.

**`c_interop_test` also had to be resurrected.** It and its `CUtils.c`/`CUtils.h` were
tracked in the repo, covered the header branch, and were registered in nothing — it could
not have passed while BUG-261 existed. Registering it retired one of
`registration_check`'s known-debt entries (20 → 19).

### A dependency is `@import`ed from TWO places, not one

`genUse` is the obvious site. `generateErrorMsgHelperWith` is the other — it emits
`@import("<dep>.zig")._error_ctx` per `use` for cross-module error propagation, and a C dep
has neither. Fixing only the first left the feature working in the default emit shape and
broken under `--no-runtime-module`, caught by **`compile_check-inline`** and by nothing
else in the FULL tier. The bootstrap had the guard already (`src/CodeGen.zig:2821`).

If a third site that `@import`s a dependency is ever added, it needs the same skip.

### One implementation note that cost a round-trip

The native-use registry is `List(str)`, not `StrSet`. A module-scope `StrSet` is emitted
correctly by the bootstrap and lowered by the **selfhost** as if it were a List
(`.append(_zbr_rt._allocator, path)`), which does not compile — so the compiler builds,
runs, and passes all 313 smoke fixtures while being unable to re-emit its own source. Only
`bootstrap_check` sees that. Filed as **BUG-264**; worked around here with the `List(str)`
+ linear-scan shape that `_implicit_try_sites` already uses.

### Still open

- **BUG-264** — the module-scope `StrSet` lowering above, still unfixed and only
  worked around.
- **BUG-262** — a native `.zig` dep is never materialized into the selfhost's temp emit
  dir, so `use SomeZigModule` fails there while working in the bootstrap. Same class as
  BUG-261, found while checking that this fix did not disturb that path (it did not).
- **BUG-263** — `use foo exposing bar` binds nothing when `foo` is native. A **shared**
  hole; fixing it in the selfhost alone would open a `divergence_check` selfhost gap.
- **DLL imports** remain unsupported, and the position on that is unchanged from section
  6: it needs `extern "lib" fn … callconv(.winapi)`, it is a Win32/shared-library feature
  rather than an FFI one, and the static path now working is a much better place to design
  it from. Nothing needs it yet.

---

## 8. Status 2026-08-05 (later still) — DLL SYMBOLS ALREADY WORK; §6-7's "unsupported" was wrong

Section 6 concluded that a DLL symbol needs `extern "kernel32" fn … callconv(.winapi)` and
that Zebra emits neither, so shared-library FFI was "not supported". That conclusion was
drawn from a segfault rather than from a controlled comparison, and **it is wrong on both
counts**. Re-measured:

### No new syntax is required. Any of these work.

    extern fn GetCurrentProcessId() u32;                              -> works
    extern "kernel32" fn GetCurrentProcessId() u32;                   -> works
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32; -> works

On x86-64 `.winapi` **is** `.c`, so the calling convention is a no-op here; it would only
matter on 32-bit x86, which Zebra does not target. The library name is likewise not needed
for COFF import resolution.

**A third-party DLL needs no syntax either** — a bare `extern fn` plus the import library
on the link line is sufficient (verified against a purpose-built `mylib.dll`/`.lib`:
`zig build-exe usr.zig -lc mylib.lib` → `triple=42`).

So "decision B's library-name half is no longer optional", recorded in §6, does not follow.
It remains optional, and nothing currently needs it.

### What actually breaks is the BUILD PATH — BUG-265

| invocation | result |
|---|---|
| `zebra.exe p.zbr` (default) | **segfault** |
| `zebra.exe --release p.zbr` | `dll-ok` |
| `zebra.exe p.zbr` with any `.c` dep present | `dll-ok` |

`selfhost/main.zbr:2550` takes the self-hosted backend (`-fno-llvm -fno-lld`) when
`not release and c_sources.len == 0 and not uses_sqlite`. A program whose only foreign
dependency is a DLL symbol matches that exactly. Isolated to the backend flags — not to
Zebra's emit (byte-identical to a working hand-written file) and not to `-lc` (LLVM
without `-lc` works):

| `zig build-exe a.zig …` | result |
|---|---|
| (default LLVM), no `-lc` | works |
| `-fno-llvm -fno-lld`, no `-lc` | **segfault** |

And it fails **silently**: the fast backend compiles cleanly, so the "fall through to LLVM
on a backend gap" safety net at `main.zbr:2536-2544` never fires. See BUG-265.

### Remaining work, if DLL support is to be a first-class feature

1. **Route `extern`-declaring programs to LLVM** (BUG-265). Mirror the `uses_sqlite` flag
   with a `declares_extern` one and add it to the condition. Both compilers. This alone
   makes DLL calls work with no flags.
2. **Naming a third-party library**, only if `use`-style ergonomics are wanted. The link
   line already accepts it; the question is purely how the author says so. Cheapest route
   is to extend the dep walk's candidate list (`.zbr`, `.c`) with `.lib`/`.dll`, reusing
   the native-use registry added for BUG-261 — the genUse arm for such a dep is the same
   "emit a comment, bind nothing" shape as `c_no_header`. `BuildTarget.linkLib` is the
   alternative and already exists, though it is still unexercised.
3. **`extern "lib"` / `callconv`** — measured unnecessary. Defer until a platform or a
   real use demands them.
