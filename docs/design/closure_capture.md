<!-- doc-status: design -->
# Implicit closure capture, by reference — BUG-569's fix

**Status:** direction decided by Sean 2026-10-14 ("(a), by reference ... similar to C#
semantics"). Drafted by Opus 5.5 on 2026-10-21. **Steps 1-3 of §6 are built (2026-10-21,
§7)**: read-only capture by copy, written captures refused by name. Step 4 (shared capture)
is not built; §5's three questions were answered by Sean the same day.
**Bug:** BUG-569 (`BUGS.md`). Its scope turned out wider than filed; see §1.

---

## 1. What is true today (measured 2026-10-21, on `6ec5333`)

QUICKSTART §19 shows a lambda changing an enclosing local (`counter += 1`) and says free
variables are "auto-captured". The ledger entry says reading a captured local works and
writing does not. **Both are wrong in the same way. An implicit capture works only when the
captured value is a compile-time constant.** `var k = 10` is emitted as `const k: i64 = 10`,
and Zig folds that into the inner function. Any runtime value fails inside zig with
`"k" not accessible from inner function`. `zebra -c` passes in every case below:

| probe | captured name | result |
|---|---|---|
| `var k = 10`, `def(x) = x + k` | comptime const | **works** (folded) |
| `var k = sys.args().len + 9`, same lambda | runtime local, read only | zig error |
| `def scale(m: int) ... def(x) = x * m` | parameter | zig error |
| `def(x) = x + .n` inside a method | `self` | zig error |
| `for x in xs` / `def(): int = x * 10` | loop variable | zig error |
| `xs.map(def(x) = x + xs.len)` | the receiver list | zig error |
| §19's own `counter += 1` | runtime local, written | zig error ("cannot assign to constant") |

These do work: module-level variables (module scope is reachable from the inner function),
and an explicit `capture` block (§19.1). The block is copied into a closure struct and
works with `map`. A `capture` closure used as a `sort` comparator fails inside zig
("unable to evaluate comptime expression"), so §3.5 has to fix that too (BUG-606).

So "auto-capture" today is a front-end promise with no lowering behind it. This is a
general leak, not a write-only one. Nothing that compiles today depends on a runtime
implicit capture, because none of them compile. That makes the change cheap to measure:
the only programs whose emit changes are the comptime-constant ones (§4).

## 2. The semantics (decided)

A lambda that names a local, parameter, loop variable or `this` from an enclosing function
shares that variable with the function and with every other closure that names it. A write
through the closure is visible outside, and a write outside is visible to the closure. This
is C#'s model, and Python's with `nonlocal`. §19's example becomes correct as written, and
the "read-only access in most cases" bullet goes.

## 3. The lowering

### 3.1 Free names

The checker already knows the enclosing scope when it walks a lambda body. The resolver
accepts the names, which is why `-c` passes. A lambda's **implicit captures** are the
names its body reads or writes that resolve to the enclosing function's parameters, locals,
loop variables or `this`, minus the lambda's own parameters, its own locals and its
explicit `capture` names. A nested lambda contributes its free names to its parent, as C#
does. This needs a PNode/Expr walker; it opts in to `lint_expr_walkers` (`# expr-walker:
exhaustive`), since a walker that misses a variant silently drops a capture. The walker
gate exists because of exactly that failure (BUG-260/267). It must reach names inside
string interpolation (`"${k}"`) and inside `zig"..."` literals. The boundary probe has a
lambda whose only use of the captured name is an interpolation.

### 3.2 Copy when nobody writes, box when somebody does

Capturing by reference and capturing by value cannot be told apart **unless someone writes
the variable after the closure exists**. So:

- **Never written after its declaration, by the function or by any lambda:** copied into a
  closure-struct field. This is the existing `capture` machinery, with the field
  synthesised (`k: i64` initialised from `k`). It covers parameters (BUG-354 makes them
  unassignable), loop variables (Zebra has no assignment to a `for` variable), `this`, and
  most locals. No allocation, and nothing changes outside the closure.
