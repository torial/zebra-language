<!-- doc-status: proof of concept (2026-10-13); the result sections carry what the run said -->
# A V backend for Zebra — proof of concept (`zebra --target v`)

*Written 2026-10-13 on branch `v-backend-poc` (worktree `C:/Projects/zebra-vbackend`),
on Sean's ask: pull main, add V as a backend in a worktree as a proof of concept,
so the question "could V be Zebra's second backend" is answered with a run and
an estimate rather than an opinion. Nothing here is on main.*

## What was built

- `selfhost/CodeGenV.zbr` (about 560 lines): a second emitter over the same
  front end (Parser → Resolver → ASTBuilder), writing V source for a **subset**
  of Zebra: free functions, classes (fields, `cue init`, methods), locals and
  `const` globals, if / else if / else, while, `for x in list`, `for i in
  a.to(b)`, assignment and the compound ops, return / break / continue, print,
  assert, calls, member access, `this`, binary and unary ops, the literals, list
  literals, string interpolation, if-expressions, and a hand-mapped slice of the
  stdlib surface (str, List, Math, the numeric conversions).
- Everything outside the subset is **refused by name and line** and listed at
  the end of the run; the `.v` is written anyway, partial where the refusals
  stood, and the tool says so. Nothing is skipped silently (the UNGIT tests:
  nothing withheld, nothing fabricated).
- `selfhost/main.zbr`: `--target v` beside `--target node-addon`, a route before
  the MultiCompiler that parses, resolves, builds the AST, emits, writes
  `<stem>.v` beside the source, prints the refusals and the `v run` line.
- `examples/v_poc.zbr`: a program entirely inside the subset, which also runs
  on the Zig backend, so the two outputs compare line for line.
- V itself: the official Windows release (`v_windows.zip`, V 0.5.2, commit
  7647ce1) at `C:/Projects/v-dist/v/`, with its bundled C compiler; a hello
  world compiled and ran before anything was emitted into it.

## V's own rules the emitter carries

| Zebra | V | why |
|---|---|---|
| `def setAnimate()`, `var winDist` | `fn set_animate()`, `win_dist` | V refuses uppercase in function, method, variable and field names; the emitter snake_cases them (and suffixes a V keyword with `_`) |
| `int` | `i64` | Zebra's int is 64-bit; V's untyped `int` is 32-bit, so a declared int carries `i64(...)` onto its literal |
| `class Name` | `struct Name { mut: ... }` + `fn new_name(...) &Name` + `fn (mut self Name) m()` | a class is a reference; V's `&Name` and a constructor function |
| `this`, `.x` | `self`, `self.x` | |
| `"text"` | `'text'` with `$` and `'` escaped | V interpolates `$` |
| `"a {x} b"` | `'a ${x} b'` | |
| `print(a, b)` | `println('${a} ${b}')` | |
| `List(int)` / `[1, 2]` | `[]i64` / `[i64(1), i64(2)]` | |
| `xs.add(x)`, `xs.at(i)`, `xs.count()` | `xs << x`, `xs[i]`, `xs.len` | |
| `s.startsWith(t)`, `s.substring(a, b)`, `s.trim()` | `s.starts_with(t)`, `s[a..b]`, `s.trim_space()` | |
| `x.toString()`, `x.toFloat()`, `x.toInt()` | `x.str()`, `f64(x)`, `i64(x)` | |
| `Math.sqrt(x)`, `a ** b` | `math.sqrt(x)`, `math.pow(a, b)` (+ `import math`) | |
| `and`, `or`, `not` | `&&`, `\|\|`, `!` | |

## What the run said

`examples/v_poc.zbr` compiled with `--target v`: **nothing refused, the whole
file in the subset**; `v run examples/v_poc.v` exited 0 with **no warnings**,
and its nine lines are **identical to the Zig backend's** (`diff` against the
control, which printed them first):

```
hits=5
a 64-bit int: 9000000000
words: alpha,beta,gamma,delta (4)
squares: 25
mean of three: 2.5
collatz steps from 10: 6
grade for 73: C
ok: true
v_poc: all ok
```

Five rounds to get there, each a fault the run named rather than one I guessed:

1. The selfhost regen refused main's emit on **unused arm bindings** in the new
   module (`on Expr.float_lit as fl` with `fl` unread): the compiler's message
   says the fix, write the arm bare. Three such arms.
2. `"${"` in a Zebra string **opens interpolation** (`${...}`), so the arm that
   built V's `${x}` never read its binding; `"\${"` is the literal (Zebra's own
   `\$` escape, BUG-385).
3. The build fell on **BUG-560** (filed by the Zebra session from this run's
   repro, corrected by them): a field named like a local class's List field,
   read through an imported class (`res.source.len` with another class's
   `source: List(str)` in main), is lowered as the List. Workaround: the field
   into a local first.
