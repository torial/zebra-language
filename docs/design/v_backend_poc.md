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

**What a V-built Zebra compiler is and is not.** It compiles Zebra to
Zig exactly as the Zig-built one does, so it can stand in for it
wherever `--emit-zig` is the job (the engine's regen, a `zebra build`
that only emits). It cannot build the Zig it emits (that needs Zig, as
before), it has no LSP and no debugger bridge, and no HTTP.

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