- **Written anywhere (outside its declaration, in the function or in any lambda):**
  boxed. The local's declaration becomes a heap cell (`const counter = _zbr_cell(i64, 0)`),
  every use in the function and in its closures becomes `counter.*`, and the closure
  struct holds the pointer. This is C#'s "display class", one cell per variable.

The rule is conservative. A variable written only *before* any closure exists is boxed,
although a copy would do. It is also syntactic and local to one function. That makes it
explainable and checkable, and it needs no flow analysis.

**The write detector is where this goes wrong silently.** Today an implicit capture fails
loudly inside zig. If the detector misses a write, the closure gets a stale copy and the
program prints a wrong value with no error. So "written" means every channel that can
change a value-type variable, each with its own boundary-probe row in the shape "closure
created; variable changed outside; closure called" (and the mirror: changed inside, read
outside):

- plain and compound assignment (`=`, `+=`, ...);
- a field write on a struct local (`p.x = 5`);
- a mutating method call on a struct local (`c.bump()`). Any method call on a struct local
  counts as a write unless the checker can prove the method does not mutate; start with
  "any";
- `<<-` copy-out;
- destructuring assignment;
- any of the above inside a nested lambda;
- assignment to a numeric `for` variable (§3.4).

A class instance or a container is a reference, so copying it shares the object and a
write *through* it is seen by everyone. Only rebinding the variable itself matters for
those, and that is the first channel. The detector is red-checked by removing each channel
in turn and watching its probe row fail. That is the real attacker, not a mutation of the
gate.

### 3.3 Lifetime: why the cell is on the heap

A stack pointer would be wrong for any closure that outlives its frame: one that is
returned (§19.2's factories), stored in a field or a list, or handed to `sys.go`. Telling
those apart takes escape analysis, which the compiler does not have, and a wrong guess is a
dangling pointer, not a zig error. So every cell is heap-allocated from the program's
allocator, as C# does unconditionally. The cost is one allocation per boxed variable per
time its declaration runs. Under §3.2 only *written* captured variables pay it.

**OPEN (Sean) — the allocator.** The program arena never frees, so a loop that runs a
boxed declaration a million times keeps a million cells. That is the same open question
as long-running-program memory on the 1.0 list. A cell could instead come from `_allocator`
and be freed with its frame when no closure escaped, but that is escape analysis again. My
recommendation is the arena now, with the cost stated in QUICKSTART, revisited with the
long-running-memory decision.

### 3.4 Loop variables

Each iteration of `for x in xs` gets its own `x`, as in C# 5: a closure made in iteration 2
sees iteration 2's `x`. For `for x in xs` this falls out of §3.2: the variable cannot be
written (an assignment to it is a zig error today, BUG-608, and will be a front-end
refusal), so it is copied at the moment the closure is made.

**A numeric `for` variable CAN be written.** `for i in 0 : 3` with `i = i + 1` in the body
is accepted and changes the iteration (it prints `1 3`; measured 2026-10-21). A closure
over it that never writes it is still a per-iteration copy. A numeric `for` variable that
is captured *and* written by the body is refused by name: per-iteration sharing and a
counter the body steers cannot both hold. That case is rare, and the refusal's fix (copy
it into a local first) is one line.

A local declared *outside* a loop and written inside it is one boxed variable shared by
every iteration's closure, which is also C#'s behaviour.

### 3.5 Where a closure struct goes

A closure that captures is a struct, not a bare `fn`. Every place that accepts a function
value has to take one. `_ZbrFn(sig)` does already (`.from` / `.fromRef`), and `map` does.
`sort` / `sortBy` comparators do not (§1, BUG-606). Expect a short tail of others to show up once
captured lambdas compile; leakgen's generator should learn to emit captured lambdas so the
tail is found by the fuzzer and not by users.

### 3.6 `this` inside a method

