<!-- doc-status: design -->
<!-- Status: proof of concept (2026-10-13); the result sections carry what the run said -->
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

## The Lexer: the first compiler module through (2026-10-13)

**`selfhost/Lexer.zbr`** (1016 lines: a class with twenty-odd methods
over a source string, a `sig`, module-level `static def` predicates,
char literals everywhere, slices, lambdas, `branch` over char ranges)
measured 298 refusals as it stood, then went through in four rounds:

1. **The kinds it names.** 270 of the 298 were char literals behind one
   catch-all message; the catch-all is split per kind now, and the
   emitter spells `c'A'` as `` u8(`A`) `` (Zebra's char is a byte; V's
   rune literal cast), a slice as `s[a..b]`, a cast as `T(x)`, a chained
   compare as its conjunction, a `sig` as `type F = fn (...) R`, a lambda
   as `fn [captures] (...) R { }` (a captured container or class is a
   reference either way; a `mut` capture where the type is one), and
   `for i in a..b` as V's counted loop.
2. **Names across the module boundary.** `Token.Token` and
   `Token.Keywords.lookup` came out verbatim and broke V's parse of the
   struct (`unknown type Lexer` 22 times was the cascade). The emitter
   notes the used modules' names from the `use` declarations; a dotted
   type is its last segment; `Mod.Name(args)` is the module's declaration
   (the class's constructor when Name is a class); the owner of a static
   access (`Mod.Class.method`, `Mod.Enum.member`, a union's variant) is
   read through the module. `on c'0'..c'9'` is V's inclusive range arm
   `` u8(`0`)...u8(`9`) `` (V takes the cast form; probed).
3. **What V could not see.** 200 errors after that, nearly all one
   cascade: Zebra allows a bare call to a method of the enclosing class
   (`peek()`, `emit(k, t, ln, cl)`), which V reads as an unknown free
   function, and everything downstream is `void`. The emitter now keeps
   the enclosing class's instance and static method names (a bare call
   among them is `self.m(...)` or `class_m(...)`), and **the V type of
   every parameter, local and field** (declared, or inferred from a
   constructor call or a union variant), which pays three more ways:
   `.len` on a container is `.count()` (a string's stays `.len`); a
   list's `remove` / `indexOf` / `reverse` reach the list's own methods
   where the string's were taken by name before; `out = List()`
   (untyped, the field's type implied) takes the target's constructor.
   And a local bound to a union variant (`var kind =
   TokenKind.zig_single()`) is cast to its union, since V types the
   variable by the variant struct and refuses the next assignment of
   another variant -- the two "cannot assign to kind" errors.
4. **The driver.** `selfhost/lexer_test.zbr` no longer compiles on the
   Zig backend (a static `main` inside the class beside the module's
   `main`: "duplicate struct member name"), so `selfhost/lexer_dump.zbr`
   stands in: fifteen sources tokenized and every token printed (kind
   name for thirty kinds, text, line, col; an unterminated string's error
   caught and printed). Its round found `use Lexer` then
   `Lexer.tokenize(src)`: a module whose name is also its class's, so
   `Mod.x(args)` is the class's static method unless x names a type; and
   the method lists are cleared at a class's end (a later bare call
   matched the last class's statics and spelled `_tokenize`).

After the four: the Lexer emits with **nothing refused and passes V's
check** (51 KB, two modules), and the dump under V is **identical to the
Zig backend's, 117 lines** -- keywords, identifiers, indentation (indent /
dedent / eol), comments, operators, numbers, strings, a char literal, a
range, `use ... exposing`, if / else, and the unterminated string's error
message. The six earlier programs stay identical.

Two things the round found beside the emitter, both unfixed:

- **A module loaded twice.** The driver first sat in
  `C:/Projects/v-dist/targets/`, which held a stale `token.zbr` copy; the
  route resolved the driver's `use Token` to that copy and the Lexer's to
  `selfhost/Token.zbr`, and emitted both ("cannot register struct
  TokenKind_indent, another type with this name exists"). The route
  dedups by file path; it should refuse two files for one module name,
  naming both. Noted, not built.
- **The Zig backend's `--module-path` from outside the directory.** The
  same driver run on the Zig backend with `--module-path selfhost` wrote
  the scratch build without `Lexer.zig` ("unable to load 'Lexer.zig':
  FileNotFound"); the driver beside the sources builds. A Zig-backend
  gap, not the V backend's; for the Zebra session.

New rows for the rules table:

| Zebra | V | why |
|---|---|---|
| `c'A'` | `` u8(`A`) `` | a char is a byte; V's rune literal is a rune (i32) |
| `on c'0'..c'9'` | `` u8(`0`)...u8(`9`) `` | V's match range arm is three dots, inclusive |
| `peek()` inside a class | `self.peek()` | V has no implicit receiver |
| `var k = U.v()` | `mut k := U(U_v{})` | V types a variable by the variant struct unless cast to the sum type |
| `xs.len` on a List | `xs.count()` | the runtime's list is a struct; `.len` is the string's and the array's |

## The Parser: the front end's second half through (2026-10-13)

**`selfhost/Parser.zbr`** (3810 lines: a class of a hundred-odd methods
over the token list, a 150-variant `PNode` union of boxed records,
def-level catches inside methods, a module-level var) measured 70
refusals and 200 V errors as it stood; four rounds:

1. **`^T`, the boxed record.** 67 of the 70 refusals were the `^T` type
   (the union's payloads, the records' fields). V cannot take the
   address of a call's result, so a struct any `^` targets anywhere (a
   pass over every payload, field, parameter and return) becomes a
   **reference type**: `&Name` wherever it is named, `@[heap]`, its
   constructors allocating -- what a boxed node is on the Zig backend
   too. The cost, stated: a by-value copy of such a struct elsewhere is
   a shared reference in V. A `^U` of a union is the union by value: V's
   sum type is already a boxed fat pointer. With that, the 74 "expected
   a pointer" and 72 "allocate on the heap" errors went. The same round:
   a def-level catch inside a method captures `mut self` (probed: V
   allows it), a name beginning with `_` is prefixed `u`, a module-level
   var with an initializer is a V const (an assignment to it refused
   with the reason: V has no mutable globals without `-enable-globals`),
   a `mut` argument that is not an lvalue (a fresh container, an
   element) is bound to a temporary on a line before the statement,
   `lastIndexOf` on a string, and the compiler's own
   `zig"_error_ctx.message"` inside a catch is V's `err.msg()`.
   Zebra's `List.remove(i)` is by **index**, which the Lexer round had
   mapped by value: corrected (`remove_at`).
2. **V's last twenty.** `x == U.v` against a payload-less variant is
   V's `x is U_v` (a sum type and a variant struct do not compare by
   `==`); `var x: str? = nil` is `?string(none)` (V types `none` alone
   as none); the payload type of every variant and the type of every
   field of every type are kept, so an `as` capture and a branch binding
   have a type and `.len` through a field chain is `.count()`;
   `Dir.exists`. Nothing refused, V's check clean.
3. **The driver.** `selfhost/parser_dump.zbr` parses eleven sources
   (a function, a class with init / method / static, a struct, an enum,
   a union, control flow, `use` / a module var / a `sig`, a def-level
   catch, two broken ones) and prints the tree's shape -- declaration
   kinds and names, members, every statement by kind, nested. Its first
   run: a branch binding whose payload is a reference must be `mut`,
   since V refuses `mut x.field` through an immutable binding (seven
   errors, one cause).
4. **V's C stage.** The check passed and the C compiler failed inside
   the runtime: V instantiates **every method of a generic struct per
   element type**, so the list's `contains` was built for `PNode`, and
   V's C for `it == x` over that sum type treated the values as pointers
   (`*it`, `*x`) and did not compile. The comparing helpers (contains,
   indexOf, remove by value) are free functions now, instantiated only
   where called, and the emitter reaches them when it knows the receiver
   is a list. The V bug is pinned and filed as **vlang/v#30275**
   (2026-10-13, 28 lines): a generic method comparing two `T` values is
   emitted with *another instantiation's* equality function once the
   struct is instantiated for a sum type and for a struct that holds a
   reference to that sum-type instantiation -- the second instantiation
   need only exist as a type, not be called. Five hand-written probes
   had all passed; what found it was a two-stage reduction of the 181 KB
   failing file (the union's 75 variants delta-debugged to two, then the
   file's top-level blocks to eight, then the eight re-read by hand into
   the repro). The generated C says it plainly: `Box[Tree].has` compares
   two `main__Tree` with `main__Param_struct_eq`. Related to #30253 (the
   insert miscompile), the same family.

After the four: **the parse dump under V is identical to the Zig
backend's, 55 lines**, and Token + Lexer + Parser -- about 5,200 lines
of the compiler's front end -- run on V with nothing refused. The six
programs and the Lexer's dump stay identical.

New rows for the rules table:

| Zebra | V | why |
|---|---|---|
| `^T` (a boxed struct) | `&T`, the struct `@[heap]`, its ctor returning `&T` | V cannot take a call result's address; a boxed node is a reference anyway |
| `^U` (a boxed union) | `U` | V's sum type is a boxed fat pointer already |
| `x == U.v` | `x is U_v` | a sum type and a variant struct do not `==` |
| `var x: T? = nil` | `mut x := ?T(none)` | `none` alone is typed none |
| `f(List())` for a `mut` param | `mut zt1 := new_zlist[T]()` then `f(mut zt1)` | `mut` takes an lvalue |
| `var G: T = v` at module level | `const g = v` | no mutable globals without `-enable-globals`; an assignment refused |
| a generic method comparing `T` | a free function | V instantiates every method per element type |

## The whole front end through (2026-10-13)

After the Parser, the rest of the front end -- **Ast** (1243 lines),
**AstWalk** (755), **AstBuilder** (1605) and **Resolver** (523, which
folds in **TypeChecker** (7924) and **CgHelpers** (2147) through its
`use` lines: eight modules, 567 KB of V) -- measured 1,664 / 1,729 /
4,739 / 3,326 V errors as they stood, all from one cause, and went clean
in seven rounds:

1. A reference to a nilable (`^Expr?`) came out `&?Expr`, which V's
   parser refuses, and the whole file after it was noise: it is `?Expr`
   for a union and `?&Name` for a boxed struct. A refusal names its
   **file** with the line now (eight modules in one emit; a bare line
   number pointed at the wrong module). `for k, v in m` is V's loop over
   the runtime's inner map, the two variables typed from the map's type.
   A method name shared by two classes with different parameter lists is
   called by position (the signature table was keyed by the bare name and
   refused the second class's calls as "more arguments"). A mutable
   module-level var is a V `__global`, and the route's run line carries
   `-enable-globals` when any exists (the const rule before it was a lie
   the TypeChecker's three globals exposed).
2. The runtime's containers are `@[heap]` (an option of a reference to
   one can then be stored in a field: V's escape rule); a map's `contains`
   and `fetch` (Zebra's get-or-fail); `s.chars()` is the bytes (Zebra's
   char is a byte); the element type of `xs.at(i)` and of a `for x in xs`
   variable is known; an `if x as y` over an option of a reference binds
   `mut` and is typed.
3. A left-leaning chain of one operator is emitted flat, and past thirty
   terms an `or` / `and` goes through `zany` / `zall` over a list: **V's
   checker gives up at forty nested levels** ("too many expr levels: 41"
   on a fifty-term keyword test), and the tree is the depth whether or
   not the parentheses are written -- so the long form loses
   short-circuiting, said in a comment. `x!` on a name is `zunwrap(x)`, a
   generic helper, since V smart-casts an option after `x != none` and
   then refuses an `or` block on it. A binding whose type is a struct, a
   class or a container is `mut`. `xs.sort()` by the list's element type.
   The compiler's own `zig"_zbr_version"` is a runtime const.
4. A for over elements that need `mut` runs **by index** with `mut x :=
   xs.at(i)`: V's `for mut x` makes a reference to the element (`&&T`
   over a list of references) and needs the list's root mutable. The
   return type of every def and method is kept, so a call's result has a
   type. `x is Enum.member` is `==`. A numeric local is cast to its
   declared type whatever its initializer (`var pos: int = -1` was V's
   32-bit int). A used module's `main` is not emitted. **Zebra's string
   escapes are translated, not passed through**: the lexer keeps them raw
   and the Zig backend passes them on, but `\$` reached V as an escaped
   backslash before an interpolation. An `is` on a call's result binds
   the subject first (V smart-casts names, not calls).
5. A `mut` value-struct parameter -- tried for `f(mut m.decls)` through an
   immutable parameter -- made V demand `mut` at every call site and
   broke two earlier witnesses; undone. The case is solved at the call
   site: a `mut` argument that is a field path not rooted at `self` is
   bound to a local first (a reference field copied is the same
   container). The implicit constructor declares `mut` on its reference
   parameters, as its recorded signature always said.
6. The list's `str()` method, instantiated for f64 by the uncalled sort
   helper's signature, made V emit its own float-array string method
   with a helper its unused-pruning had dropped (`StrIntpData` undeclared
   at the C stage; `-no-skip-unused` runs the program identical). A free
   function now. A fifteen-line probe does not reproduce it; not filed.

The witnesses: **`selfhost/ast_dump.zbr`** parses and builds eleven
sources and prints the built tree (else-if chains, a branch's arms, a
catch's clauses): **69 lines identical** on both backends.
**`selfhost/resolver_dump.zbr`** resolves six sources through the
Resolver -- which runs the TypeChecker's inference and CgHelpers -- and
prints the count and every message: **11 lines identical**. With the
Lexer's and the Parser's dumps, the six programs and the engine's math
test, ten witnesses hold, and the front end but CodeGen -- about 16,000
lines of the compiler -- runs on V.

What the pipeline learned about itself on the way, each a false green
caught after the fact and closed: it carried on after a refused regen
and diffed the old binary (stops now); it printed "build exit 0" for a
failed build through a pipe (the build's own exit gates it now, and a
binary older than its source is refused); it called two empty files
identical (an empty control is "no control" now).

New rows for the rules table:

| Zebra | V | why |
|---|---|---|
| `^Expr?` | `?Expr` / `?&Name` | never `&?T` |
| `var G: T = v` at module level | `__global ( g = v )` + `-enable-globals` | the real mutable global |
| `a or b or ... (50 terms)` | `zany([a, b, ...])` | the checker's forty-level limit; no short-circuit |
| `x!` after `if x != nil` | `zunwrap(x)` | the smart cast refuses `or` |
| `for x in xs` with `mut x.field` passed on | by index, `mut x := xs.at(i)` | `for mut` references the element |
| `f(mut p.field)` through an immutable `p` | `mut zt := p.field` then `f(mut zt)` | a reference copied is the same container |
| `"\$"` in a string | `'\$'` | the lexer keeps escapes raw |

## CodeGen: the whole compiler through (2026-10-13)

**`selfhost/CodeGen.zbr`** (21,437 lines, the Zig emitter: a Generator
struct of a hundred-odd methods, a Writer, the `except` records, every
idiom the language has) measured 28 refusals and 200+ V errors as it
stood and went through in twelve rounds; the last four were one crash.

1. A struct whose methods assign its fields has **every** method on
   `mut self` (a per-method test missed bare-name assignments and calls
   into mutating methods: 181 of the errors); `base except f = v` is V's
   struct update `Name{ ...base, f: v }` (the pointee spread for a
   class); an `is` subject that is not a name is bound first.
2. A mutating call on a receiver that is not a name (`x!.stmts.add(s)`)
   binds the receiver first, never inside a loop condition; the mutating
   structs are known before emission (a pass); a union's variant read as
   a field (`fi.iter.call`) is `(x as U_v).payload`; `items()` /
   `keys()` / `values()` / `copy()` typed; `concat`, `isNumeric`; a
   reference parameter stored into a field through `unsafe { }`; every
   class `@[heap]`; a missing-argument refusal names its callee.
3. A local initialized from any expression takes the expression's type;
   an unwrap has its option's inner type.
4. A map's `get` / `fetch` and a list's `last` typed.
5. The cross-module collision the note called a known gap, hit:
   `typeRefStr` in both CgHelpers and CodeGen. A free function declared
   in more than one module is `<module>_<name>` wherever declared, and a
   bare call resolves to the current module's own, else a used module's;
   `main` exempt.
6. **V's smart cast, three rounds.** V narrows a name after `x == none`
   / `x != none`; on the narrowed name an `or` block is refused, the
   generic unwrap helper's re-wrap fails at the C stage ("cannot convert
   TRef to _option_TRef", 25 lines, filed as vlang/v#30277), the explicit
   option cast works for a parameter but not for a `mut` local
   (another C-stage failure), and the narrowing does not carry into a
   binding (`y := x` stays an option). Mirroring the smart cast in the
   emitter (a round, undone) hit the binding case. What holds: **a nil
   comparison is a helper call** (`zis_none(x)`), which V does not narrow
   through, so an option keeps its type everywhere and the one unwrap
   `zunwrap(?T(x))` is right in every position.
7. A Zebra name that is a C keyword or a tcc calling-convention word
   (`cdecl`, a loop variable) is suffixed: V emits it into its C verbatim
   and tcc reads the keyword ("identifier expected").
8. **The crash.** The dump then compiled and segfaulted before its first
   line, with no backtrace from tcc on Windows ("Unhandled Exception" and
   three frames of V's own handler). The instrument was a tracer that
   inserts `eprintln('> name')` at every function entry of the emitted
   file (`scratchpad/v_trace.py`, 1,295 functions), then single-value
   probes at the last function entered: the module-class lookup returned
   an address that was not the object. Sixty lines reproduced it, thirty
   pinned it: **a `mut c &T` parameter used as a value is the address of
   the caller's slot** -- field reads through it deref twice and work,
   but stored into a map or a field it is a stack address. `mut c T` and
   `c &T` store the object. The emitter had declared every reference
   parameter `mut x &T`; it declares `mut x T` now. V's escape analysis
   had refused plain stores of such parameters earlier and the round
   that wrapped them in `unsafe { }` was hiding the right message.
   Filed as vlang/v#30276 (`repro_v3/storeparam.v`, 30 lines).
   Also on the way: a set or string-builder field of a class starts as
   its constructor, not nil.
9. A char's `toString` is the character (`ascii_str()`), a byte's its
   number: a Zig type name built char by char came out `105110116` for
   `int`, the only difference left in the generated Zig.

The witness: **`selfhost/codegen_dump.zbr`** parses, resolves, builds
and generates three sources through CodeGen and prints the module's
Zig without the preamble: **132 lines, byte-identical** to what the
Zig-built compiler generates. With the ten before it, eleven witnesses
hold, and every module of the compiler -- Token, Lexer, Parser, Ast,
AstWalk, AstBuilder, TypeChecker, CgHelpers, Resolver, CodeGen, about
38,000 lines -- emits with nothing refused, passes V's check, and runs.
What is not through: `main.zbr` itself (the route, the build driver, the
`zig` literals of host interop) and `Checker`; a Zebra compiler binary
built by V is the next step after them.

New rows for the rules table:

| Zebra | V | why |
|---|---|---|
| `def f(xs: List(int))`, `def f(c: Node)` | `fn f(mut xs ZList[i64])`, `fn f(mut c Node)` | never `mut x &T`: used as a value it is the slot's address |
| `x == nil` | `zis_none(x)` | V's smart cast never triggers; the unwrap stays one form |
| `base except f = v` | `Name{ ...base, f: v }` | V's struct update |
| `fi.iter.call` (a payload by its variant's name) | `(fi.iter as Expr_call).payload` | |
| a name `cdecl` | `cdecl_` | tcc's keyword |
| `ch.toString()` on a char | `ch.ascii_str()` | a byte's `.str()` is its number |

## The compiler binary, and what it costs (2026-10-13)

**`selfhost/main.zbr`** (5385 lines, the route: the CLI, the build
driver, the LSP server, the debugger bridge, the updater) and
**`Checker`** (765) went through in fourteen rounds, and `zebra --target
v selfhost/main.zbr` now writes one V file that V builds into
**`zebra_v.exe`, a Zebra compiler built by V**. What it took, beyond the
earlier rules:

- **A function holding a refused construct is a stub.** Its body is
  captured while emitted; if anything in it was refused, the body is
  replaced by `panic('not on the V backend: <fn>: <reasons>')` and the
  refusal list says `[in <fn>: stubbed]`. The program compiles and runs,
  and the gap names itself where it is reached. The route's sixteen
  remaining refusals are inside two functions: `run_lsp` (channels,
  atomics, goroutines) and `dbg_run_session` (piped processes, stdin
  polling). `zebra_v lsp` panics with that sentence; `zebra_v --emit-zig`
  does not.
- **Signatures keyed by what is emitted.** A free function under its
  (module-prefixed) V name, a method under `.name` and `Owner.name`, a
  static under `owner_name`: a method and a free function of one name no
  longer collide into positional calls that lose `mut`.
- **The OS and stdlib surface the route uses**: sys (err, getenv,
  setenv, selfExe, run with a captured process, sleep, readLine,
  exec_inherit, writeStdout), Dir (createAll, list, deleteAll), File
  (isDir, rename, delete, copy, readLines), Random, Hash (sha256), the
  builtin **Arg** parser ported line for line as a runtime struct, and
  **Json**: Zebra's Json / JsonValue is V's `json2.Any` by value (as Zig's
  std.json.Value is), the statics and the reads through runtime helpers,
  and the put / append family as the statement rewrite `j = zjson_put(j,
  k, v)` (a sum type cannot be a mut parameter; the rewrite keeps the
  value semantics). Http is refused: V's net.http needs socket headers
  tcc does not ship on Windows, so the updater's fetch is a stub.
- **Three rendering bugs of my own**, each a V warning that `-prod`
  makes an error: the static-namespace resolver rendered a call's
  arguments before knowing the call was no static (every argument
  temporary bound twice); the binary emitter rendered both operands
  before deciding the expression was a chain (the chain rendered them
  again); the condition stripper counted parentheses inside rune
  literals. Rendering an expression binds temporaries, so rendering it
  twice is never harmless -- a rule now.
- **`_ = x` for a name nothing reads**, through the compiler's own
  AstWalk and a stricter walker of mine (V counts an assigned-only local
  as unused); a `_` binding is not bound; a module-level var is declared
  by type and set in `zglobals_init()` at main's start (MSVC refuses V's
  static initializer for a string global; this is the Zig backend's
  `_initModuleVars` shape).
- Also: `Arg.parse()` beside the AST's own `Arg` struct (a static access
  on a type that declares no such static goes to the builtin namespaces
  first); `near` / `far` / `pascal` / `huge` are macros in tcc's Windows
  headers; a for-in over an `orelse` expression binds the iterable first
  (V's C for it did not compile); `xs[i]` on a known list is `.at(i)`;
  `str.toInt()` is `.i64()` when the receiver is a string; the route's
  own `vLoadModule` no longer returns a nilable AND throws (V has no
  `!?T`).

**The witness.** `zebra_v.exe --emit-zig --output-dir D selfhost/main.zbr`
writes the whole compiler -- fourteen `.zig` files, **99,080 lines** --
**byte-identical** to what the Zig-built compiler writes. Every variant
below produces the same fourteen files.

**The cost**, measured on that emit (the compiler compiling itself to
Zig; three runs each, the middle one; peak = peak working set, read
through a Process handle refreshed each 10 ms -- a 300 MB control reads
303 MB; the first readings, without the refresh, were a tenth of the
truth):

| compiler | built by | wall | peak memory |
|---|---|---|---|
| zebra.exe, Debug | Zig | 8.5 s | 358 MB |
| zebra.exe, ReleaseFast | Zig | 1.15 s | 330 MB |
| zebra_v.exe, tcc, no collector | V | 4.8 s | 521 MB |
| zebra_v.exe, tcc, Boehm | V | 5.1 s | 179 MB |
| zebra_v.exe, zig cc -O3, no collector | V | 2.0 s | 517 MB |

What the table says: V's debug build (tcc compiles in 2.6 s) is twice
as fast as Zig's Debug and the optimized V build is 1.7x slower than
Zig's ReleaseFast; V without a collector holds 60 percent more memory
than Zig's arena (its strings and arrays allocate per value; nothing is
freed in either); **the Boehm collector costs 6 percent of the time and
takes back two thirds of the peak**. The collector is V's default and
the backend's explicit mode (`--gc` on the route; `-gc none` is what the
run line prints without it).

What did not make the table: the zig cc build with Boehm did not finish
the emit in 600 s of CPU (the collector under clang -O3 on Windows;
killed, unpinned); V's `-prod` picks MSVC on this host (installed, not
on PATH), compiles the compiler in 1m39 -- and the binary panics at a
slice bound during parsing that the tcc- and clang-built binaries
accept (`slice index out of range for int: 2674`), under -O2 and also
without optimization: an MSVC-specific difference in V's generated C,
unpinned; `zig cc` needs V's `-Wl,-stack=N` dropped and links without
`-flto` (long-double math symbols go missing with it) -- `vbin/zigcc.py`
is the wrapper.

Where each of the wrapper's adjustments belongs, traced on 2026-10-14
(Sean asked whether they were worth reporting; none is new). V keys a
C compiler's kind on its FILE NAME before it asks the binary --
`contains('gcc')` is checked before `--version` is read -- so
`zigcc.cmd` has been driven as GCC by both versions (a copy named
`zigclang.cmd` is clang to them, and `-showcc` shows the difference:
under 0.5.2 the gcc path adds `-flto -fno-strict-aliasing -std=c99`,
the clang path adds no `-flto` on Windows at all, an exclusion from
2022 (d4fc8601, vlang/v#13470: clang over binutils ld could not link
bitcode); master's rewritten driver adds `-flto` to both). The LTO
link loss is zig's own: ziglang/zig#31958 on Codeberg (2026-04-19,
Zig 0.16.0, open, the same symbol list, "does not occur if zigc
symbols are not weak"), reproduced here from a nine-line C file. Not
V's: V's Windows CI drives msys2's clang, which links through lld,
where LTO works; the host's LLVM clang 22 targets MSVC and builds
nothing for V in debug under either version, so no "clang on Windows"
claim could be witnessed here. The stack flag: master already emits
`-Wl,--stack=`, which zig cc accepts; 0.5.2's `-stack=` it refuses.
The mingw target spelling and the missing `-fwrapv` are in #30495,
the module cache's object in #30493. So the wrapper stays as it is,
and a zig release that closes #31958 retires its `-flto` line.

The clang V assumes, installed (Sean's pick, 2026-10-14): llvm-mingw
20261006 at `C:/Projects/llvm-mingw` (737 MB; clang 23.1.3 for
x86_64-w64-windows-gnu, lld inside; the zip kept beside it). Three
answers in a quarter of an hour. The nine-line LTO program links on
it, so the loss was zig's alone. V master passes `-flto` to it under
`-prod` and the hello program builds and runs in debug and `-prod`, so
master dropping the 2022 exclusion is no regression and that ticket is
dead. And V 0.5.2 fails the C stage under it in both modes -- its
generated C passes a `u32*` where the Windows SDK declares `LPDWORD`,
which clang 22 and later refuse (the LLVM installer's MSVC-target
clang 22 had said the same) -- fixed upstream on 2026-10-12 (75da3f80,
vlang/v#30255, after the release), and `-cflags
-Wno-incompatible-pointer-types` builds 0.5.2 under it meanwhile. So
the lanes gain a compiler V supports with no wrapper in the path
(`v_clang_lane.sh 052|master [prod]` on the same eleven programs and
controls), and the pin to 0.5.2 carries one more reason to move at
0.5.3.

The clang lanes (2026-10-14 evening): under 0.5.2 with llvm-mingw's
clang at `-prod`, ten of the eleven programs are IDENTICAL and the
demo is not -- it corrupts its heap between the designer's save and
the "play here" lay (a segfault, a negative allocation size or a list
that "cannot grow", a different one of the three on different runs of
the SAME binary, which no deterministic fault does); under master's
new backend the same program through the same clang is IDENTICAL,
eleven of eleven. What the evening established, each by an instrument
that proved it could see: the failure is clang 22 and 23 at `-O2` and
`-O3`, not `-O1`, not clang 21 (zig cc), not tcc, not MSVC; the loop
and SLP vectorisers off, or inlining off, or the machine scheduler off
(`-mllvm -enable-misched=false`) each make it pass; strict aliasing is
cleared (`-fno-strict-aliasing` changes the symptom, and an auto-init
bisection under it names the same variable); the undefined-behaviour
and address sanitizers are silent at every level (a planted shift and
a planted heap overflow each fired); the random generator alone is
identical at every level. LLVM's pass bisection (`-mllvm
-opt-bisect-limit`, 20 builds) names `machine-scheduler on main__main`
as the pass that turns it, and a diff of main's machine IR before and
after that pass shows no store reordered against a load and nothing
crossing a call -- the scheduler is correct, and what it changes is
register assignment, which only matters to a program reading what it
never wrote. Clang's `-ftrivial-auto-var-init=zero` with
`-stop-after=N` is monotonic and sharp at N = 827: the 40-byte return
slot of `strconv.atof64` (its success path declares `_result_f64 _t5`
bare and lets `_result_ok` fill it through a `_result*` cast; the
padding goes to the caller stale). But that variable is necessary,
not sufficient: zeroing it by hand (kept past the optimiser), on
every return path, building the result through its own type, or
marking atof64 noinline, each still fails, and the bisection over the
hand-zeroed C names the same N. Barriers inside main localise nothing
(every subset of thirteen statements fails, all of them pass: the
barriers perturb allocation function-wide). The honest end state: an
uninitialised read, stack-content dependent, somewhere in 0.5.2's
generated C or in a V 0.5.2 runtime path the demo exercises, that
clang 22's codegen exposes and no instrument on Windows can name (a
memory sanitizer would, on Linux). It does not touch master's C, and
the pin moves off 0.5.2 at the next release; until then the 0.5.2
clang lane reads ten of eleven and says why. The tools built for the
hunt live in the session scratchpad: `opt_bisect.py` (pass
bisection), `barrier_bisect.py` / `barrier_pair.py`,
`autoinit_bisect.py`, `replay_rsp.py` / `replay_variant.py` (a
response-file replay with extra flags or line edits),
`mir_memorder.py` (store/load reorderings per block between two MIR
dumps); each refuses to bisect when its controls do not read as
expected.

**What a V-built Zebra compiler is and is not.** It compiles Zebra to
Zig exactly as the Zig-built one does, so it can stand in for it
wherever `--emit-zig` is the job (the engine's regen, a `zebra build`
that only emits). It cannot build the Zig it emits (that needs Zig, as
before), it has no LSP and no debugger bridge, and no HTTP.

**A GUI program on the V target: the libui-ng section, a proof of concept
(2026-10-14; Sean: "the libui back-end probably needs a proof of
concept").** Zebra's Gui is immediate-mode over an MVU loop: each frame
the program's `view(g, model)` declares its widgets, `g.button(label,
msg)` sends a Msg, the loop runs `update` over what was sent. On the Zig
target `selfhost/gui_libui_ng_section.zig` (3,400 lines) puts that over
libui-ng's retained widgets. `selfhost/gui_libui_ng_section.v` (340
lines) is the same contract for V, appended to the emission by `zebra
--target v --gui-backend=libui_ng` (found beside the runtime, in the
repo or beside zebra.exe): `Gui` is a handle over heap state; a frame
runs after each event (`uiMainStep(1)`), and once more without waiting
when the frame sent a message, so the updated model is drawn at once;
the frame's widget list is diffed against the last in order -- the same
kinds and labels reuse their controls (a label's text updated in place),
any difference rebuilds the window's content; a message is the Msg
value's bytes (`memdup`, `sizeof(T)` in the generic `button[T]`) read
back as G by the generic run loop; a click's callback carries the node
holding the copy. The widgets (the second batch, the same evening):
text, separator, sameLine (an open horizontal row), button, send,
toggle (a checkbox), field (an entry), spinbox, slider (0..1000
underneath, mapped onto min..max), progressBar (0..1 as a percent),
every (a libui timer that sends while the view keeps declaring it),
and the containers beginForm / endForm (libui's uiForm, labels left and
controls right), beginHBox / endHBox, beginVBox / endVBox, beginPanel /
endPanel (a uiGroup); a control without a label of its own (field,
spinbox, slider, progress) gets one beside it, or its form row's. A
widget with a value takes the program's closure from the value to a
Msg, wrapped in the generic method into a closure that sends. The
rebuild keeps ONE root box as the window's child for the program's
life and detaches each top-level child with uiBoxDelete before
destroying it: libui refuses to destroy a control that still has a
parent, and the first rebuild (a toggle adding a form row) crashed on
exactly that. A call to any widget not listed is a V compile error
naming the method; tooltip is accepted and dropped, said once.
The third batch, the same night: tabs (a page is a box appended to a
uiTab; `tabSelected` reads the control, `selectTab` is applied at the
commit), combobox and radio (a Zebra list of choices -- the runtime's
boxed `&ZList[string]` -- a selection, a sender), menus (libui builds
the menubar BEFORE the window, so the window is now made at the first
commit, after the first frame's menu declarations, as the Zig section
does; later declarations are accepted and ignored, said in the
section), and the `vbox` / `hbox` handles with `begin` / `end`. Those
handles exist for Zebra's `using EXPR` block, which the emitter refused
until tonight: it now spells the Zig target's lowering -- a handle
bound, `begin()`, the body, `end()` -- with the end written after the
body, since V's `defer` is function-scoped (an early return inside the
block skips it; the Zig target's block-scoped defer does not). A
`with` block is its statements. `ZGUI_SCRIPT` drives the window
without a mouse, one action per frame after the first draw --
`click:<label>`, `toggle:<label>`, `set:<label>=<text>`,
`spin:<label>=<n>`, `slide:<label>=<x>`, `pick:<label>=<index>`,
`tab:<id>=<index>`, `menu:<label>`, `tick`, `quit`; an action acts on
the previous frame's widgets, so a row a toggle adds is there to act on
a frame later -- and `ZGUI_TRACE=1` prints each frame's widgets with
their values, which is how `tools/v_gui_check.sh` witnesses it:
`examples/counter.zbr` run with + + - Reset + must draw the counts
0 0 1 2 1 0; `examples/form_smoke.zbr` with a field set, the port spun,
TLS toggled, Advanced toggled on (its Timeout row added through the
rebuild), the timeout spun and Advanced toggled off again must draw
each change in place and the row's arrival and departure, nine frames;
and `examples/gui_tabs_smoke.zbr` (new: a menu, tabs, a combobox and a
radio under a `using g.vbox` block) with the menu item sent, the second
page picked, the radio picked, the first page again and the combobox
picked must draw each, seven frames.

The fourth batch: tables. `beginTable(id, cols)` / `tableSetupColumn` /
`tableNextRow` / `tableNextColumn` / `g.text` as the cell / `endTable`
fill a `ZGuiTable` kept by id across frames; its rows are a libui
model's (the handler's five function pointers sit first in the table
record, so a callback casts the handler pointer it is given back to the
table), the control is a uiTable over that model with a text column per
`tableSetupColumn`, made at the first commit and again after a rebuild
(the rebuild frees the destroyed tables' models: a model may hold no
table when freed); each frame's rows are told to libui row by row as
inserted, changed or deleted; `tableSelectedRow` reads the selection,
`tableActivatedRow` the last double-click, once. `hotkey`, `takeKey`
and `minSize` are accepted and not acted on, said once each. The
witness: `examples/table_strip_smoke.zbr` (a table fed every tick, a
tab strip, a window hotkey), the timer ticked twice, row 1
double-clicked, row 2 selected: three rows, the ticks, the activation
and the selection drawn, six frames.

The fifth batch needs the FORK checkout (`C:/Projects/zig-libui-ng/libui`,
Sean's libui-ng with trees, a toolbar, tooltips and the clipboard; the
plain `C:/Projects/libui-ng` has none of them, which the first grep of
its header said), built ReleaseFast the same way (12 minutes on a
saturated host). Trees: `beginTree(id, onSelect, onActivate, onExpand)`
takes the program's three closures; `treeNode` / `treeLeaf` and their
Icon forms declare this frame's nodes under a stack `treePop` pops;
`endTree` makes the node whose identity is the keys and their nesting,
so the same structure updates labels and expansion in place (the
fork's `uiTreeModelNodeChanged`, `uiTreeSetExpanded` against
`uiTreeExpanded`) and a changed one rebuilds; the fork's keyed model
handler sits first in the tree record, as the table's does; the three
callbacks deliver the node's key to the program's closures and the
model decides (the example's "Close all" folds every folder with no
click). The toolbar is a strip the window holds: declared every frame,
its items re-appended whenever the labels change, each item's enabled
state applied per frame, a click sending the item's Msg by its index.
A tooltip goes on the widget declared just before. `Gui.setClipboardText`
and `Gui.clipboardText` are the fork's two calls. `Gui.registerIcon`
runs before `Gui.run`, before libui is initialised, so the requests
queue and the images are made at init (one process-wide state, made by
the first call that needs it); an unregistered icon name is drawn
without and said once: the Zig section's built-in set is not here.
Three more witnesses: `examples/tree_smoke.zbr` (a node selected,
another activated, a folder expanded through the model, all closed),
`examples/toolbar_smoke.zbr` (Build, Run with Stop enabled only while
running, Stop, the Clear item appearing and going) and
`examples/tooltip_clipboard_smoke.zbr` (the field set, copied, pasted
back through the system clipboard -- which that case overwrites -- and
a node of an iconed tree picked). Two runtime gaps they found: a Zebra
list's `append` (the emitter maps methods by name; the runtime had only
`add`) and a StringBuilder's `appendChar`, both added to `zebra_rt.v`.

The sixth batch: the dialogs -- `openFile` / `saveFile` / `openFolder`
return a Zebra option, `msgBox` / `msgBoxError` show -- are libui's
modal ones on a real run and, scripted, the next `dialog:<path>` answer
(an empty one is a cancel) with a `dialogs(...)` word in the trace, so
`examples/file_dialog_smoke.zbr` runs headless: an open answered, a
save cancelled with the status left alone, a folder answered, an alert
and an error recorded; the editable combobox (`comboboxEditable`, a
list of choices and a text, the `set` verb;
`examples/combobox_editable_smoke.zbr`); and the built-in icon set,
the Zig section's four painters (folder, file, dot, warn) ported pixel
for pixel and premultiplied as libui wants -- which `registerIcon`'s
bytes now are too, a step the fifth batch had skipped (the warn
triangle's amber is this section's own: the Zig line was cut in the
read). Nine witnesses now.

The seventh batch completes the table: `tableSetupCheckColumn`,
`tableSetupEditColumn` and `tableSetupButtonColumn` each take the
program's closure for the row's toggle (row and a bool), edit (row and
the new text) or click (the row), a check cell is `tableCheck` (1 or 0
as the cell's text, which the model reports as libui's integer value),
the columns are appended by kind with libui's always-editable
sentinel, and the model's SetCellValue is dispatched by column to the
closure; the model is not changed there -- the message goes to update
and the next frame's rows carry the answer, or do not, as
`examples/table_edit_smoke.zbr` shows by refusing an empty name. The
trace now prints a table's rows as words. Two more witnesses:
`examples/table_check_smoke.zbr` (row 1 checked through the closure,
then None and All) and `table_edit_smoke.zbr` (a rename, the refused
empty rename, a row removed by its button). Eleven.

The eighth batch: drawing. `area(id, w, h, draw, onClick)` and
`canvas(id, w, h, draw, onMouse, onKey)` keep a record by id with
libui's five-pointer area handler first (the pointer-first trick a
fourth time); the draw closure runs inside libui's draw callback with
the paint context and the area's size held in the state, and the six
primitives -- `line`, `rect`, `fillRect`, `circle`, `fillCircle`,
`drawText` -- are paths with a solid brush and round strokes (a
0xRRGGBB colour), text through an attributed string and the control
font, nothing outside a draw; mouse and key events reach the program's
closures as the Zig section numbers them (press, release, move, enter,
leave; the hotkey vocabulary for keys). A V closure's captures cannot
be compared, so a redraw is queued every frame where the Zig section
redraws only when the captures changed. The trace names what the last
draw painted, and libui paints asynchronously, so those words lag the
model by one frame, which the witness expects. Two more witnesses:
`examples/area_smoke.zbr` (the board painted, a cell clicked and
filled, cleared) and `examples/canvas_smoke.zbr` (a press near the dot,
a drag moving it, a release, an enter, a key). Thirteen.

The ninth batch: the CodeEditor, over the fork's Scintilla shim
(`zig-libui-ng/libui_scintilla` with the vendored Scintilla 5, built
ReleaseFast as `sci_native` -- which the fork's build did not install
until a local `installArtifact` line, said in that checkout; six
minutes of C++). The emission types a `CodeEditor?` as a value and
calls methods on the unwrapped copy, so `CodeEditor` is a handle over
a heap record, as `Gui` is: `CodeEditor.forZebra()` / `forFile` /
`forLanguage` / `new` make one; `setText` / `getText` (the text lives
in the Scintilla control while the window holds it and is pulled back
into the record before a rebuild destroys the control); `setReadOnly`;
the cursor's line and column and `setCursorPosition`; the three
recorded events `takeModified` / `takeCharAdded` / `takeMarginClick`
through the shim's notification hook (insert or delete, the character,
the margin's line), and `hotkey` / `takeKey` through its key hook
(chords as the Zig section packs them, mods above the key); `render`
places it as a node keyed by the record's address, stretchy; the
configuration is the Zig section's (UTF-8, Consolas 11, One Dark, a
line-number margin, the caret line, a four-space tab). No syntax
styling in this batch (the tenth, below, is it);
`setErrorMarkers` is accepted and said. Script verbs `edtype` (an edit
appended through Scintilla, so the modified event fires), `edkey`,
`edmargin`. The witness: `examples/editor_events_smoke.zbr` -- an edit,
a Ctrl+S, a margin click, each taken by a tick and counted.

The tenth batch: syntax styling, the Zig section's tokenizer ported.
A language is data (`ZCeLangSpec`: the keyword list, the line and
block comment forms, whether `#` at a line's start is a preprocessor
line, whether `'x'` is a char literal, Zig's `\\` multiline-string
lines and `@builtin` calls, whether a capitalised identifier is a
type) and one tokenizer reads it, one style byte per source byte, the
specs for zebra, c, zig and plain text; the eight style slots and
their One Dark colours are the Zig section's (0xBBGGRR, the easy
mistake). The bytes go to the control as `SCI_SETSTYLINGEX` after a
`setText` and when the control is made over the record's text; an
edit moves Scintilla's end-styled watermark back to where it
happened, and the commit's in-place pass asks for it each frame
(`SCI_GETENDSTYLED` short of the length: pull the live text, restyle;
two messages when nothing changed, as the Zig section polls, since
libui routes no notification for it). `forC` / `forZig` join the
constructors and `forFile` picks by the spec table's extensions
(`.hpp` is c, `.zon` is zig, an unknown one is text). The trace's
editor entry carries a tally of the style bytes read back from the
control with `SCI_GETSTYLEAT` (the first 4096), which is the
instrument: it reads what the control shows, not what the tokenizer
said. The witness counts by hand from the texts and the control agrees
to the byte: the editor example's `def` and `print` as keywords (8),
`main` as a function (4), the string (8), and an appended `def`
restyled by the next frame (11); the styler smoke's three controls
from the IDE plan -- C's `#` inside a string as STRING and `#include`
as PREPROC (a comment count of 33, which a `#` read as a comment would
make 48), Zig's two `\\` lines and `@import` as STRING and FUNC,
Zebra's `${}` inside its STRING with `#` a comment. Two reds seen:
with the restyle gone the edit stays at 8; with the first styling gone
every tally reads 0. Sixteen cases.

The eleventh batch: the three Gui stubs become real, and the hatch.
`g.hotkey(vk, mods)` registers a window chord ((mods << 16) | vk, Ctrl
1 / Shift 2 / Alt 4, the fork's uiWindowOnKey bits) and the window's
key hook, registered when the window is made, consumes a registered
chord before the focused control sees it and queues it for
`g.takeKey()` in order; `g.minSize(id, w, h)` finds the container the
view keyed `id` in the last frame's nodes and sets its minimum through
`uiControlSetMinSize` (the first frame's call finds nothing, as the Zig
section's), and the trace says what was applied on the container's
entry (`begin_vbox(##side min 240x0)`): what the backend did, not the
control's own minimum read back, which the section cannot see without
declaring uiControl's layout. The CodeEditor's hatch `sci(msg, w, l)`
/ `sciStr(msg, w, text)` sends any Scintilla message to the control, 0
before it exists (the Zig section's rule; a hatch call in init is
dropped on both backends). Script verb `winkey:<vk>,<mods>` is a
key-down to the window's hook; like `edkey`, it calls the hook, so the
registration line (uiWindowOnKey to the callback) is the one link no
script exercises -- a real keyboard would. Two more witnesses:
`examples/sci_hatch_smoke.zbr` (0 before the control; SETTEXT through
sciStr and GETLENGTH back, 14; the set text restyled as a C comment by
the commit's dirty check, cm=13 read from the control) and the
compiler's own `examples/table_strip_smoke.zbr` (Ctrl+S taken and sent,
saved 1 a frame later; the side pane's minimum said). Two reds by hand:
the chord not queued, saved stays 0; sciStr sending nothing, len 0 and
one line. Eighteen cases.

Two general things the table example found, neither about tables. A
literal message (`g.every(100, 1)` with `Msg = int`) is a V `int` where
the program's Msg is `i64`: four bytes copied, eight read back, the
upper four whatever the heap held -- the ticks arrived on one run and
not the next. The queue carries each copy's size now and the run loop
zero-extends a smaller copy into the Msg, saying so once; a sum-type
Msg is never smaller. And a class field's declared default (`var
activated: int = -1`) was dropped by the emitter for a class without an
init: the constructor returned `&Model{}`, zeroed. A field's default is
now V's own field default in the struct declaration (`activated i64 =
-1`), at the class site and the struct site alike; the pipeline's
fifteen witnesses unchanged.

What the first run taught, each a line in the section or the build:
V reserves `init` and `cleanup` as module hooks (`fn init() Counter` is
"cannot have a return type"), so `vSafe` suffixes them; a generic
read-back of a sum type from copied bytes must bind the pointer first
(`*(&G(p))` in one expression is emitted as void); a variant value
`Msg_inc{}` passed into a generic parameter keeps the variant's own type
and the loop read garbage as Msg, so the emitter now spells a variant
value as the sum type `Msg(Msg_inc{})` (a no-op everywhere a Msg was
already wanted; the pipeline's fifteen witnesses unchanged); V reads a
`gdi32` link flag as "a GUI app" and then emits a console attach with
`freopen_s`, which mingw's headers do not declare at C99
(`-subsystem console`); the `ui.lib` zig builds in Debug carries 284
calls into the undefined-behaviour sanitizer's runtime, so the section
links `zig-out-fast/lib` (`zig build -Doptimize=ReleaseFast -p
zig-out-fast` in libui-ng, 3m50); libui-ng's Windows backend has C++ in
it (`-lc++`), and `-static` keeps llvm-mingw's runtime out of the exe's
DLL list (without it: libunwind.dll not found); and the static build
needs the Common-Controls v6 manifest beside the exe, the Zig scaffold's
text. The compiler is the mingw clang (llvm-mingw): tcc stops before
the archive, unable to find V's own `dbghelp` library once `-static` is
among the flags (not pursued), and MSVC was not tried.

What it is not: error markers in the editor (a stub on every backend,
the Zig section's too), the tui backend on V (forgone, Sean 2026-10-15:
zigzag has not moved to Zig 0.17 yet, so the Zig one is in the air
too), a manifest the compiler embeds, a `--gui-backend` build the
compiler runs (it says the build line). The hand on a real mouse came
on 2026-10-15: Sean ran three of the witness programs by hand and the
keyboard and the mouse worked, which closes the one link no script
exercises (the hooks' registration with libui). None of the rest was in
the question, which was whether a Zebra GUI program can reach a native
window through V at all: it can, and the diff-over-retained shape is
the same one the Zig section uses.

**A V 0.5.2 generic miscompile, found by the pipeline (2026-10-15).**
Adding one line to the runtime -- `zlist_of[string](out)` in a new
`zdir_walk`, with `out` a local `[]string` -- turned three pipeline
witnesses red: every string-list literal in every program
(`['x', 'y']`) read back as twenty-byte blobs. The emitted V text of
the programs was unchanged (an A/B against the HEAD emitter through a
stash, build, emit, pop), the C compiler was not it (tcc and clang
alike), and the generated C of `main` was identical between the good
and the bad build; what differed was the body V generated for the
instantiation `zlist_of_T_string`: it converted the items to
`json2.Any` (`string_to_sumtype_x__json2__Any` per element) before
storing them, the body of the sum-type instantiation under the string
instantiation's name. The minimal repro is twelve lines: a generic
`of[T](items []T) &Box[T]`, a sum type `Any = int | string`, and in one
function `of[string](['x', 'y'])` followed by `of[Any]([]Any{})`: the
string list prints garbage. The sum-type call first, or in a function
declared earlier, is fine; V master (d67ee55) is fine either way, so
there is no ticket to file, only the 0.5.2 rule for the runtime: no
`zlist_of[string]` call site may come before the first
`zlist_of[json2.Any]` one in the file, and `zdir_walk` builds its list
directly, as `zfile_list_dir` does. The mechanism, found later that
night with an instrumented V build (wiki
`fable/fieldnotes_v-heap-init-stale-expected_2026-10-15`): the checker
re-checks a generic body once per concrete type set and writes each
pass's `expected_type` onto the one shared struct-init node, last pass
wins; cgen's plain `S{}` path recomputes it per instantiation, but the
heap `&S{}` path (`gen/c/struct.v:592-633`) keeps it whenever it is
nonzero, so the string instantiation inherits the sum type's and the
array-to-sum-type promotion fires. Every runtime container is a heap
init, which is why one call site reached every program; the condition
is a `&Generic[T]{}` init in a generic function instantiated with a
sum type and one of its variants, the variant's instantiation checked
first. The pipeline's fifteen witnesses
are the detector; v_poc2's names line was the one that spoke. One
lesson about the A/B: the emitter reads `selfhost/zebra_rt.v` before
the copy beside the exe, so a first A/B that swapped the copy beside
the exe compared the new runtime with itself and said "not the
runtime" -- an instrument that cannot see, reporting the reassuring
answer, until the emission diff showed the runtime block as the only
difference.

**zebra-ide through the V target (2026-10-15).** The largest real GUI
program there is -- Sean's IDE, 5,383 lines of Zebra over libui-ng and
Scintilla, talking to `zebra lsp` and `zebra debug` over pipes -- was
the next question, since the TUI was forgone and the mouse was proven.
Its first emission refused seventeen constructs of three kinds: the
optional chain `?.` (thirteen sites, all JSON reads), `sys.spawnPiped`
/ `spawnPipedIn`, and `Dir.walk`; and five of its headless tests passed
on V as they were (two of them, naming Gui, with the libui section).
One of the others, `icons_test`, is a `zebra test` file -- test_ defs,
no main -- and the V target built it and ran NOTHING, exit 0: a green
from a runner that never ran. A root without main whose defs are tests
now gets a main that runs them in order and reports as the Zig runner
does (`3 passed, 0 failed` on stderr), saying first that a failing
assert ends the run (a panic on V, where the Zig runner counts it and
goes on). The chain is V's if-guard, bound on lines before its
statement -- the base first, then the guarded read -- because V's guard
takes a call or a name and `or { }` follows a call or a name, neither
an if-expression; the read's temporary is typed as the base's inner
type so a JSON read on it is spelled as one, and the chain's own type
is an arm of `vTypeOf`, so a chain used as another chain's base is
typed too; the else arm is a bare `none` when the read is a plain
value (V infers the option, and a cast there is refused) and the read's
own option type spelled when the read is an option already (V did not
unify a bare `none` with `?&ZList[...]`). `sys.spawnPiped` is
`ZSysProcess` over V's `os.Process` with redirected stdio: `write` is
`stdin_write`, `readAvailable` drains `stdout_read` (which peeks first,
so it never blocks) a few blocks per call, `isRunning` polls
`is_alive` and reaps the code; `closeStdin` is the one method
`os.Process` cannot do (no per-pipe close): accepted and said once per
process, the child ended by the caller's kill, as the IDE's transport
does after a short wait. And a program that is not there: V's
`os.Process` on Windows prints "failed CreateProcess" and EXITS the
whole program, which is what the IDE did at its first `zebra lsp`
without a zebra on PATH; the runtime resolves the program first (a bare
name through PATH, a path by its existence) and hands back a dead
handle, Zebra's contract. `Dir.walk` is `os.walk_ext` with the slashes
turned (the Zig shape), built directly rather than through `zlist_of`
-- the generic miscompile above. Then the IDE itself: its own
`sci.zbr` declares `SCI_SETCODEPAGE` and the rest, which snake-case to
the section's own constant names, so the section's are `zsci_*` /
`zscn_*` now; `Timer.start()` is `ZTimer` (`time.since`, microseconds
and milliseconds); a struct's container field without an initializer
is the empty container (V wants every reference field initialized;
Zebra's zero value is the empty list); and `xs[i] = v` on a container
was spelled as the read (`.at(i) = v`), which V refuses as an lvalue,
and is `set()` now, a compound assignment reading through `at()`.
`tools/v_ide_check.sh` is the witness: the IDE's seven headless tests
pass through V exactly as the IDE's own gate expects them (sci,
buffers, textops, ignore, keys, coverage's four, icons' three), the
IDE builds (3.9 MB), and runs scripted from its own directory: without
a compiler its status line says it could not start `zebra lsp` and it
goes on; with `ZEBRA_COMPILER` naming the Zig-built compiler, the
status line reaches "zebra lsp" by the fourth tick -- the LSP's
initialize handshake over V's pipes. The next rung came the same night:
the tests that spawn the compiler -- gates_test, tests_test, tools_test,
lsp_client_test and rename_workspace_test (the multi-file rename loop
end to end) -- pass through V too, with ZEBRA_COMPILER naming the
Zig-built compiler, after three more findings: a finished child read as
exit -1 (V's `is_alive` only looks; `wait` fills the code, so the
runtime waits once the child is seen gone), `Dir.create` (the Zig
backend's createDirPath), and a triple-quoted Zebra string emitted with
its `"""` delimiters kept (tools_test's manifest began with three
quotes and would not parse; a doc string is now the Zig backend's
content, the delimiters and the newline after the opening one off, and
a raw string's backslashes are literal). Twelve of the IDE's gate
steps run on V; the three that cannot are model_test (the tui backend,
forgone), dap_client_test (lldb-dap, which the IDE's own gate skips
here too) and cross_lsp_test (clangd and zls). Not seen: the IDE with a
hand on it through V (the window opens and paints; typing, squiggles
and the debugger are a session with Sean).

**The engine's headless tests as the ladder (2026-10-15).** After the
IDE, the largest set of real programs there is: `tools/v_engine_check.py`
takes every test root `build.zig` names (through the engine's own
`tools/affected_tests.py`), keeps the 95 whose root is a Zebra source <!-- doc-lint-ok: the GameEngine's own tool (C:/Projects/GameEngine/tools), not this repo's -->
(the other 255 are Zig-rooted host tests, counted, never guessed), emits
each from the engine root with `--module-path zbra`, moves the `.v` out of
the engine tree at once, builds it with V, runs it from the engine root
and diffs its stdout against the Zig-built test's (`zig build
run-<name>`, or the executable the last suite left in the cache when
there is no step), measured durations normalised, refusals and V errors
ranked by the roots they touch. Five rungs in an afternoon: 70, 85 (a
false 80 between, from a patch the regen had refused), 88, 89, then
**92 of 95 identical**, the pipeline 15/15, the GUI witness 18/18 and
the IDE check green at each. What the rungs found, in the order the
counts chose:

- **An evaluation-order bug in the emitter.** A temporary bound for a
  mutating call on a call's result (`tracks.get("swing")!.isPlaying()`)
  was hoisted before the whole statement -- ahead of the earlier terms'
  side effects and outside the `and` / `or` short-circuit. character_test
  read the track before `play("lunge")` made it; net_mirror_test fetched
  the player before the pump rebuilt it; both looked like runtime
  divergences and were one emitter fault. An `and` / `or` chain whose
  later term hoists lines is now a bound boolean updated inside an `if`
  with those lines inside it (`chainStr`); the same hazard in other
  expression shapes is noted, not closed. The instrument that found the
  unwrap: number every `zunwrap` in the emitted main (`zunwrap_at(N,
  ...)`) and print the site -- V's own backtrace stops at the helper.
- **A flat local list.** A loop variable, a for-num counter and an `if x
  as y` binding stayed in the emitter's local list past their block, so
  a later `capture var r = rec` in the same function read as a
  re-declaration and was emitted as an assignment (minigames_test: `for
  r in tremor.ranges` then the capture; the mutable-element loop added
  its variable twice). Block-scoped names leave the list at their
  block's end (`popLocal`).
- **V 0.5.2's json2 keeps the escape sequences inside object keys** (a
  key `Iron \"Spear\"` reads back with its backslashes and encodes
  doubled); master is fine. The runtime unescapes keys after a decode.
- **The engine's own test tool.** `tools/affected_tests.py` mapped <!-- doc-lint-ok: the GameEngine's own tool (C:/Projects/GameEngine/tools), not this repo's -->
  `.root_module = tmod` to the LAST definition of a module variable
  `build.zig` reuses four times, so datastore_test's root read as
  voting_test's (the F42 class): the nearest preceding definition now,
  GameEngine 10b9f61.
- The smaller ones: an enum member typed (an optional-vs-enum compare
  through `zopt_eq`); a local named like a builtin namespace (`sys`) is
  the local; `for ... if` emits a `continue` at the body's head in every
  loop form (the list form was missed on the first pass: a filter a loop
  silently drops is worse than a refusal, and the second pass asserts no
  body is left unfiltered); the chained JSON index `j["a"]["b"]?`
  propagates the inner result and is typed; `f() catch nil` is the option
  declared by its type and set inside a guard on lines before the
  statement (V takes no result type as a generic argument, and its C
  stage miscompiles an if-expression over a result guard with a `none`
  arm); a throwing call as a statement propagates; Math.exp / Math.log,
  Dir.delete; Tcp refused by name; a def whose snake name is a class's
  constructor name is suffixed; two module-level vars that snake-case
  alike are numbered; a raw string takes the escape path (the lexer
  keeps its text pre-escaped for the Zig literal; spelled byte for byte
  it doubled every backslash, and tuon_story's 80-column rows read 11
  per 9).

The three that stay: net_figures_test prints a HashMap's entries in
iteration order (Zig's unordered, V's insertion-ordered; Zebra does not
specify one), tween_create_test wants a thread's Atomic and a call on a
call's result, and the devtools inspector wants a TCP client the runtime
does not have. Two lessons of the afternoon about the tooling: a Bash
heredoc turns `\t` into a tab (twice, through the quoted form too), so
a patch that carries an escape goes through a file the shell never
reads; and a pipeline whose regen refuses leaves the previous compiler
in place, so a ladder run after it measures the wrong build unless the
refusal is read first.

**The fixed point (2026-10-13).** `zebra_v --target v selfhost/main.zbr`
is the V backend emitting itself. Generation 0 is the Zig-built
compiler's emission of the backend's own source (61,627 lines of V);
generation 1 is a V-built compiler's emission of the same source;
generation 2 is the compiler built from generation 1 emitting it again;
generation 3 the compiler built from generation 2. **Generations 0, 2
and 3 are one file** (sha256 705ff021...). Generation 1 differed from 0
in two lines because the binary that wrote it predated the last emitter
change (the globals' shape), and its successor carried the change: the
difference was the source's, not the host's. The compiler built from
generation 2 emits the whole compiler to Zig byte-identical to the
Zig-built one, as its predecessors did. So: a Zebra compiler whose host
language is V, built by a Zebra compiler whose host language is V,
reproduces itself and reproduces the Zig-hosted compiler's output.
`C:/Projects/v-dist/fixed/` keeps the generations; `vbin/
zebra_v_none_debug.exe` is generation 2.

Re-run on 2026-10-15 after the week's emitter changes (the chain, doc
and raw strings, index assignment, the test runner, field defaults,
Timer, the GUI section): generations 0 to 3 are one file again (sha256
09c984e4..., 63,227 lines, fifteen refusals in main.zbr where there
were sixteen), each V build of the compiler four seconds under tcc, and
generation 2's `--emit-zig` of the whole compiler is 14/14 identical to
the Zig-built compiler's. `C:/Projects/v-dist/fixed2/` keeps them; the
script is the scratchpad's `fixed_point.sh` (emit, build, emit, three
times, then the Zig comparison, refusing at the first step that fails).

## The engine's first modules (2026-10-13)

Sean's stress test: the game engine (`C:\Projects\GameEngine`, `zbra/`
and `game/mm/`) through the backend, from the engine root with
`--module-path zbra`. Measured as they stood: `zbra/signal` (60 lines)
clean; `zbra/instance` (973) and `zbra/tween` (445) wanting interfaces
and a type alias; `game/mm/health` (362 lines, which folds in **21
modules**: the workspace, the instance tree, the GUI scene loader, the
player handler, the shop, the datastore) wanting untyped list literals,
the stream type and much that only showed once the first were in.
Twenty-eight rounds:

1. **Interfaces.** `interface I` is V's interface with every method under
   `mut:` (a class's methods are all `mut self`); `implements` emits
   nothing (V's interfaces are structural); an interface-typed parameter
   is `mut`; an interface's methods have signatures and return types like
   a class's. A simple `type Alias = Base` resolves to its base wherever
   named (V's `type` makes a distinct type). An untyped list literal takes
   its first element's type.
2. A name that is a V import (`time`) or a V type (`map`, `string`,
   `int`) is suffixed. **Capture closures** declare their captures at the
   capture point (`capture var rc: RoundControl = this` is `mut rc :=
   self` before the `fn [mut rc]`), as is when the value is the name
   itself, assigned when a capture already declared the name. A method's
   return type is keyed by its owner too and read by the receiver's type.
   **A signature that cannot fit the call** (more arguments than
   parameters, a named one it lacks, a missing one without a default)
   was matched by name to another declaration's: Zebra's checker already
   accepted the real callee, so the arguments go by position. `SqliteDb`
   and `SqliteRow` are runtime types whose every call panics (no sqlite
   on this backend); `Random.new(seed)` is a seeded xoshiro256++ whose
   sequence is **not** the Zig backend's (a known divergence). **Zebra's
   own narrowing**: after `if x == nil: return` or inside `if x != nil`,
   Zebra reads a nilable local -- and a field of `this` -- as its inner
   type; the emitter tracks the narrowed names per block and spells a
   narrowed read as `zunwrap(?T(x))`, right in every position because V
   never narrows here (the nil check is `zis_none`); an assignment
   un-narrows; a re-check reads the raw name.
3. **A module-level var declared in more than one module** is
   `<module>_<name>` wherever declared or read: three modules' `_registry`
   collided in V's one namespace and the reads crossed (a player handler
   typed as a menu button). A call through a function-typed value (`h(x)`
   with `h` of a `sig` type) takes the sig's signature.
4. **A lambda's nested emitter inherits the whole context** -- it
   inherited nine tables of forty; inside a closure a call's result had
   no type, so a mutating call on it was not bound and an `as` over it
   not `mut`.
5. **A user type's own method comes before the stdlib table.** The table
   (contains, add, get, set, keys, ...) was consulted by name first and
   took a `TagList.contains(inst)` for a string's. The expression-
   statement path that bound a call-result receiver itself went: the
   method emitter does it, with the type.
6. `x.toString()` on a user type is V's `str()`; `opt == value` (Zebra
   compares a nilable with a value) is `zopt_eq`.
7. **A def that is nilable AND throws** (`def f(): T? throws`; V has no
   `!?T`) returns `!ZOpt[T]`, a two-field wrapper in the runtime: `return
   nil` is `ZOpt[T]{}`, `return x` wraps, and `f()?` at a call is
   `zopt_of(f()!)`, V's option again; the type table keeps `!?T`.
8. **Zebra's Json idioms**: `p[key]?` and `arr[0]?` are subscripts on a
   Json value (helpers returning V's result); a Json value converts by
   the type of the local, parameter, field or cast that receives it
   (`var sx: float = arr[0]?` is `.f64()`, a str `zjson_str`, a
   `List(JsonValue)` `zjson_list`), so the signature table now carries
   the parameters' types; a for-in over a Json value iterates its array;
   literals have types.
9. Three faults of my own found on the way: the return-type pass
   recorded a throwing def's type without its `!`, so no `?`-call was ever
   typed as one; a bare call to a method of the enclosing type lost its
   return type when free functions were re-keyed; the definitions pass
   ran after the return-type pass it feeds.
10. **Two sigs of one shape are one V name** (vlang/v#30282). The health
    test's V check was clean and its C stage failed on `undefined symbol
    '..._add_T_anon_fn_'`: V instantiates a generic struct's methods
    **once per resolved type** and calls them under each alias, so with
    `sig VoidCallback()`, `sig JoinHandler()` and `sig CleanupFn()` all
    `fn ()`, the second and third aliases' `ZList.add` -- and `get`,
    `count`, every method -- were declared and never generated. Ten
    probes pinned it to seventeen lines: a cast at the call site and a
    named function in place of the lambda fail the same way; two
    aliases of different shapes, of `int` or of one struct work, and a
    direct `<<` works. The emitter keys every sig by its V shape (the
    parameter types with their `mut`, the return) and spells a sig
    whose shape an earlier sig owns by the owner wherever it is named;
    its own declaration is a comment naming the spelling and the
    ticket. The cost is nominal: two Zebra sigs of one shape were
    distinct types on the Zig backend and are one here, which no Zebra
    program can tell apart without overloading, which Zebra has not.
11. **A keyed try is the member's.** With the C stage through, the V
    binary ran the health test to "all ok" with the harness's two death
    lines and 2 Health components to the harness's 19: a Json value's
    keyed try (`n.tryList("tags")`, `p.tryStr("name")`, `v.tryFloat("x")`)
    was spelled as the bare `zjson_try_X(v)` with its key dropped, so
    the GUI scene loader asked each node whether it was itself a list
    and registered no tag, and the export's seventeen tagged instances
    never reached the Framework. The Zig backend has two families
    (`_json_self_X(v)`, `_json_try_X(v, key)`); the V runtime now has
    `zjson_tryk_X(j, k)` beside the bare six, chosen by the argument
    count. The count in the test's last line is why this was seen at
    all: "all ok" alone would have passed it.
12. **The second batch** (tags, guiscene, guitree, player_handler,
    round): tags and guiscene identical at once; guitree and round
    wanted `.sort(def(a, b): bool = ...)` and `.sortBy(def(a): K =
    ...)` with closures -- the runtime's stable insertion sorts
    (`zlist_sort_with`, `zlist_sort_by_i64 / _f64 / _str` by the
    lambda's return type; the Zig backend's `std.mem.sort` is stable,
    so ties keep their order on both); round wanted a list literal to
    have a type (its declared element type, else its first element's),
    so `for p in [p1, p2, p3]` over class references takes the mutable
    index loop (V: "`p` is immutable"); and player_handler DIVERGED, as
    the previous report's least-confident item said it might: json2
    parses every number as f64 and `zjson_try_int` returned the
    truncation, so the scene loader's `attrText` spelled a
    SpeedReduction of 1.6 as "1" and Iron Armor walked at 0.99 against
    the harness's 0.984. The Zig backend's `_json_as_int` is null for a
    float with a fraction; the V runtime's is now the same. All five
    identical after: 1, 1, 1, 6 and 1 lines.
13. **A local named like any module's global is renamed.** The health
    test's `-prod` build failed in V's checker with "duplicate of a
    const name `step`": TweenClock.update's local `step` against
    diffusable's `const step = 0.1`. Zebra scopes a module's globals to
    the module; V's one file has one namespace, and the shadowing is a
    WARNING that `-prod` refuses as an error (the debug build carried
    it silently). Isolated by flag (`-prod` alone, not `-skip-unused`),
    by a rename (the one local clears it) and by a 60-line ddmin (the
    const at its end): not a V bug. The emitter collects every emitted
    global name after its other passes and renames a local of that
    name `step_v`, as a local named like a function already was. Every
    engine emission now passes `-prod -check` clean, and the health
    test builds under `zig cc -O3`.
14. **An assert is never V's assert.** The first thing the `-prod`
    binary did was lie: one line, "all ok (20 Health components)",
    against the harness's three lines and nineteen. V's `-prod` drops
    `assert` statements, condition and all, and the engine's tests put
    the act inside the assert (`assert mh.damage(hit(50.0, c)) ==
    "Dead"`), so no damage was dealt, no death printed, one component
    never removed. An MSVC `-prod` build showed the same, so not the C
    compiler. A Zebra assert is evaluated in every build (the Zig
    backend panics `assert failed at f.zbr:12: msg`); the emitter now
    spells it `if !(cond) { panic('assert failed at <file>:<line>: '
    + msg) }`, the condition rendered once. Both `-prod` binaries print
    the harness's lines now. The Zebra session confirms this is the
    language's own contract, gated on the Zig backend: contract mode
    asserts that an `assert` survives `--turbo` and `--release` ("a
    check the author wrote to RUN"), so the two backends mean the same
    thing by the word. The lesson the round leaves: a build that
    succeeds is not a witness -- round 13's `-prod` build "worked" too --
    only a run diffed against the control is, and a test whose acts
    live inside its asserts is one a build flag can hollow out.

**The demo, rounds 20 to 28.** `game/mm/demo_test` builds the whole
monster mayhem demo as the host does and steps the autoplay's first two
minutes: 19,000 lines of V, 168 lines of output, the vote, the map, the
spawns, the figures, the creators, the fort, the night, the round's end
and the next vote. It went from "cannot register struct TweenInfo" to
byte-identical in nine rounds, each one V error or one wrong line
deeper, every existing witness identical throughout:

15. **Two modules' same-named types are renamed in the source.** V has
    one namespace per file and the demo's module set declares nine
    type names twice (gui's TweenInfo struct against tween's class, two
    TweenServices, the easing enums, Weld, Seen, NotifyLog, CameraMode,
    MessageHandler). The emitter has forty type-name sites and the
    front end no generic walker, so the route renames `<Stem>_<Name>`
    in each module's SOURCE TEXT before parsing it again, by the
    lexer's `id` and `open_call` tokens (a name followed by `(` is its
    own kind), in the declaring module and in every `use ... exposing`
    that names it -- Zebra's own resolution -- and the parser, the
    resolver and the emitter never meet the collision.
16. **Scopes, captures, tuples.** A statement list restores the local
    names and renames it declared (a capture declared in one loop body
    was "already declared" in the next); a capture of a renamed local
    takes the local's V name; a constructor call has a type, so a list
    literal of them is typed; tuples are the runtime's `ZTuple2 /
    ZTuple3` (V: a generic parameter is exactly one capital letter and
    `C` is reserved), the literal V infers, `t.0` is `t.f0` -- the
    engine's four stubs were that one tuple counted at three sites.
17. **A name in scope wins over a module of its name** (the engine's
    modules are common nouns: tween, character, health, door), else
    `tween.step(dt)` was a bare call; Zebra's `else if` is V's flat
    `else if` when its condition renders without a temporary (a probe
    render in a cloned context decides; the autoplay's seventy nested
    elses passed V's depth of forty); `str.bytes()` is a List(byte); a
    constructor's bare `return` is `return self`; a narrowed read is
    bound before a mutating call and reads as its inner type; a free
    function or a global resolves by the `use ... exposing` that names
    it, not the use lines' order (build_tools got math's snapToGrid
    for building's); DateTime is a builtin namespace; `x != nil` is
    parenthesized as an operand; a unary or binary expression has a
    type (`var best = -1` is i64, not V's int).
18. **A seeded Random samples as the Zig backend does.** The vote's
    winner differed: the generator was Zig's (xoshiro256++ by
    SplitMix64) but the sampling was not. Zig's `intRangeAtMost` is
    `lo +% uintAtMost(hi -% lo)`, `uintAtMost` is `uintLessThan(n + 1)`
    (Lemire's multiply-shift with rejection, a draw consumed even for
    lo == hi), `float(f64)` takes a draw's leading zeros as the
    exponent; ported bit for bit (four 32-bit products for the 128-bit
    multiply, checked against Python). A `Random.new(42)` probe prints
    the same fourteen lines through both backends. The module-level
    `Random.randInt` is entropy on both.
19. **A capture of a reference is declared through its pointer cast**
    (vlang/v#30348). The creator's eight edits re-dressed nothing:
    inside a closure capturing a heap reference with `[mut self]`
    (every try block's body is one), `mut demo := self` copies the
    struct while `typeof(self)` says `&MmDemo`; `&MmDemo(self)` keeps
    the pointer. Found by prints inside the emitted V -- addresses and
    `typeof` -- in three probes and no regen.
20. **Every emitted slice bound is cast to int** (vlang/v#30352). Under
    MSVC, with or without `-prod` -- and a bare `-prod` picks MSVC on
    this host, so every "tcc -prod" build of the night was MSVC's --
    a string slice with `i64` bounds panics for an end that is in
    range; tcc and clang are right. Five lines pin it; the demo built
    `-prod` under MSVC had stopped after four lines at mapSlug's
    substring. The prod reference is zig cc; tcc is the debug lane,
    and V's own word is that tcc is not meant for `-prod`.

**What the demo costs** (the autoplay's first two minutes stepped, 168
lines, measured with the scratch measure.ps1 from the engine root,
three runs each). Overnight on an idle host the readings were stable;
the daytime readings of the optimized binaries spread two- to fourfold
because the host was in use, so those are given as best to worst.

| build | wall | peak memory |
|---|---|---|
| Zig harness, Debug (`zig build run-demo_test`) | 28.2 to 37.1 s | 808 MB |
| Zig harness, ReleaseFast | 2.6 to 5.2 s | 805 MB |
| V, tcc, no collector | 33.0 to 35.6 s | 1,059 MB |
| V, tcc, Boehm | 31.0 to 32.1 s | 240 MB |
| V, zig cc -O3 `-prod` | 7.4 to 29.6 s | 1,051 MB |
| V, MSVC /O2 `-prod` | 22.9 to 57.2 s | 1,052 MB |
| V, zig cc -O3 `-prod`, Boehm | 14.7 to 16.8 s | 174 to 181 MB |

(The datastore test, SQLite real, prints the harness's one line under V
too; it is part of the engine batch now.)

Reading it: unoptimized V under tcc runs the demo at the Debug harness's
speed; the collector returns four fifths of the memory at no speed
cost; the optimized Zig harness is five to ten times faster than its
Debug build, and the best optimized V binary (clang via zig cc) is two
to three times behind it; MSVC's build is behind clang's. A quiet-host
rerun of the optimized row is owed before the ratio is quoted as more
than a first read. The collector under clang does not crawl on the demo
(the crawl seen on the compiler-emit workload was that workload's): the
optimized build with Boehm has the lowest peak memory of the table, so
the collector is a switch in the shipping build too, at the cost of a
five-minute compile of the 37,000-line C with -O3.

21. **SQLite is real** (round 31). Zebra's `SqliteDb` / `SqliteRow`, the
    engine's datastore and the game's player store, were runtime stubs
    that panicked; they are V's `db.sqlite` now, over the same vendored
    amalgamation the Zig backend links (copied from the pinned compiler
    worktree's `vendor/sqlite` into V's `thirdparty/sqlite`; no
    download), `?` parameters through `exec_param_many`, rows read by
    column name. The section is inlined, and `db.sqlite` imported, only
    into a program whose emitted body names the runtime's sqlite
    symbols (a text check on the body), so a program without a
    database neither imports nor compiles the 9 MB of C; the demo and
    the datastore test carry it, the compiler and the small tests do
    not. The datastore test prints the harness's line under V. Sean's
    rule (2026-10-02): a mechanism the game's code uses must be working
    and under test, never skipped -- this was the last stub.

Two V rules met on the way: a local may not bear an imported module's
name (`rand`, `bits`), and `-prod` makes a warning an error. One
instrument fix: a chain now stops at the first red witness of the
pipeline's report, and the engine batch's diff normalizes every
millisecond count in the text (the demo prints five load timings).

**What runs.** `zbra/signal_test`, `zbra/instance_test` and
`zbra/tween_test` -- each with its own `main` -- print the same lines on
both backends (1, 1 and 10 lines). `game/mm/health_test` (222 lines, the
Health component's whole behaviour over the exported GUI scene: damage,
armor, regen, death, kill rewards) runs under V and prints the harness's
three lines byte for byte -- the two death notices and `all ok (19
Health components)`, seventeen of them the export's tagged instances
bound by the Framework at `begin()`, two the test's own. Its control
comes from the engine's own harness (`zig build run-health_test`),
since the Zig backend's `--module-path` cannot build a driver that sits
outside the module directory; the V run is from the engine root, where
the scene file is. The demo test (the whole demo, two minutes stepped,
168 lines) prints the harness's lines byte for byte with its five load
timings normalized. Built with `-prod` under MSVC (what a bare `-prod` picks on this host)
and under `zig cc -O3` (11.6 and 19.5 s), the health test prints the same
three lines; it is
startup-bound (150 to 300 ms, 8 to 17 MB) on the Zig harness, tcc,
tcc with Boehm and zig cc alike, so it gives no performance signal --
a read needs a longer workload. The four refusals in the 21 modules stand (three
stream-typed fields and one tuple literal, each a stub that panics if
reached) and nothing in the test reaches them. The V compile of the
health test is 9,000 lines of V and about two seconds with tcc.

## Main merged, the workarounds out (2026-10-13)

The Zebra session fixed BUG-559 and BUG-560 on main (3133ec1; the cause
corrected from what this note recorded above: the `*const` was the
INNER receiver, which the mutation scan never reached through a call
used as a receiver, and `inferExpr` typed only Math.abs / min / max, so
a `Math.floor(...)` result was unknown and hoisted), with BUG-561
(5e14144) and BUG-562 (68e80e3). Main is merged into this branch
(6fd6626: a clean textual merge, and the pipeline's fifteen witnesses
identical on the merged tree with the regen leaving it unchanged -- the
semantic check a clean merge does not give). The two workarounds are
out: the route's local that stood in for `res.source.len` read through
the imported class, and the third example's floats bound before
`.toInt()` -- `Math.floor(2.7).toInt()` is written as Zebra writes it
and prints the same on both backends. Still open on main from the same
night: BUG-563 (a list of lambdas types as List(str)), BUG-564 (a
statement lambda's indent inside a multi-line call), BUG-565 (`@[...]`
only inline after `in`); none is in this backend's way yet.

## V master's new compiler (2026-10-13)

Sean's question -- V's other compiler, the one with the flat AST and the
SSA path, is the better place to focus; had I tested its optimized
output? -- had the honest answer no: every number above came through
0.5.2's classic compiler, and the optimization was the C compiler's. So
master was built here (`C:/Projects/v-master`, commit 37b596b: seven
attempts, the Windows bootstrap being broken today in three ways -- the
module cache's native object that nothing on Windows builds or links,
MSVC's 16 KB string-literal limit on the generated second stage, and
Clang always given a MinGW target it has no sysroot for (vlang/v#30493,
#30494 and #30495, each through the review protocol, which corrected
two of the three causes before they went out) -- and finally built through a
`clang` shim onto zig cc that spells the mingw target as zig does,
passes `-fwrapv -fno-sanitize=undefined` since zig cc traps the signed
overflow V's literal parser relies on wrapping through, and compiles the
module cache's one native source alongside a stage) and our emitted
programs put through it.

Master moves, and the lane follows it (2026-10-14, 02:49): pulled to
d67ee55 (a shallow fetch and reset; the previous binary kept beside it
as `v_37b596b.exe`) and bootstrapped through the same shim in seven
minutes (`cmd //c ".\makev.bat -clang"` from the checkout: cmd on this
host does not search the current directory for a bare name). Under
it: vlang/v#30352 is fixed (3887674e, the i64 slice prints the right
character under MSVC; 0.5.2 still has it, so the emitter's `int()`
cast on slice bounds stays until the pin moves); #30470, #30471 and
#30473 reproduce unchanged; both lanes are green, eleven of eleven
under tcc and eleven of eleven `-prod` through zig cc. The `-prod`
builds took two to twenty-five times longer than under 37b596b
(signal_test 8m37 against 20 s, the demo 7m22 against 4m06), but the
Zebra session's gate was running alongside them, so that is not a
reading of master. One thing master does now that it did not: when
the new compiler's C fails to compile, it keeps the failing C, the
compiler's name and its output under `%TEMP%/v_0/v3_fallback_<pid>.c_error/`
and looks for a V 0.5.2 "fallback" build (`make v1`) to retry with,
which this host has not -- so a failure under master could one day be
masked by a silent retry through the classic compiler, and a lane
that reads "IDENTICAL" would then be reading the old compiler's work.
The lanes' logs say which compiler compiled (the fallback message is
printed when it is tried), and that line is now part of what to read.

What master's new compiler is, read from its sources: a flat AST, a
transformer, `markused` dead-code elimination, a direct emitter to C
(`cleanc`), and under `-prod` `-O3 -flto` per unit with content-cached
objects and a profile-guided build script; V's own optimizer -- mem2reg,
dominators, phi, fold, dce, a verifier, MIR lowering -- exists only on
the ARM64 native path, macOS only. On this host its code quality is
still clang's or MSVC's, on cleaner C with the dead code gone first.

**The dialect it demanded**, rounds 32 to 36, all of which keep every
0.5.2 witness identical: an option cast to its own type is refused
(`zopt_id(x)`, an identity function, in its place); a mutable binding of
an element reached through an immutable temporary is refused (`unsafe
{ }` around the index loop's binding); a narrowed read is spelled by its
TARGET -- the function form `zunwrap(zopt_id(x))` by default, since
0.5.2 miscompiles V's `or` form used directly as a call argument of a
generic-struct pointer type, and V's `x or { panic }` bound to a
temporary first where the value flows into an interface, since master
loses the method table of a value that comes out of a generic call
(vlang/v#30470) or of a field read in `or` form inside a closure
capturing `[mut self]` (every try block's body; the shape is on the
ticket); an option of a struct reference into an option of an interface
gets no conversion (vlang/v#30471); an option- or result-typed global
declared without an initializer is emitted type-erased (vlang/v#30473:
six lines), so the emitter's `__global` block carries `= ?T(none)`; and
`os.system` is deprecated, an error under `-prod`, so the runtime's
`sys.execInherit` runs through `os.new_process`. All three master
tickets went through the review protocol first.

**What runs under master:** every engine program the 0.5.2 lane runs --
signal, instance, tween, health (21 modules), tags, guiscene, guitree,
player_handler, round, datastore (SQLite) and the whole demo (168
lines) -- all identical to the harness under master's compiler with
tcc, in one scripted lane (`v_master_tests.sh`) -- and all eleven again
built `-prod` through zig cc under master (`v_master_prod.sh`, 1m17 to
4m06 a build), identical to the harness. The master lane is a peer of
the 0.5.2 lane now: `v_round_master_chain.sh` runs both master stages
after the 0.5.2 stages, so a round that breaks either dialect is red. Master's checker takes 3m16 on the demo's 37,000 lines where
0.5.2's takes 44 s. Master's `-prod` through zig cc first failed its
link on long-double math and `isnan` symbols; that was not the module
cache (a build without it fails the same), not zig's libc (a test
program using the names links) and not the generated C (the kept C has
none of them) -- master passes `-O3 -flto` inline for its unit compiles,
and zig cc's link loses exactly those symbols under LTO, the loss the
compiler-binary work had met in the response file; with `-flto`
dropped everywhere the optimized master binary through zig cc **builds
in 5m13 and runs the demo identical**. Its timing on this host came back
INVALID from the guarded instrument (another session's daily gate at 37
to 65 percent), which is the instrument working. **`-prod` through MSVC builds and
runs the demo identical** (4m12 to build), and that is the first
optimized number from the new compiler, on the same busy daytime host as
the table above, three runs each:

| build | wall | peak memory |
|---|---|---|
| V 0.5.2, MSVC /O2 `-prod` | 7.9 to 9.7 s | 1,054 MB |
| V master, MSVC /O2 `-prod` | 4.6 to 12.0 s | 1,096 MB |

**Retracted the next night:** "master 1.7 times faster" was noise. The
machine is a 15-watt laptop processor (i5-8365U, 1.6 GHz base, turbo to
about 4.1) whose clock a load reading cannot see: the same binaries ran
2.6 times slower one night than the other at a reported 0 percent, a
fixed loop took 11.7 s and then 2.1 s back to back. So the optimized
rows were re-measured round-robin -- every row in every round, a fixed
calibration loop first -- which cancels the drift in the ratios:

| round (calibration loop) | Zig ReleaseFast | V 0.5.2 zig cc -O3 | V 0.5.2 MSVC /O2 | V master MSVC /O2 | V 0.5.2 zig cc -O3 + Boehm |
|---|---|---|---|---|---|
| 1 (7.7 s) | 7.2 s | 16.9 s | 7.4 s | 6.2 s | 6.0 s |
| 2 (5.6 s) | 2.6 s | 6.7 s | 6.9 s | 9.5 s | 4.3 s |
| 3 (3.9 s) | 2.5 s | 3.7 s | 6.2 s | 4.8 s | 5.6 s |
| 4 (4.5 s) | 2.2 s | 6.6 s | 5.1 s | 7.1 s | 4.5 s |

What resolves: the optimized Zig harness is the fastest in every round,
by 1.5 to 3 times over any optimized V build; the optimized V builds
are indistinguishable from one another on this instrument (zig cc,
MSVC, master's MSVC, Boehm's all swing twofold within a round); and the
memory column, which is deterministic, stands as the solid result --
Boehm at 174 to 181 MB against 1.05 to 1.10 GB for everything else. A
master-versus-0.5.2 speed difference, if there is one, is below what
this laptop can measure; a desktop with a fixed clock would settle it.
The dialect is in, the engine's programs run on both compilers, the
optimized master binary exists, and three more V bugs are filed.

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

## The decision, as it stands (2026-10-15)

Sean, after the two merges: "I'm seriously considering V as the long
term back-end once it gets to the 0.5.3 ... and the work you've done is
significant step in that direction." So the pin moves at 0.5.3, and
these are the 0.5.2 workarounds to re-test there, each with its
witness, so the move retires what it can:

- the generic heap-init order rule (`zlist_of[string]` after
  `zlist_of[json2.Any]`; `fable/fieldnotes_v-heap-init-stale-expected`)
  -- the pipeline's v_poc2 names line;
- json2's escape sequences kept inside object keys (`zjson_fix_keys`
  in the runtime) -- the engine ladder's player_store_test;
- the C stage miscompiling an if-expression over a result guard with
  a `none` arm (the two-line `catch nil`) -- tuon_data_test;
- the `-cflags -Wno-incompatible-pointer-types` the clang 22+ build
  needs (`u32*` as `LPDWORD`; vlang/v#30587 on master, fixed there) --
  any GUI build;
- MSVC's negated `_const_min_int` (vlang/v#30352, fixed on master; the
  emitter's `int()` cast on slice bounds stays until then) -- the clang
  and msvc lanes;
- the demo's heap corruption under clang 22/23 at -O2 (parked;
  `opt_bisect.py`) -- the `-prod` lane.

Master is a different compiler (the flat AST, `cleanc`); 0.5.3 is the
first release that will say which of these it carries.

## The re-evaluation under master 7940bb1 (2026-10-20)

Sean asked (2026-10-20) for the V tree brought up to date and the state
re-read, since a run of the tickets had been fixed. V master 7940bb1 was
bootstrapped (`makev.bat -clang` under the zvm shim), with d67ee55 and
37b596b kept beside it as a cheap regression window; all thirty earlier
tickets were closed on vlang/v. Then the three witnesses ran under it,
against the 0.5.2 lane as the control. What master changed, and what
each change turned out to be:

| witness | 0.5.2 7647ce1 | master 7940bb1, first run | cause |
|---|---|---|---|
| `tools/v_gui_check.sh` (18 cases) | ok | dialogs exits 0xc0000139 | #30968: the post-link `longPathAware` manifest hides the side-by-side manifest; `TaskDialog` needs Common-Controls v6 |
| `tools/v_ide_check.sh` (12 gates + ide.exe) | ok | coverage_test (a V build error), gates_test and tools_test (asserts), ide.exe does not start | #30970, #30967 twice, #30968 |
| `tools/v_engine_check.py` (95 Zebra roots) | 92 identical, 2 refused, 1 differs | 84 identical, 8 V build, 2 refused, 1 differs | #30966 on seven roots (`jv_opt = zunwrap(zopt_id(fresh))` over `json2.Any`), one root a param named like a global (master refuses, 0.5.2 noticed), the differs the Zig control's hash order |

Five tickets came out of it, each through one Opus 5.5 review round
whose key claims I re-ran before posting (the pattern held every time:
my draft named a construct one step too specific, the reviewer found a
smaller program):

- **vlang/v#30965** -- a parenthesized value converted to `?I` / `!I`
  is boxed twice (the surviving shape behind #30470's comment).
- **vlang/v#30966** -- a generic call assigned to an existing `?T`
  lvalue infers `T` as the option itself (`o = id(Any(3))` instantiates
  `id_T_Option_Any`); int payloads carry the same wrong instantiation
  silently; `id[Any](...)` works. The emitter's every map read.
- **vlang/v#30967** -- a bare `join_path` call in `main` is lowered to
  `os.join_path_single` whatever it names (`transform/fn.v` keys on the
  spelling; a one-argument user `join_path` returns its argument with
  no error). The IDE's own `join_path(root, rel)` helper.
- **vlang/v#30968** -- V embeds a `longPathAware` manifest after the
  link, so a side-by-side `<exe>.manifest` is ignored; a program
  needing Common-Controls v6 fails to start. No flag to opt out.
- **vlang/v#30970** -- an `if mut e := opt()` binding over a reference
  is refused as immutable in `f(mut e).method()` when `f` returns a
  generic struct; `v -check` accepts it, the full compile refuses it.

What the backend adapted, all of it harmless on 0.5.2 (the pipeline's
every diff identical after the change):

- a narrowed read spells the payload type on the runtime generics when
  the emitter knows it, `zunwrap[T](zopt_id[T](x))` (`narrowedRead`
  takes the nilable's V type; the three callers pass what they have);
  the generic form stays where the type is unknown;
- a parameter named like an emitted module-level var or const is
  renamed `_v`, as a local already was (`genParams` spells it,
  `resetLocals` re-makes the rename per def -- and now clears the
  table per def, which it never did);
- the two GUI witnesses embed the Common-Controls manifest as an
  RT_MANIFEST resource (`1 24 "app.manifest"` through `llvm-windres`
  beside clang, the object on V's link line through `-ldflags`),
  instead of laying the side file: V keeps a manifest the linker
  embedded, on both compilers; the price is `longPathAware`, which our
  manifest does not declare.

Not adapted, on purpose: the `join_path` lowering (#30967) and the
`if mut` refusal (#30970) are V's to fix, and renaming the IDE's helper
or re-shaping every `if x as y` to dodge them would hide the witness
that will say when they are fixed. The IDE check stays red under master
on those three gates until then.

After the adaptation: GUI witness ok under both; IDE check 15/15 under
0.5.2, 12/15 under master with ide.exe built and running (the three
reds are #30967 x2 and #30970); the ladders' numbers below.

The engine ladder after the adaptation, both compilers (one run each,
the same OUT shape, the Zig controls re-run):

| compiler | identical | refused | differs | V build |
|---|---|---|---|---|
| 0.5.2 7647ce1 | 92 | 2 | 1 | 0 |
| master 7940bb1 | 92 | 2 | 1 | 0 |

The two refusals are the emitter's own (a call on a call's result and
the generic `Atomic` in tween_create_test; `Tcp.connect` in the
devtools), the differs is net_figures_test's drop tally, where the Zig
control iterates a HashMap in hash order and V in insertion order
(`respawn 1 left 1 gone 1` is the order the test drops them; the
control says `left` first). Master's seven #30966 roots build with the
typed `zunwrap`, and robloxglobals_test with the renamed param. So on
the engine's 95 Zebra roots master and 0.5.2 now read the same; what
separates them is the IDE's three gates (#30967, #30970) and the
manifest (#30968), each with a ticket and a witness that will say when
it closes. Master took 1038 s to 0.5.2's 346 s for the same ladder:
the new compiler is three times slower on these builds on this host
(one reading, the host otherwise quiet).

The decision above stands: the pin stays on 0.5.2 until 0.5.3; the
re-test list there gains nothing from this round (none of the five is
a 0.5.2 workaround), and the three master-only shapes above are the
new entries to re-test when the pin moves.

## The cost matrix re-measured, master against 0.5.2 (2026-10-20)

Sean asked for the week-old numbers re-taken. The host was quiet (27
percent CPU, 17 GB free), each build timed once, each emit of
`selfhost/main.zbr` (the whole compiler, fourteen `.zig` files, 105,366
lines) three times, the peak the OS's own PeakWorkingSetSize read
through the process handle after exit (`C:/Projects/v-dist/measure.py`;
the fresh ReleaseFast control took 136 s to build). Every V-built
compiler's emit was byte-identical to the Zig control's.

| compiler | build of zebra_v.exe (65,336-line main.v) | emit of main.zbr | peak |
|---|---|---|---|
| Zig Debug (the control) | -- | 12.7 s | 390 MB |
| Zig ReleaseFast | 136 s | 1.57 s | 360 MB |
| V 0.5.2, tcc, no collector | 3.3 s | 6.1 s | 588 MB |
| V 0.5.2, tcc, Boehm | 4.0 s | 7.1 s | 209 MB |
| V 0.5.2, clang 23 `-prod` | 49.6 s | 2.78 s | 585 MB |
| V 0.5.2, MSVC `-prod` | 68.4 s | 2.60 s | 588 MB |
| V master 7940bb1, any C compiler | refused: over 10 GB (14.3 GB when the limit is lifted, then killed) | -- | -- |

So on 0.5.2 the optimized V-built compiler is 1.7x the Zig ReleaseFast
build on the emit and 1.6x its memory, with Boehm the smallest process
of all at the cost of a tenth in time -- the week-old ratios, re-read
on a quiet host.

Master could not build the compiler route at all, and the week-old row
that said it could (1,096 MB under MSVC `-prod`, 2026-10-13) does not
reproduce: the same 37b596b binary over its own vlib, on the Oct 12
emission, trips the 10 GiB guard today, and `-check` alone does (0.5.2:
481 MB). I cannot say what that row measured; the fallback to an old
compiler the driver tries on failure (`v_old.exe`, dated Oct 14, is on
this host now and was not then) is the candidate I would bet on, and
the row is struck. The ladder's largest program (demo_test_prog.v,
37,826 lines) builds under master at 9.8 GB in 29.7 s against 0.5.2's
1.07 GB in 5.0 s; the curve on four smaller roots:

| emitted program | lines | 0.5.2 peak | master peak | 0.5.2 / master wall |
|---|---|---|---|---|
| abbreviate_number_test | 1,430 | 216 MB | 301 MB | 1.5 / 4.3 s |
| physics_test | 4,870 | 266 MB | 380 MB | 1.5 / 4.8 s |
| net_figures_test | 11,871 | 447 MB | 931 MB | 2.3 / 10.4 s |
| map_library_test | 14,295 | 473 MB | 1,405 MB | 2.3 / 11.2 s |
| demo_test | 37,826 | 1,067 MB | 9,819 MB | 5.0 / 29.7 s |
| main (the compiler) | 65,336 | 796 MB | over 14 GB | 3.3 s / refused |

A synthetic program says what drives it: N small structs, each holding
one `&ZList[string]` (one generic struct, one instantiation) and
calling its methods. Master's `-check`: 100 structs 307 MB, 250
structs 3.8 GB, 500 structs over 10 GB; the same program with the
generic replaced by a plain `Strs` struct: 97 MB and 123 MB. V 0.5.2:
72 to 157 MB either way. One generic instantiation used from N places
costs master something far worse than linear in N -- vlang/v#30975,
whose reviewer found the trigger smaller still: top-level declarations
alone (500 structs with the field, an empty main: 2.4 GB; 1000: over
the guard; 0.5.2: 66 MB), the peak in the checker's `check` stage, not
the monomorphizer, and distinct instantiations or in-body uses cheap.

The instrument hung itself once on the way: the first measure.py piped
the child's stderr and drained it only after exit, and under its
watchdog loop a compiler that printed more than the pipe's 64 KB of
notices blocked on its own stderr -- which read as a V master hang for
twenty minutes, across two builds, until 0.5.2 "hung" the same way. The
stderr goes to a file now. A hang in the subject is the instrument
until proven otherwise.

## If the branch ever merges to main

- `tools/regen_selfhost.sh`'s FILES list names CodeGenV (this branch); since
  1670756 the script refuses an emitted module the list does not name, so a
  merge that drops it fails by name.
- `tools/bootstrap_check.sh` keeps its own FILES list with the same seam
  (it checks the listed files are present); CodeGenV goes in there too, or
  the round-trip proof skips the new module without a word (the Zebra
  session's note, 2026-10-13).

## How to run it

SQLite on the V side needs V's own thirdparty copy of the amalgamation:
`C:/Projects/v-dist/v/thirdparty/sqlite/sqlite3.c` and `sqlite3.h`,
copied from a pinned compiler worktree's `vendor/sqlite/` (the same
files the Zig backend links; V's own install script would download
them instead). Without them a program that uses a database fails at
the C stage naming the missing header.

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
