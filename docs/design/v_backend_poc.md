<!-- doc-status: proof of concept (2026-10-13); the result sections carry what the run said -->
# A V backend for Zebra — proof of concept (`zebra --target v`)

*Written 2026-10-13 on branch `v-backend-poc` (worktree `C:/Projects/zebra-vbackend`),
on Sean's ask: pull main, add V as a backend in a worktree as a proof of concept,
so the question "could V be Zebra's second backend" is answered with a run and
an estimate rather than an opinion. Nothing here is on main.*

## What it is for (Sean, 2026-10-13)

Two reasons, both of which move the estimate:

- **Vinix.** Sean is weighing the Vinix OS, written in V, as a daily driver.
  A Zebra program native to that OS wants a V backend, and the engine's "host
  stays Zig" line below becomes a road rather than a wall: a V host is a
  project, but it is the project that would matter there.
- **Openness.** V takes tickets and PRs from LLMs rather than refusing them,
  so a backend that finds V's bugs can send them back and have the language
  improve under it. The first night produced one confirmed (the generic
  `insert` miscompile below), with a twenty-line repro ready to post.

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

## Containers are references (decided and done for the subset, 2026-10-13)

Sean's decision: keep Zebra's reference semantics for containers (BUG-501
1d: two names for one container). A V array is a value copied on assignment,
so the backend boxes: `selfhost/zebra_rt.v` holds `ZList[T]` and `ZMap[K, V]`
as structs by reference with the methods on them (add, at, set, count, copy,
contains, clear, last, is_empty; set, get as an option, has, keys, remove,
count, copy), inlined at the top of every emitted file so one file runs. The
emitter maps `List(T)` to `&ZList[T]`, `List(T)()` and typed literals to the
runtime's constructors, the methods by name, iteration to `.items`, and the
nilable shapes a map needs: `orelse` as `or { }`, `if x as y` as `if y := x`,
`T?` as `?T`, `nil` as `none`.

The probe first (`C:/Projects/v-dist/probe/refsem.v`, six cases with asserts):
two names one container, mutation through a function and through a struct
field, an independent `copy()`, a boxed literal, a list of lists. Then
`examples/v_poc2.zbr`, the same six in Zebra plus a map through `get`,
`orelse`, `if as` and `keys`: **identical to the Zig backend's nine lines**,
nothing refused, no warnings; and `examples/v_poc.zbr` still identical to its
control under the new emitter.

Three V rules the emitter carries, each named by a V error:

- a mutating method cannot be called on a call's result (`rows.at(0).add(7)`:
  "cannot pass expression as mut"): the emitter binds a temporary;
- a reference field must be initialised: the constructor's struct literal
  initialises every reference field, a container by the runtime's constructor,
  a class-typed field by `unsafe { nil }` (Zebra's zero for it);
- a parameter mutated through a method is `mut` at the declaration and at the
  call (`fill(mut a, 3)`): a first pass collects which parameters are
  references, by callee name (a method name shared across classes keeps the
  first, a known coarseness until the emitter has types).

One V bug met and worked around, the repro at
`C:/Projects/v-dist/repro_v/generic_insert.v`: `l.items.insert(i, x)` on a
generic struct gets the other instantiation's element type once two
instantiations exist (`insert` / `removeAt` are out of the runtime until V
fixes it; the emitter refuses them by name). A first C error was attributed by
`-g` to `x in l.items` in `contains`; a standalone repro of that compiles and
answers correctly, so the attribution was the line map's, not a second bug
(`contains` stays a loop, which is right either way). One cost: a
reference per container, a deref per use, which is what V's `&Struct` pays
everywhere.

## The collector is a mode, not the default (Sean, 2026-10-13)

The Zebra language book argues against garbage collection, and V collects
by default (Boehm). The backend does not change the book's position by the
back door: `zebra --target v` says the run line as `v -gc none run <file>`,
under which V frees nothing, as Zebra's arena does today; `--gc` says it as
`v -gc boehm run <file>`. A program that wants the collector asks for it.
The book's line becomes "available as an explicitly enabled mode on the V
backend", wording for Sean to approve when the book is next touched. (The
F50 class of growth -- strings and containers never freed -- is what `--gc`
would end for a standalone program; the reference-counting decision for the
Zig backend stands.)

## The stdlib slice (2026-10-13)

The engine's own sources were counted for what they call (add, toString,
count, at, set, get, contains, append, tryFloat, toFloat, tryStr,
startsWith, to, toInt, substring, trim, keys, endsWith, split, join and
the Math set, in that order of use), and the Zig emitter's method surface
was read for Zebra's spellings (211 names). The slice maps, by name:

- **str**: len, upper / lower, startsWith, endsWith, contains, substring,
  split and lines and chars (boxed on return: a Zebra `split` is a List),
  join (a List(str)'s), trim / trimLeft / trimRight, repeat, indexOf,
  replace / replaceAll, padLeft / padRight, tryInt / tryFloat (as V
  options), equals, eqlIgnoreCase, reverse;
- **List**: add, at, set, count, contains, copy, clear, last, isEmpty;
- **HashMap**: set / put, get (an option), has, keys, values, remove, count,
  copy, clear;
- **Set** (`&ZSet[T]`): add, contains, remove, count, clear, items;
- **StringBuilder** (`&ZStringBuilder`): append, build, clear;
- **Math**: sqrt abs floor ceil sin cos tan pow min max atan2 by name,
  round and clamp through the runtime, `Math.PI` as `math.pi`;
- **File**: exists, read, write, append, listDir; **Path**: dirname,
  basename, stem, join; **sys**: exit, errln, cwd, args -- all over V's `os`.

Refused by name, with the reason in the refusal: a list's indexOf / remove /
reverse / sort (the receiver's type is needed to tell them from str's; the
emitter has no types yet), map / filter / reduce (closures), str.toInt
(the numeric cast is kept), str.charAt (Zebra's char is a number whose
toString prints it; V has no char to match), List.insert / removeAt
(vlang/v#30253), Json (the next slice: V's `json2.Any` has Zebra's Json
shape).

Three things the slice taught:

- **V's imports are per file.** The runtime is inlined after the emitted
  program's header, so the runtime file carries no imports and the header
  always imports math, os and strconv; a two-file check mimics that by
  concatenation, or every `os.` in the runtime is "undefined ident".
- **Generic methods are instantiated per element type**, so `join` (strings
  only) and `sort` (a comparable T) cannot live on `ZList[T]`: they are free
  functions (`zjoin`, `zsort_i64` / `_f64` / `_str`), and `sort` is refused
  until the emitter knows the element type.
- **Zebra's own spellings** came from the Zig control, not from me:
  `upper` / `lower` (not toUpper), StringBuilder's surface is append /
  appendChar / add / build / toString / clear / len, a char's `toString` is
  its number, and `//` has no infix form.

`examples/v_poc3.zbr` calls each mapped method once with an assert,
order-independent where the two backends' maps iterate differently, floats
cast to int before they print (V prints `3.0` where Zig prints `3`):
**identical to the Zig backend's seven lines** by diff, nothing refused, no
warnings; the first two programs still identical under the grown emitter.
Two Zig-backend quirks met on the way and told to the Zebra session: a
`.toInt()` on a call's result with a comptime-float operand, recorded as
BUG-559's second symptom (8fab325: the same chain temporary, untyped with a
literal operand, mis-lowered with a runtime one; the fix needs both a typed
temporary and the numeric lowering), worked around by binding the float
first; and `charAt`'s number.

## The type system's core (2026-10-13)

The first real target, `zbra/math.zbr`, constructs its structs with named
arguments and default parameters and prints with format specs, so those
came in with the slice:

- **a declarations pass** records every callee's parameter names, defaults
  and reference flags (a function, `new_<type>`, a method, by name); at a
  call, named arguments go to their positions, the unnamed ones in sequence
  to the rest, a missing one from its default, and `mut` where the parameter
  is a reference;
- **value structs** as V structs by value: `new_name(...) Name`, methods
  `(self Name)` or `(mut self Name)` when the body assigns to a field (a scan
  through if / while / for / branch bodies), `cue toString()` as V's `str()`;
- **enums** by name, their `branch` arms spelled `.member`;
- **unions** as V sum types over one struct per variant (`U_v { payload T }`,
  empty without a payload): `U.v(x)` constructs, `branch` is a `match` on a
  bound temporary (V smart-casts an identifier, not an expression), an arm's
  binding reads the variant's payload, `x is U.v` and `if x is U.v as p` are
  the smart cast;
- **`branch` on a plain value** as `match` with `else`; over a union or an
  enum the arms are counted against the type's members and `else` is
  emitted only when they do not cover it (V refuses both a non-exhaustive
  match without `else` and an `else` on an exhaustive one);
- **format specs** spliced into V's own `${x:.4f}` (a format part follows
  its expression in the AST's parts, which the run showed before the
  builder's source did).

`examples/v_poc4.zbr` (a struct with defaults, named arguments, methods and
a formatted `toString`; an enum and a branch on it; a union with payload and
payload-less variants, a branch with bindings, `is ... as`; a branch on an
int with several values and an else; a function with a default parameter
called both ways): **identical to the Zig backend's seven lines** by diff,
nothing refused, no warnings; the three earlier programs still identical.

Met on the way: V refuses a name beginning with `_` (temporaries are `zt1`,
`zm1`), a sum-type list literal needs each element cast, a struct's
constructor returns by value, Zebra's `sig` is a keyword (the emitter's
signature records are `fsig`); and the Zig backend's chain temporary showed
a third symptom (`a.add(b).scale(2.0)`, a struct method on a call's result,
reaches zig as a method on a `const` temporary), told to the Zebra session
and bound first in the test.

## Errors (2026-10-13)