For a class, `self` is a pointer and is copied like any never-written value, so the closure
writes the same object. A **struct** method's `self` is a value. A closure that writes a
field of it (`def() = .n += 1`) would write a copy, which reads as a silent no-op. Refuse
that in the front end and name the fix ("a struct is a value; return the new value, or make
it a class"). Reading struct fields is fine.

## 4. What changes for programs that compile today

Only the comptime-constant captures (§1, row 1). Their emit changes from the folded constant
to a closure-struct field; their behaviour does not. Measure it with the emit A/B over the
repo, zebra-ide and the engine before landing; output_sweep should show behaviour
identical. Every other implicit capture moves from "zig error" to "compiles".

## 5. The three questions -- DECIDED (Sean, 2026-10-21)

1. **A closure value is a reference.** Every holder of one closure -- a local, a parameter it
   was passed to, a field or list it was stored in -- sees the same `capture` state, as with a
   C# delegate. BUG-607 tracks it. The borrow fix alone (`.fromRef(&b)` on the caller's own
   variable) covers a closure passed INTO a call, but a closure stored in a field or list goes
   through `.from`, which heap-copies, so two holders would still diverge. The complete form
   makes a capturing closure a heap object from its creation, the way a class instance is,
   which shares step 4's machinery (cells in the arena), so it lands with step 4.
2. **`sys.go` keeps the explicit `capture` rule** -- as built in step 3.
3. **Cells live in the program arena** -- §3.3's recommendation; revisit with the
   long-running-memory work.

The original questions follow, as written before the answers.

### As written (OPEN at the time)