4. V refused the program on **three faults of the emitter**: `.count` mapped to
   `.len` for a *field* named count (only the property `len` maps now); a
   constructor named `new_99ounter`, because a Zebra string index is a byte
   whose `toString` is its number (the alphabet's chars are iterated instead);
   and the one refusal, an empty list literal without an element type (the
   type is the declared variable's). And V's warning on `if (x) {`: an outer
   balanced pair is stripped from conditions.
5. Then the diff.

What the run proves: the front end is shared unchanged, the subset's V is
V's own idiom (snake_case, `i64`, `&Struct`, `mut self`, `<<`), and the
refusal list is empty on a program that uses every construct the subset
claims. What it does not prove: anything about the stdlib surface beyond the
dozen methods mapped, nilables, errors, closures, interfaces, generics, or
the container semantics (item 3 below).

## The distance to a full backend, measured on the Zig emitter

`selfhost/CodeGen.zbr` is 21,402 lines in 495 functions. Counted by function
name (a rough cut; a function is counted once, by its first matching area):

| area | lines | share |
|---|---|---|
| expressions, statements, control flow (the proof of concept's subset) | 4,857 | 22.7 % |
| the stdlib method surface (`genMemberCall` alone is 2,856; Math, str, List, HashMap helpers) | 3,663 | 17.1 % |
| classes, structs, interfaces, mixins, generics, unions, enums | 1,591 | 7.4 % |
| closures, lambdas, captures, sigs, escape analysis | 644 | 3.0 % |
| errors: throws, try, catch, raise | 455 | 2.1 % |
| everything else: module assembly, the runtime module, node-addon, GUI, coverage, source maps, helpers | 10,192 | 47.6 % |

The proof of concept re-expressed the first area's *shape* in about 560 lines
because V's surface syntax is close to Zebra's for that area and because it
refuses rather than lowers what it does not spell. The honest estimate for a
backend that compiles the engine's `zbra/` and `game/mm/` sources (the real
test, since `luau2zebra.py` ports land there):

1. **The stdlib surface** is the long pole, as it is in the Zig emitter: every
   `str` / `List` / `HashMap` / `Set` / `StringBuilder` / `Json` / `File` /
   `sys` method the engine's code uses must be mapped or shimmed in a V
   preamble. V's own standard library covers most of them natively (strings,
   arrays, maps, JSON, os), so this is a mapping table plus a small
   `zebra_rt.v`, not a port of `stdlib_preamble.zig` (5,611 lines) — but it is
   the bulk of the work. Order of magnitude: the 3,663 lines above, re-expressed.
2. **Nilables, `orelse`, `if ... as`, `!`** map onto V's option types
   (`?T`, `or { }`, `if x := y { }`) cleanly; the error channel (`throws`, `?`,
   `catch`, `raise`) maps onto V's result types (`!T`, `or { }`, `return error()`)
   cleanly too. Both are smaller than they look because V's semantics are the
   same shape.
3. **Containers as references** (zebra-language BUG-501 1d, cfd2bc8): V's arrays
   and maps are *value* types copied on assignment unless passed as `mut` or
   held in a struct by reference. This is the semantic seam, the one the proof
   of concept did not reach: a Zebra `List` is one object under two names, a V
   array is two after `b := a`. A full backend either boxes containers (a
   `&[]T` behind every List, costing a deref on every use) or re-derives the
   container semantics for V. This is the decision to make before any of the
   rest, and it is Sean's.
4. **Classes with interfaces, generics, unions, `branch`** map onto V's
   interfaces, generics (`fn f[T]`), sum types and `match`; mechanical but wide
   (1,591 lines' worth).
5. **Closures** (the engine's capture closures since 838f05f) map onto V's
   closures, which capture by value unless `[mut x]`-listed; same seam as 3.
6. **The host interop** (`@import` of Zig, the raylib host, `_zbr_free`, the
   allocator installed by the host) has no V equivalent: the engine's host is
   Zig and would stay Zig; a V backend serves standalone Zebra programs and a
   future V host, not the engine as it stands.

A full backend is weeks, not days, with item 3 decided first. The proof of
concept's value is that items 1, 2 and 4 are mappings rather than inventions,
and item 3 is now named.

## Pros and cons, for the decision

**For V:**
- The surface syntax is close enough that the subset was a day's emitter; the
  reading above says the rest is mostly mapping.
- Compiles are fast and the toolchain is one download with a C compiler inside;
  no `zig` version pin on the user's machine (the proof of concept ran on the
  release zip alone).
- V takes outside tickets and PRs; an LLM-filed ticket is a normal event there.
  The private-fork cost you have paid with Zig has a route out.
- V's option and result types, interfaces, sum types and `match` are the same
  shapes as Zebra's nilables, errors, interfaces, unions and `branch`.

**Against, or to price:**
- **Value-semantic containers.** The one real semantic seam; see item 3.
- **V's churn.** 0.5.2 today; the language still breaks things between
  releases, and a backend pins to a V version exactly as the Zig one pins to
  0.16/0.17. A friendlier pin (one zip, no build), but a pin.
- **V's lints are errors**: unused variables, unused imports, uppercase in
  names. An emitter has to be tidy about what it declares, or every program
  fails on a warning. The proof of concept hit none because its test uses
  every variable; a real program's dead locals would.
- **The host stays Zig.** The engine would not move; this is a second
  backend for standalone programs, or a long road to a V host.
- **Two backends to keep in step** with every language change, or one that
  the other lags; the regen tooling and the drift alarm would have to grow a
  second target.

## How to run it

```bash
# in the worktree, on Zig 0.17
bash tools/regen_selfhost.sh --apply     # since f970e71 (the Zebra session, from this branch's finding): one default-flag
                                         # emit of main.zbr, every module validated against the committed one and installed
                                         # with zebra_rt.zig; on this branch all fourteen show 0 changed lines, CodeGenV among them
~/.zvm/0.17.0/zig.exe build
zig-out/bin/zebra.exe --target v examples/v_poc.zbr      # writes examples/v_poc.v, lists refusals
C:/Projects/v-dist/v/v.exe run examples/v_poc.v
zig-out/bin/zebra.exe examples/v_poc.zbr                 # the same program on the Zig backend: the control
```
