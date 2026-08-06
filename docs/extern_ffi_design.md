<!-- doc-status: design -->
# `extern` — declaring foreign symbols (BUG-258)

**Status:** DECLARATION implemented in both compilers; LINKING not solved. See section 6
for the current state — do not read sections 1-3 as future tense.
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