1. **Is a closure *value* a reference?** Today a `capture`-block closure is copied when
   it is passed to a function (BUG-371's borrow copies it into a block-local; filed as BUG-607), so its state
   does not survive the call: `apply(b, 1)` twice printed `9 9`, while calling `b()` twice
   counts up. Under C# semantics a delegate is a reference and the count would carry
   through. Implicit captures in §3.2 do not depend on this: boxed variables are shared
   through the pointer either way. Explicit `capture` state does. My recommendation is
   reference: pass `.fromRef(&b)` on the caller's own variable instead of a copy, and
   say so next to §19.1.
2. **`sys.go`.** QUICKSTART requires an explicit `capture` for a thread closure. Under this
   design an implicit capture into a thread is either a copy or a shared, unsynchronised
   cell, the same as containers since 2026-10-06. My recommendation is to keep requiring
   `capture` for `sys.go`: a shared cell between threads is a data race the program never
   asked for, and the explicit block makes the sharing visible.
3. **The allocator for cells** (§3.3).

## 6. Plan (once §5 is answered)

1. Boundary probe first, written from §19 and this note, unrun before the commit
   (boundary_check's discipline): every row of §1 plus the §3.4 loop case, the §3.2 shared
   write, a returned closure over a boxed local, and the §3.6 refusal.
2. The free-name walker (§3.1), gated by `lint_expr_walkers`.
3. Copy captures (§3.2, first half): the synthesised `capture` fields. This alone fixes
   every read-only row of §1. In the same step, a captured variable that IS written gets a
   named front-end refusal ("`counter` is changed after the closure captures it, and
   shared capture is not built yet; use a `capture` block for state the closure keeps").
   After step 3 every row of §1 either works or is refused by name, so the leak class is
   closed even if step 4 waits. Steps 1-3 depend on none of §5's open questions.
4. Boxed captures (§3.2, second half, and §3.3). The step-3 refusal is removed.
5. Comparators and other function-value sinks (§3.5); leakgen learns captured lambdas.
6. QUICKSTART §19 rewritten; §19's example becomes a `smoke_run` fixture, so the doc and
   the compiler are tied together.

Each step lands separately, with the emit A/B, the `-c` A/B over the three corpora, and a
FULL tier.

## 7. What was built (steps 1-3, 2026-10-21) and what it does not do

- **Where the capture is made: the Resolver.** It is the one pass that already knows, for
  every name, whether it is a local, a parameter or a module name -- and over-including a
  module variable would have been a silent copy. Each lambda walked pushes a frame of its own
  names; a name read that is not the lambda's own but is a function-level local or parameter
  becomes an implicit capture of every frame it crosses. When the function's walk ends, those
  are appended to the lambda's `capture` list (`PCaptureVar.is_implicit`, carried into the AST
  as `Modifiers.is_implicit_capture`), so the checker and all fifteen codegen consumers of
  `captures` see one uniform form. Appending at the END means a path that ignores the
  Resolver's errors (`main.zbr`'s dependency pass) never gets a capture that should have been
  refused: the lambda still names a runtime local and zig refuses it, loudly.
- **The walker is the Resolver's own** `resolveExpr` / `resolveStmt`, which `lint_expr_walkers`
  already holds exhaustive over `PNode` (BUG-571, BUG-593), so §3.1's separate walker was not
  needed; the interpolation row of the boundary probe is the check that names inside `${...}`
  are reached.
- **Not captured:** a local bound to a lambda that itself captures nothing -- it is a comptime
  function in the emit, and copying it would make the closure struct comptime-only.
- **Field types** come from inference (`implicitCaptureZigType`), not `@TypeOf(local)`; a closure
  factory's hoisted struct is typed under the factory's own context (`closure_ret_ctx`: params
  bound, body walked), since it is emitted at module scope.
- **The write rule, in two places.** A REBOUND variable (`=`, a compound assignment, `<<-`) is
  syntactic: the Resolver refuses it at the write, naming the closure's line. A struct changed
  IN PLACE needs types, and CgHelpers -- which the TypeChecker cannot import -- holds the oracle
  (`scanMutations`), so codegen emits a Zebra-worded `@compileError` in the field's type. That
  half is seen at build, not by `zebra -c` (the documented front-end asymmetry). A class
  instance or a container changed through its reference is not a write of the variable: the
  copy shares the object (`test/bug569_capture_refs_test.zbr`).
- **`sys.go`** keeps the explicit-capture rule (§5.2's recommendation), refused by name.
- **§3.4 correction.** "A `for` variable cannot be written" was false when written: assigning
  one passed `-c` and failed inside zig (BUG-608, fixed the same night). It is true now for
  `for ... in`; a range counter is still assignable, and a captured, written counter falls to
  the general rebinding refusal.
- **`this` inside a lambda (same day, a later commit).** In a CLASS method the Resolver
  captures `this` as a hidden `_zbr_this` field (typed `*Class`) and codegen points the
  closure's `self_name` at it, so `.n`, `this.n` and `.f()` all read through the copy -- a
  class instance is a reference, so a write through it is shared, which is §2's semantics
  exactly. In a STRUCT method `this` is a value; a closure reading it is refused by name
  (§3.6), naming the local that works. A pipeline's right side (`s -> .upper()`) is a bare
  leading-dot member that is NOT `this`; the Resolver walks it without noting `this`.
- **The probe's loop row** (`bv_closure_capture_read`) calls each iteration's closure inside
  that iteration, so per-iteration copy and a shared variable print the same 60 there. The
  discriminating row -- closures kept and called after the loop -- belongs to step 4's probe
  (and needs BUG-563's list of lambdas, or a capture-free container of them).
- **Measured before landing:** `-c` over the repo (1,108 files), zebra-ide (29) and the
  GameEngine (1,848): the repo and zebra-ide moved 0. The engine moved two hand-wired scripts,
  `game/scripts/portal_oscillate.zbr` and `dancing_shelly.zbr`, from passing to a named
  refusal: each accumulates into an enclosing local from a Heartbeat closure -- shared
  capture, step 4 -- and neither emit could ever have compiled (`t = (t + dt)` inside a nested
  function); `build.zig` registers them with `_ = script_...;`, so zig never analysed them. The
  other 78 moved files are machine-ported scripts that already failed. The emit A/B moved three
  corpus files, all compile-time-constant captures now carried as fields, each printing exactly
  what it did.