Zebra's error channel is V's result type, shape for shape: a `throws` def
returns `!T` (`!` for none), `raise msg` is `return error(msg)` (the
details, when given, appended to the message: V's error carries one string,
nothing dropped), `f()?` is `f()!`, and `f() catch |e| fallback` is V's
`or { e := err ... fallback }` block, the block's last expression its value,
`e.message` as `e.msg()` on a binding the emitter knows is an error. V has
no try statement, so the **def-level `catch |e|`** is the def's body as a
result-returning closure over the def's parameters (`fn [mut xs, n] () !T {
... }()`), the catch as its `or` block; a `return` inside the `or` block
returns from the def by V's own rule, which is what Zebra's catch means. A
catch inside a method is refused for now (a closure's capture of `self` is
V's call), as is a typed catch clause.

`examples/v_poc5.zbr` (a throws def that raises, a `?` chain through a
second throws def, a def-level catch on a plain def, the expression-level
catch with and without its binding): **identical to the Zig backend's five
lines** by diff, nothing refused, no warnings; the four earlier programs
still identical. The one thing the control taught: a catch capture must be
used or omitted (Zebra's rule), so a fallback that ignores the error is
written `catch 0 - 1`.

## The first real targets (2026-10-13)

Measured as they stand, from the worktree root (the route finds
`zebra_rt.v` beside `selfhost/` or beside the binary, where a copy is
installed), the refusal lists as the distance:

- **`zbra/math.zbr`** (515 lines, nine value structs with methods, format
  specs, defaults and named arguments): 74 refusals, every one the same
  cause -- a struct without a `cue init` has Zebra's implicit constructor
  from its fields (Quaternion, Matrix3, CFrame). The emitter gives such a
  struct a constructor with every field a parameter in order and a zero
  default, its signature recorded, so named arguments reach it.
- **`selfhost/Token.zbr`** (349 lines, a union of forty variants, two
  classes): nothing refused; V's check named two things. Token's init
  assigns its fields **bare** (`kind = k`), which Zebra allows inside a
  class: a bare identifier that names a field of the enclosing type is
  `self.<field>` unless a parameter or a local declared so far shadows it
  (the locals are tracked per def through var, for and catch bindings).
  Keywords is all `static def`: a free function named `<class>_<method>`,
  reached by a call on the class's name.

After the two: both emit with nothing refused and pass `v -check`. V's
check is a type check; the run needs a driver, and the engine has one per
module. **`use`** came next: the route loads each used module (the file
beside the root, else under `--module-path`), transitively with a visited
set, parses, resolves and builds each, and the emitter runs its
declaration passes over all of them and emits every module's declarations
into the one V file, dependencies first; a `use` declaration emits nothing.
V's single namespace means a name shared across modules collides, which
the emitter does not yet detect (a known gap until a prefixing scheme is
wanted). Two V quirks of naming: a `*_test.v` is a test file to V and must
hold `test_` functions, so a Zebra `*_test.zbr` is written as
`*_test_prog.v`; and V prints a notice per unused function of a used
module, notices rather than errors, left as they are.

**`zbra/math_test.zbr`** (166 lines, `use math`): emitted as two modules in
one 28 KB file, nothing refused, and under V its **eight lines are
identical to the Zig backend's**: Vector2, Vector3, Color3, Matrix3,
CFrame, AABB, quaternions and cframeLerp all ok. The first engine code
through the backend, with a module boundary crossed.

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

1. **The stdlib surface** -- begun (the slice above: str, List, HashMap,
   Set, StringBuilder, Math, File, Path, sys by name; Json next). Still
   the long pole, as it is in the Zig emitter: every
   `str` / `List` / `HashMap` / `Set` / `StringBuilder` / `Json` / `File` /
   `sys` method the engine's code uses must be mapped or shimmed in a V
   preamble. V's own standard library covers most of them natively (strings,
   arrays, maps, JSON, os), so this is a mapping table plus a small
   `zebra_rt.v`, not a port of `stdlib_preamble.zig` (5,611 lines) — but it is
   the bulk of the work. Order of magnitude: the 3,663 lines above, re-expressed.
2. **Nilables, `orelse`, `if ... as`, `!`** -- done for the subset (the nilables with the containers, the errors above). They map onto V's option types
   (`?T`, `or { }`, `if x := y { }`) cleanly; the error channel (`throws`, `?`,
   `catch`, `raise`) maps onto V's result types (`!T`, `or { }`, `return error()`)
   cleanly too. Both are smaller than they look because V's semantics are the
   same shape.
3. **Containers as references** -- decided (kept) and done for the subset,
   see the section above: a boxed `ZList` / `ZMap` by reference in a V
   runtime. What remains is the rest of the method surface (sort, slices,
   `insert` once V fixes its generic `array.insert`, Set, StringBuilder) and
   the Zebra idioms that rely on the reference (`copy()` for a snapshot, a
   list handed to the host).
4. **Classes with interfaces, generics, unions, `branch`** -- unions, enums, value structs and `branch` done (the section above); interfaces and generics map onto V's
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

## If the branch ever merges to main

- `tools/regen_selfhost.sh`'s FILES list names CodeGenV (this branch); since
  1670756 the script refuses an emitted module the list does not name, so a
  merge that drops it fails by name.
- `tools/bootstrap_check.sh` keeps its own FILES list with the same seam
  (it checks the listed files are present); CodeGenV goes in there too, or
  the round-trip proof skips the new module without a word (the Zebra
  session's note, 2026-10-13).

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
