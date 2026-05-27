# Zebra Language Quick Reference

This file is the **agent-facing quick reference** for the Zebra language (.zbr files).
It covers syntax, semantics, and idioms needed to read and write Zebra without
scanning the full compiler source. For the compiler's own implementation see `src/`.

> **Reading order:** New to Zebra? Start with the **Getting Started** section
> below, then §1–§14 for everyday syntax.  §15–§23 are reference for specialised
> features.  §24–§25 cover contracts and reflection.  §26 is idioms; §27 is
> gotchas.  §28–§31 are memory/build/GUI/stdlib.  §32–§40 cover advanced and
> newer features (SIMD, Test, tuples, channels, type aliases, refinements,
> `using`, `with`, SQLite).  §41–§44 cover `namespace`, `extend`, `@derive`,
> and `DynLib` (dynamic library plugins).

---

## Getting Started

### What is Zebra?

Zebra is a statically-typed, compiled programming language in the Python / Cobra / Eiffel
family. The name is a portmanteau of **Zig** and **Cobra** — `.zbr` source files compile
to native executables via a Zig backend.

**Design goals:**

- **Safe by default.** Nil tracking, optional types, and Design-by-Contract (`require`,
  `ensure`, `invariant`) make precondition violations visible at compile time rather than
  as runtime crashes.
- **Readable.** Python-style indentation, no semicolons, no boilerplate class scaffolding,
  `print "hello"` without import.
- **Fast native output.** The Zig backend gives C-level performance and a simple,
  deterministic memory model (arena allocator by default).
- **Self-hosting.** The compiler is being progressively rewritten in Zebra itself
  (see `selfhost/`).

Zebra is not a scripting language — programs are compiled ahead of time. It is also not
a Zig wrapper; Zig is an implementation detail you can usually ignore unless you need to
call C libraries via `zig"..."` escape hatches (§23).

---

### Installation

**Requirements:** Zig 0.15.0 or newer. The recommended way to install Zig on Windows or
Linux is [zvm](https://github.com/tristanisham/zvm) (Zig Version Manager):

```bash
# Install zvm (follow instructions at https://github.com/tristanisham/zvm)
# Then install Zig 0.15.0 or the latest stable:
zvm install 0.15.0
zvm use 0.15.0
```

**Clone and build:**

```bash
git clone https://github.com/torial/zebra-language.git
cd zebra-language
zig build
```

This produces `zig-out/bin/zebra` (or `zebra.exe` on Windows).

**Add to PATH** so you can invoke `zebra` from anywhere:

```bash
# Bash / Git Bash (Windows):
export PATH="$PWD/zig-out/bin:$PATH"

# Or add to your shell profile (~/.bashrc, ~/.zshrc, etc.) permanently.
```

**Verify:**

```bash
zebra --version        # prints the compiler version
zig build test         # runs the test suite (~150 tests)
```

> **Note:** The Zig compiler itself must also be on your PATH. If you used zvm, run
> `export PATH="$HOME/.zvm/bin:$PATH"` (or the Windows equivalent) before building.

---

### Hello, World

Save the following as `hello.zbr`:

```zebra
def main
    print "Hello, Zebra!"
```

Compile and run:

```bash
zebra hello.zbr
```

Output:

```
Hello, Zebra!
```

**What just happened?**

- `def main` declares a top-level function named `main`. No class required.
- `print` is a built-in statement (not a function call) — parentheses are optional.
- Indentation defines blocks — no braces or `begin`/`end`.

**A slightly larger example** — reading command-line arguments:

```zebra
use sys

def main
    var args = Arg.all()
    if args.len == 0
        print "Usage: hello <name>"
    else
        print "Hello, ${args[0]}!"
```

```bash
zebra hello.zbr World
# → Hello, World!
```

**Compiler subcommands:**

| Command | What it does |
|---------|-------------|
| `zebra file.zbr` | Compile and run (default backend) |
| `zebra repl` | Interactive REPL (`:help` for commands) |
| `zebra test file.zbr` | Run test suite (§33) |
| `zebra build` | Project build system (§29) |
| `zebra check file.zbr` | Dead-code analysis |
| `zebra debug file.zbr` | Launch with LLDB-DAP debugger |
| `zebra --emit-zig file.zbr` | Emit Zig source without running |
| `zebra --turbo file.zbr` | Strip contract checks (§24) |
| `zebra --gui-backend=libui_ng f.zbr` | GUI with native OS controls (§30) |

---

## 1. File structure

```zebra
# comment
use ast exposing Decl, TypeRef        # import from module, expose names into scope
use codegen                            # import module (access via codegen.Name)

# top-level functions
def helper(x: int): str
    return x.toString()

# top-level class / struct / enum / union
class Foo
    ...

struct Bar
    ...
```

- `.zbr` files are modules. The module name is the file stem (`codegen.zbr` → module `codegen`).
- `use path/to/module` makes `module.Name` available.
- `use path/to/module exposing A, B` also binds `A` and `B` directly in scope.
- No explicit `main` — programs use either a `class Main` with `static def main`,
  or a top-level `def main()`.

---

## 2. Variables

```zebra
var x = 42                     # inferred type (int)
var name: str = "hello"        # explicit type annotation
var flag: bool                 # declaration without init (must assign before use)
var opt: int? = nil            # optional int, initially nil
```

- `var` is always mutable.  There is no `let` / `const` in Zebra source.
- The compiler emits `const` or `var` in Zig based on mutation analysis — you
  don't control this.
- Type annotations use `: Type` (colon) syntax, not `as Type`.  `as` is reserved
  for binding clauses (`if x as n`, `branch on V as r`, `if x is T as r`) — see §11, §13, §21.

---

## 3. Primitive types

| Zebra           | Zig                  | Notes                                |
|-----------------|----------------------|--------------------------------------|
| `int`           | `i64`                | default integer                      |
| `uint`          | `u64`                |                                      |
| `byte`          | `u8`                 | semantic alias for `uint8`           |
| `float`         | `f64`                | default float                        |
| `bool`          | `bool`               |                                      |
| `char`          | `u21`                | Unicode codepoint                    |
| `str`           | `[]const u8`         | immutable string slice               |
| `String`        | `[]const u8`         | alias for `str`                      |
| `int8…128`      | `i8…i128`            | sized signed integers                |
| `uint8…128`     | `u8…u128`            | sized unsigned integers              |
| `float16…128`   | `f16…f128`           | sized floats                         |
| `StringBuilder` | `std.ArrayList(u8)`  | growable string buffer               |
| `void`          | `void`               |                                      |

Optionals: `T?` → `?T` in Zig.  `nil` → `null`.

Float suffix literals: `1.5_f32`, `2.5_f64`, `0.5f32`, `3.0f64` emit
`@as(fNN, val)` directly.

### §3.1 Operator precedence (highest → lowest)

| Level | Operators | Notes |
|-------|-----------|-------|
| 1 — postfix | `x!`  `x?`  `.method()`  `[i]`  `?.` | Force-unwrap, optional-chain |
| 2 — unary | `not`  `-x` | Logical not; arithmetic negation |
| 3 — multiplicative | `*`  `/`  `%` | |
| 4 — additive | `+`  `-` | String concat is also `+` |
| 5 — comparison | `<`  `<=`  `>`  `>=`  `is`  `in` | `is`: type check; `in`: containment |
| 6 — equality | `==`  `!=` | |
| 7 — logical and | `and` | Short-circuits |
| 8 — logical or | `or` | Short-circuits |
| 9 — nil/error fallback | `orelse`  `catch` | `orelse`: `T?`; `catch`: error union |
| 10 — pipeline | `->` | Left-to-right chaining |

`orelse` and `catch` have the same precedence (level 9); they associate left-to-right.
`->`  (pipeline) is the lowest non-assignment operator, so `a + b -> f` means `f(a + b)`.

---

## 4. Functions (top-level `def`)

```zebra
def add(a: int, b: int): int
    return a + b

def greet(name: str)             # void return — no annotation
    print "Hello, ${name}"

def divide(a: int, b: int): int throws
    if b == 0
        raise "division by zero"
    return a / b
```

- `throws` makes the function return `anyerror!T` in Zig.
- `raise "msg"` creates an error with `_error_ctx.message = "msg"`.
- Calls always need parentheses: `add(1, 2)`.  A bare `add` is a function reference.
- Top-level `def main()` is allowed in addition to `class Main` + `static def main`.

### Named and default arguments

```zebra
def open(path: str, mode: str = "r", buffered: bool = true)
    ...

# Call sites:
open("data.txt")                        # mode and buffered take defaults
open("data.txt", mode: "w")             # named arg; buffered defaults
open("data.txt", buffered: false)       # skip mode (uses default)
open(path: "data.txt", mode: "w")       # all named
```

**Rules:**

- Defaults appear after the type annotation: `name: T = expr`.
- Any parameter with a default can be skipped at the call site, regardless of position.
  Non-contiguous skipping is allowed — `open("f.txt", buffered: false)` skips `mode`.
- At a call site, all positional arguments must come before the first named argument:
  `open("data.txt", mode: "w")` is fine; `open(mode: "w", "data.txt")` is a parse error.
- Named args after the last positional may appear in **any order**:
  `open("f.txt", buffered: false, mode: "w")` is the same as `open("f.txt", mode: "w", buffered: false)`.
- Default expressions are evaluated at the **call site** (not at definition time).  You can
  use runtime values as defaults:
  ```zebra
  def log(msg: str, level: int = Log.defaultLevel())
      ...
  ```
- Type annotation on the default is required — `name = "r"` without `: str` is a
  parser error.
- Methods on classes use the same syntax; `cue init` constructors also support
  named/default args.
- **Struct construction** uses named arg syntax too: `Point(x: 1, y: 2)` — see §6.

---

## 5. Classes (reference types)

Classes are heap-allocated.  Variables hold a pointer (`*ClassName` in Zig).
Assigning a class variable copies the pointer, not the object.

```zebra
class Counter
    var count: int

    cue init()                        # constructor
        count = 0

    def increment
        count += 1

    def value(): int                  # instance method
        return count

    def name: str                     # getter (no parens, no params) — read like a field
        return "Counter"

    static
        def create(): Counter         # static method — group form
            return Counter()
```

- `cue init(params...)` is the constructor.  No return type.
- `static def` declares a type-associated method (no `this`).  The `static`
  group form (a `static` line, indented members below) is preferred for >1 static.
- Field access inside methods uses the **leading-dot shorthand**: `.count`
  reads/writes the field, even when a local variable shadows the name.  Bare
  `count` is also legal but only when no local shadows it — `.count` is the
  shadow-resilient default.  External: `obj.count`.  See §26 for the idiom
  table.
- Constructor call: `Counter()` or `Counter(arg1, arg2)`.

### Static members (`static def` / `static var`)

`static def` and `static var` declare members that belong to the **type**, not to
any particular instance.  They are accessed via `ClassName.member`, never via an object.

```zebra
class Registry
    static var count: int         # class-level variable; shared across all instances
    static var instances: List(Registry)

    cue init
        Registry.count += 1       # access static vars with ClassName.
        Registry.instances.append(this)

    static
        def total(): int          # group form: multiple statics under one `static` block
            return Registry.count

        def reset()
            Registry.count = 0
            Registry.instances = List(Registry)()

    def id(): int
        return Registry.count     # instance method can read static var

# Usage:
var r1 = Registry()
var r2 = Registry()
print Registry.total()            # → 2
```

**Two forms of static declaration:**

```zebra
class Foo
    # Inline form — one member at a time:
    static def hello()
        print "hello from Foo"

    static var greeting: str = "hi"

    # Group form — preferred when there are multiple statics:
    static
        def bye()
            print "bye"
        var farewell: str = "goodbye"
```

**Key points:**

- `static var` is initialized **once**, at program start (Zig `const` or `var` at module
  scope).  There is no per-instance copy.
- `static def` has no `this` / no leading-dot access — it cannot read or write instance
  fields.  If you need `this`, the method is not static.
- `static var` with a `List` or `HashMap` default must be initialized in `cue init`
  or a static `def` — direct default expressions are evaluated at compile time.
- Static and instance members share the same namespace; you cannot have a static `def foo`
  and an instance `def foo` in the same class.
- `static` members are accessed cross-module as `Module.ClassName.member` (note the two
  dots of qualification).

### Method modifiers (`@once`, `@profile`, `@tag`)

Prefix a `def` declaration with an `@modifier` to alter its behaviour:

```zebra
class Config
    @once
    def load(): str        # body runs at most once; result is cached on the instance
        return File.read("config.json")

    @profile
    def heavyWork()        # body is wrapped with Profile.start/end automatically
        # ...

    @tag("unit", "fast")
    static def test_defaults()   # tagged for selective test runs
        assert_eq .load(), "{}"
```

- **`@once`** — the first call executes the body and stores the result in a hidden
  field (`_once_cache_<name>` + `_once_done_<name>`).  Subsequent calls return the
  cached value without re-running the body.  Works for any non-void return type.
  If the method returns `void`, the body is suppressed after the first call.
- **`@profile`** — wraps the body with `Profile.start("ClassName.method")`
  and `defer Profile.end(...)`.  Requires the `Profile` module (stdlib).
- **`@tag("label", ...)`** — attaches one or more string tags to a test method for
  use with `zebra test --tag <label>`.  See §33 for full details.

> **Note (0.13 sweep):** `def name: T` (no parens at decl) is being removed
> from the grammar — see BUG-112.  Always use `def name(): T`.  Callers
> always write parens (`obj.name()`) regardless.

---

## 6. Structs (value types)

Structs are copied on assignment.  Methods take `self: *StructType` in Zig.

```zebra
struct Point
    var x: int
    var y: int

    cue init(x: int = 0, y: int = 0)  # default params allowed on cue init
        .x = x                        # leading-dot shorthand: param `x` shadows field `x`
        .y = y

    def distSq(): int
        return .x * .x + .y * .y

    def withX(nx: int): Point         # returns a modified copy
        var p = this except
            x = nx
        return p

# Call sites — named args and defaults work on constructors too:
var p1 = Point()                  # x=0, y=0 (all defaults)
var p2 = Point(y: 5)              # x=0 (default), y=5 (named)
var p3 = Point(3, 4)              # positional — x=3, y=4
```

- `.field` is the canonical receiver-field access (works regardless of local
  shadowing).  Bare `field` is legal when no local shadows it but is more
  fragile to future edits.  `this.field` is non-canonical — see §26.
- `this` itself (no dot) is the whole struct value, used in
  `this except field = value, ...` — the immutable-update idiom.
- Method-chaining on struct temporaries works in `var`-init, `return`, and
  assignment positions (the compiler auto-materialises the temporary).
  Expression-position chains (call args, compound expressions) still need a
  manual temp — see §27.

---

## 7. `struct except` — context forking

```zebra
struct Config
    var indent:  int
    var owner:   str
    var verbose: bool

    def indented(): Config
        var c = this except
            indent = indent + 1
        return c

    def withOwner(name: str): Config
        var c = this except
            owner = name
        return c
```

`this except` produces a new value with the listed fields overridden; all other
fields are copied.

---

## 8. Enums

```zebra
enum Color
    red
    green
    blue

enum Status(int)              # backed by int
    ok = 0
    err = 1
```

Usage: `Color.red`, `Status.ok`.

---

## 9. Unions (tagged unions)

```zebra
union Expr
    int_:  int
    str_:  str
    void_                     # payload-less variant
    node_: ^Node              # heap-indirection payload (^T only valid for structs/primitives/unions)

# Construction:
var e = Expr.int_(42)
var v = Expr.void_()

# Pattern matching:
branch e
    on Expr.int_ as n
        print "int: ${n}"
    on Expr.str_ as s
        print "str: ${s}"
    on Expr.void_
        print "void"
    else
        pass
```

- `^T` payload: the pointer is transparent — the branch-binding variable has
  type `T`, not `*T`.
- `^T` is valid only for struct / primitive / union payloads.  Using
  `^ClassName` where `ClassName` is a class is a **compile error** (BUG-078):
  classes are already reference types; `^ClassName` would double-box to `**T`.
  Use `item: ClassName` directly.
- `else` with `pass` is required for non-exhaustive branches.

```zebra
# Single-variant check with payload binding:
var e = Expr.int_(42)
if e is Expr.int_ as n
    print "got int: ${n}"     # n is the int payload
else
    print "not int"

# Standalone `is` check (no binding):
var ok  = e is Expr.int_      # true — union variant check
var ok2 = e is MyClass        # true — class type-tag check

# Negated check — `is not`:
var not_int = e is not Expr.int_     # true when e is any variant except int_
if e is not Expr.str_
    print "not a string"
```

**Precedence of `is not`:** `is not` and `not in` are comparisons (higher precedence
than `not`, `and`, `or`).  Compound boolean expressions parse as you'd expect:

```zebra
x is not Foo or y is not Bar   # → (x is not Foo) or (y is not Bar)
not x is not Foo               # → not (x is not Foo)  ≡  x is Foo
```

**Style rule — `if … is … as` vs `branch`:**
- Use `if x is Union.Variant as r` when checking a **single variant** and
  binding its payload.  Reads naturally: "if x is a member expression, bind it as m".
- Use `branch x` when dispatching across **multiple variants**.  `branch` is
  exhaustive-by-default; cover the rest with `else`.

```zebra
# ✓ Single-variant: use if-is
if e is Expr.member as m
    genMember(m)

# ✓ Multi-variant: use branch
branch e
    on Expr.int_ as n    print "int: ${n}"
    on Expr.str_ as s    print "str: ${s}"
    else                 pass
```

---

## 10. Collections

```zebra
# List
var items = List(int)()              # empty list, constructor form
items.add(1)
items.add(2)
# Or — list literal `[…]` builds the same thing in one expression:
var nums = [1, 2, 3]                 # type inferred from the first element
var labels = ["alpha", "beta"]       # → List(str)
var empty: List(int) = []            # empty literal needs an annotation
var n = items.count()                # length
var x = items.at(0)                  # index (bounds-checked)
items.remove(0)                      # remove by index
var has = items.any(def(x) = x > 2)  # true if any element matches predicate
var ok  = items.all(def(x) = x > 0)  # true if every element matches predicate
var f   = items.find(def(x) = x > 2) # first match or nil (returns T?)

# HashMap
var m = HashMap(str, int)()
m.set("a", 1)
var v = m.get("a")                   # returns int? (optional)
var has = m.contains("a")            # bool
m.remove("a")

# StrSet (set of strings)
var s = StrSet()
s.add("hello")
var present = s.contains("hello")

# Iteration
for item in items
    print item

for k, v in m
    print "${k} = ${v}"

# Tuple list destructuring — `for a, b in list_of_pairs`
# The list must be declared as List((T1, T2)) (explicit type annotation required).
var pairs: List((int, str)) = List((int, str))()
pairs.add((1, "one"))
for n, s in pairs           # n: int, s: str
    print "${n}: ${s}"
for n, s in pairs if n > 0 # where clause supported
    print n

# Array literal
var nums = @[3, 1, 4, 1, 5]
if 3 in nums
    print "three is present"
```

Field declarations use the type without an initializer; the constructor (or
`var x = expr` in a method body) does the actual init — see §27 gotcha #4.

---

## 11. Optional types and nil

```zebra
var x: int? = nil
var y: int? = 42

# Nil check + force-unwrap:
if x != nil
    print x!                         # `x!` = force-unwrap (panics if nil); alias: `x to!`

# Optional-unwrap binding form:
if y as n
    print "y is ${n}"                # n is non-optional int

# Combined with type check (LHS must be optional):
var maybeUser: User? = lookup()
if maybeUser is User as u            # binds u: User (non-optional)
    print u.name

# Nil-coalescing with orelse:
var z = x orelse 0                   # use 0 if nil (also works on error unions)

# Optional chaining:
var n = node?.next                   # nil if node is nil
var s = node?.toString()             # method call — nil if node is nil
var v = node?.value! + 1             # unwrap result of optional chain
```

- `x!` is the force-unwrap operator.  Panics if nil.  `x to!` is a legacy alias.
- `x orelse fallback` — evaluates `fallback` when `x` is nil (for `T?`) or an error
  (for `anyerror!T`).  This is the Zebra equivalent of Zig's `orelse`.  There is no
  `??` operator in Zebra.
- `?.` is optional member/method access — propagates nil.  Result type is `T?`.
  If the accessed member is already `T?`, the result is still `T?` (flattened, not `T??`).
  Chain multiple accesses: `a?.b?.c` propagates nil through each step.
- `if x as n` (when `x: T?`) binds `n: T` in the then-branch.
- **`orelse` vs `catch`**: use `orelse` on optionals (`T?`), use `catch` on error
  results (`throws`).  Both can appear in the same expression for chained recovery.

---

## 12. Error handling

```zebra
def divide(a: int, b: int): int throws
    if b == 0
        raise "division by zero"
    return a / b

def caller(): int throws
    var r = divide(10, 2)            # auto-propagates (same-file throws calls)
    return r

# Method-level catch (catch clauses after the method body):
def risky()
    var r = divide(10, 0)
    print r
catch |e|
    print "Error: ${e.message}"

# Inline postfix catch — fallback value on error:
var r = divide(10, 0) catch 0

# Explicit propagation with `?`:
var r = someObj.method()?            # propagates if method throws

# `try expr` prefix was removed in 0.15 — use `expr?` instead:
# OLD: var r = try divide(10, 2)
# NEW: var r = divide(10, 2)?
```

- `throws` on a `def` makes it return `anyerror!T`.
- Inside a `throws` method, calls to other `throws` methods in the **same file**
  auto-propagate (compiler emits `try`).  For cross-module `throws` calls or
  calls on local variables, use explicit `?` suffix.
- **Migration note**: The `try expr` prefix form was removed in 0.15.
  Replace every `try f()` with `f()?`; the semantics are identical.
- `raise "msg"` creates an error string; `raise "msg", obj` attaches a
  `_Stringable` details object.
- `catch` clauses appear after the method body at the same indent as `def`;
  they wrap the entire body.  Multiple `catch` clauses are allowed; each has an
  optional `|binding|` and typed variant `|e: ErrorType|`.

---

## 13. Control flow

```zebra
# if / else if / else (block form)
if x > 0
    print "positive"
else if x < 0
    print "negative"
else
    print "zero"

# Inline single-line if: `if cond: stmt` — colon required
if x > 0: print "positive"

# Inline with else (same line or next line)
if x > 0: label = "pos" else: label = "non-pos"

if x > 0: label = "pos"
else: label = "non-pos"

# Inline else-if chain
if grade >= 90: letter = "A" else if grade >= 80: letter = "B" else: letter = "F"

# Inline if with return (common idiom)
def sign(n: int): String
    if n > 0: return "pos"
    else if n < 0: return "neg"
    else: return "zero"

# Notes:
#   - Colon (`:`) is required before the inline body
#   - No capture binding (`as`) in inline form — use block form for that
#   - Control structures (while, for, branch) still require block form

# while
var i = 0
while i < 10
    print i
    i += 1

# while with bind-and-guard:
while line = reader.readLine() != nil
    process(line!)

# for-in (list)
for item in items
    print item

# for-in with index
for i, item in items
    print "${i}: ${item}"

# for-in with numeric range
for i in 0 to 10                     # 0..9
    print i
for i in 0 to 10 step 2
    print i

# for-in with inline guard (filter condition; skip non-matching elements)
for item in items if item > 0
    totals.add(item)

# for-in guard also works on split, chars, and range iterators
for p in text.split(",") if p != ""
    parts.add(p)
for i in 0.to(100) if i % 2 == 0
    evens.add(i)

# for-else (else runs when loop completes without break)
for item in items
    if item == target
        found = item
        break
else
    found = default

# guard (early return on nil/false)
guard x != nil else
    return

# branch — pattern matching on unions
branch expr
    on Expr.int_ as n
        return n
    on Expr.str_ as s
        return s.len
    else
        pass

# branch with struct field patterns (0.7+)
branch p
    on Point(x: 0, y: 0)             # exact field match
        print "origin"
    on Point(x: 0)                   # partial — only x must equal 0
        print "on Y axis"
    else
        print "elsewhere"
```

- `for x in list if cond` — the inline guard skips non-matching elements via
  `continue`; works on all iterator forms (list, split, chars, range, HashMap).
- `for-else` is fully supported on list `.items` iteration; HashMap /
  string-split / chars iterators silently drop the `else` block (deferred).
- `branch` struct patterns match by field value; the type name must be a
  struct in scope.  An optional `as binding` clause binds the whole struct.

---

## 14. String operations

```zebra
var s = "hello"
var t = "world"
var u = s + ", " + t                 # concatenation
var n = s.len                        # length (int)
var c = s[0]                         # char at index
var sub = s[1..3]                    # substring slice
var up = s.upper()
var lo = s.lower()
var trimmed = s.trim()
var b   = s.startsWith("hel")        # bool
var b2  = s.endsWith("lo")           # bool
var idx = s.indexOf("ll")            # int? (nil if not found)
var parts  = s.split(",")            # List(str)
var joined = items.join(", ")        # str

# String interpolation — basic
var msg = "Hello, ${name}!  You have ${count} items."

# Format specifiers: ${expr:spec}  spec = [fill][align][width][.prec][type]
var hex  = "${n:08x}"               # 000000ff  (zero-padded 8-digit hex)
var flt  = "${fval:.2f}"            # 3.14      (2 decimal places)
var rpad = "${greeting:>20}"        #                hello  (right-align, width 20)
var lpad = "${tag:-<15}"            # ok-------------       (left-align, fill '-')
var cpt  = "${codepoint:c}"         # Unicode scalar as character
# align chars: < left  > right  ^ center
# type chars:  x/X hex  o octal  b binary  f float  e/E scientific  s string

# StringBuilder
var sb = StringBuilder()
sb.append("hello")
sb.append(" world")
var result = sb.build()              # str (drains the builder)
```

- `in` operator: `if "needle" in haystack` — substring test.
- Inside `${…}`, non-string values get an implicit `.toString()` call.
- **Format specifiers** — `${expr:spec}` where `spec` follows
  `[fill][align][width][.precision][type]`.  Fill is any character; align is
  `<` (left), `>` (right), or `^` (center); type chars: `x`/`X` hex, `o`
  octal, `b` binary, `f` float, `e`/`E` scientific, `c` Unicode scalar, `s`
  string.  Examples: `${n:08x}` → `000000ff`, `${v:.2f}` → `3.14`,
  `${s:>20}` right-aligns in a 20-char field, `${s:-<15}` left-aligns with
  `-` fill.
- To include a literal `${` in a string, escape the dollar sign: `"\${"`.

### String method reference

**Returns `str`:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `upper()` | `(): str` | All characters uppercased |
| `lower()` | `(): str` | All characters lowercased |
| `trim()` | `(): str` | Strip leading and trailing whitespace |
| `trimLeft()` | `(): str` | Strip leading whitespace |
| `trimRight()` | `(): str` | Strip trailing whitespace |
| `reverse()` | `(): str` | Reverse the string |
| `replace(from, to)` | `(str, str): str` | Replace all occurrences of `from` with `to` |
| `repeat(n)` | `(int): str` | Repeat the string `n` times |
| `padLeft(width, fill)` | `(int, str): str` | Pad on the left to `width` characters with `fill` |
| `padRight(width, fill)` | `(int, str): str` | Pad on the right to `width` characters |
| `center(width, fill)` | `(int, str): str` | Center within `width` characters |
| `concat(other)` | `(str): str` | Append `other` (same as `+`) |
| `format(args...)` | variadic | `std.fmt.allocPrint`-style format |
| `join(sep)` | `(str): str` | Join list elements — called on `List(str)`, not a single `str` |
| `substring(start, end)` | `(int, int): str` | Slice from `start` to `end` (same as `s[start..end]`) |
| `toHex()` | `(): str` | Hex-encode bytes |
| `fromHex()` | `(): str` | Decode hex string to bytes |
| `encodeBase64()` | `(): str` | Base64-encode |
| `decodeBase64()` | `(): str` | Base64-decode |
| `lines()` | `(): List(str)` | Split on newlines |

**Returns `int`:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `len` | (field) | Byte length |
| `indexOf(sub)` | `(str): int?` | First occurrence index; `nil` if not found |
| `lastIndexOf(sub)` | `(str): int?` | Last occurrence index |
| `indexOfFrom(sub, from)` | `(str, int): int?` | Search starting at `from` |
| `indexOfIgnoreCase(sub)` | `(str): int?` | Case-insensitive `indexOf` |
| `count(sub)` | `(str): int` | Number of non-overlapping occurrences |
| `toInt()` | `(): int` | Parse as decimal integer (panics on bad input) |
| `toIntBase(base)` | `(int): int` | Parse with given base (2, 8, 10, 16) |
| `codePointCount()` | `(): int` | Count Unicode codepoints (not bytes) |

**Returns `bool`:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `contains(sub)` | `(str): bool` | Substring presence check |
| `startsWith(pre)` | `(str): bool` | Prefix check |
| `endsWith(suf)` | `(str): bool` | Suffix check |
| `isEmpty()` | `(): bool` | True when `len == 0` |
| `isAlpha()` | `(): bool` | All codepoints are Unicode letters |
| `isNumeric()` | `(): bool` | All codepoints are decimal digits |
| `isAlphanumeric()` | `(): bool` | All codepoints are letters or digits |
| `isPrintable()` | `(): bool` | All codepoints are printable |
| `isValidUtf8()` | `(): bool` | Valid UTF-8 byte sequence |
| `eqlIgnoreCase(other)` | `(str): bool` | Case-insensitive equality |
| `startsWithIgnoreCase(pre)` | `(str): bool` | Case-insensitive prefix |
| `endsWithIgnoreCase(suf)` | `(str): bool` | Case-insensitive suffix |
| `containsIgnoreCase(sub)` | `(str): bool` | Case-insensitive contains |

**Returns sequence:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `split(sep)` | `(str): List(str)` | Split on `sep` string |
| `chars()` | `(): List(char)` | Sequence of Unicode codepoints (`u21`) |
| `bytes()` | `(): List(int)` | Sequence of bytes (`u8` as `int`) |

### Raw strings (`r'…'` / `r"…"`)

The `r` prefix makes backslashes literal and disables `${…}` interpolation.
Two quote forms are available — pick the one whose quote character is not in
your content:

```zebra
var re   = r"\d+\.\d+"              # r"…" — backslash literal; no ${} expansion
var path = r"C:\Users\Sean\docs"    # Windows path — four literal backslashes

# Use r'…' when your content contains double quotes:
var json_tmpl = r'{"key": "value"}'   # double-quotes inside single-quoted raw

# Use r"…" when your content contains single quotes:
var sql_frag  = r"WHERE name = 'Alice'"
```

**What raw strings do and don't do:**

| Feature | `r"…"` / `r'…'` |
|---------|-----------------|
| Backslashes are literal (`\` stays `\`) | ✅ |
| `${…}` interpolation | ✗ disabled |
| Escape sequences (`\n`, `\t`, etc.) | ✗ not processed |
| Spans multiple lines | ✗ single line only |
| Can contain `"` (double-quote) | only in `r'…'` form |
| Can contain `'` (single-quote) | only in `r"…"` form |

The closing quote terminates the string — there is no way to escape it inside a
raw string.  If you need both quote types in one string, use triple-quoted
(`"""…"""`) or a regular string with `\'` / `\"` escapes.

### Triple-quoted strings (`"""…"""`)

Multi-line literals.  No `${…}` interpolation; backslashes are literal.

**Single-line form** — content between the `"""` delimiters on the same line:

```zebra
var sql = """SELECT * FROM users WHERE name = 'Alice' AND status = "active" """
# Result: SELECT * FROM users WHERE name = 'Alice' AND status = "active"
# (trailing space before """ is stripped)
```

**Multiline form** — `"""` on its own line, content indented, closing `"""` on
its own line:

```zebra
var html = """
    <html>
        <body>Hello</body>
    </html>
    """
# Result (exact bytes):
# "    <html>\n        <body>Hello</body>\n    </html>\n"
#  ^^^^ 4 spaces preserved — content indentation is NOT dedented
```

**Stripping rules** (applied in this order):
1. Strip the opening `"""` and closing `"""` delimiters.
2. Strip exactly one leading `\n` (the newline immediately after the opening `"""`).
3. Strip trailing spaces and tabs only — the whitespace before the closing `"""`.
   A trailing newline is NOT stripped (only the indent-spaces after it).

**What this means in practice:**

```zebra
var a = """
    line one
    line two
"""
# → "    line one\n    line two\n"
#   Leading 4-space indent preserved; trailing \n kept; no spaces after \n

var b = """
    line one
    line two
    """
# → "    line one\n    line two\n"
#   Same result — trailing "    " (the indent of closing """) is stripped

var c = """line one"""
# → "line one"
```

**What triple-quoted strings can contain:**

| | `"""…"""` |
|---|---|
| Single quotes `'` | ✅ freely |
| Double quotes `"` or `""` | ✅ freely |
| Three consecutive `"""` | ✗ terminates the string |
| `${…}` interpolation | ✗ not available |
| Backslash sequences | treated as literal (e.g. `\n` stays two chars) |
| Multi-line content | ✅ |

> **To get both interpolation and multi-line**, build the string with `+` and
> a regular `"…"` string:
> ```zebra
> var name = "Alice"
> var body = "    <p>Hello, ${name}</p>\n    <p>Welcome.</p>\n"
> ```

---

## 15. Modules and cross-module usage

```zebra
# file: math_utils.zbr
def square(x: int): int
    return x * x

struct Vec2
    var x: float
    var y: float

    def length(): float
        return Math.sqrt(x*x + y*y)
```

```zebra
# file: main.zbr
use math_utils exposing square, Vec2

def main
    var n = square(5)                # direct call
    var v = Vec2(3.0, 4.0)
    print v.length()
```

```zebra
# Without exposing — qualified access:
use math_utils

def main
    var n = math_utils.square(5)
    var v = math_utils.Vec2(3.0, 4.0)
```

**Cross-module type annotation:**
```zebra
var v: math_utils.Vec2 = math_utils.Vec2(1.0, 2.0)
# OR with exposing:
var v: Vec2 = Vec2(1.0, 2.0)
```

**Partial files** — `Foo.zbr` is the primary; `Foo.json.zbr`, `Foo.ui.zbr`
etc. are partials whose `class Foo` members merge into the primary.

---

## 16. Interfaces and mixins

```zebra
interface Printable
    def show(): str

mixin Describable
    def describe(): str
        return "Describable instance"

class Dog implements Printable adds Describable
    var name: str

    cue init(name: str)
        .name = name

    def show(): str
        return "Dog(${name})"

# `is` check:
if obj is Printable
    print obj.show()
```

- `implements` declares interface conformance — the compiler verifies all
  required methods exist via `comptime { Iface.check(@This()); }`.
- `adds Mixin` includes methods from a mixin declaration.
- `is Iface` performs the conformance check at runtime.

---

## 17. Generics

```zebra
class Stack(T)
    var items: List(T)

    cue init()
        items = List(T)()

    def push(item: T)
        .items.add(item)

    def pop(): T?
        if .items.count() == 0
            return nil
        var last = .items.at(.items.count() - 1)
        .items.remove(.items.count() - 1)
        return last

# Constrained generic — T must implement Comparable:
class SortedList(T where T implements Comparable)
    ...

# Usage:
var s = Stack(int)()
s.push(1)
s.push(2)
var top = s.pop()
```

- Generic class instantiation: `Stack(int)()` — type arg, then constructor args.
- The constraint clause is `T where T implements InterfaceName` (full form, not
  the shorthand `T where Comparable`).

---

## 18. Properties

There is no special property / getter syntax in Zebra.  The
`prop` / `get` / `set` / `body` / `post` keywords were removed.

Use ordinary methods for computed state:

```zebra
class Circle
    var radius: float

    def diameter(): float
        return .radius * 2.0

    def area(): float
        return Math.PI * .radius * .radius

# Use:
var c = Circle(5.0)
print c.radius                    # field access — no parens
print c.area()                    # method call — parens required
```

**Field visibility** — use `public`, `private`, `internal`, or `protected` on
fields and methods.  `private` restricts to the owning class; `internal`
excludes the member from cross-module interface tables; `protected` limits
to the class and subclasses.  Default (no keyword) is equivalent to `public`.

```zebra
class Wallet
    private var balance: float     # only Wallet methods can access this
    public def deposit(n: float)
        .balance = .balance + n
    public def getBalance(): float
        return .balance
```

---

## 19. Lambda / closures

```zebra
# Expression lambda:
var double = (x: int) -> x * 2

# Statement-body lambda:
var consume = def(x: int)
    print "got ${x}"
    log("seen", x)

# Implicit closure capture:
var counter = 0
var bump = def()
    counter += 1                     # captures `counter` from the enclosing scope
```

- Free variables are auto-captured (no explicit `capture` block needed for
  read-only access in most cases).
- An explicit `capture` block at the top of a lambda body declares persistent
  per-instance state — see §19.1 below.

### §19.1 `capture` blocks — persistent per-closure state

A `capture` block declares variables that are **private to one closure instance** and
persist across calls.

**Without `capture`:** a lambda is emitted as a plain function pointer (no wrapper struct).
It can reference module-level variables, but has no private persistent state of its own.

**With `capture`:** the lambda is wrapped in an anonymous struct.  Each creation of the
lambda allocates a fresh instance of that struct with its own independent fields.

```zebra
# Factory that returns a fresh counter each time:
var make_counter = def(): def(): int
    return def(): int
        capture
            var count: int = 0
        count += 1
        return count

var c1 = make_counter()
var c2 = make_counter()
print c1()   # → 1
print c1()   # → 2
print c2()   # → 1  (independent from c1)
print c1()   # → 3
```

**How it works:** The `capture` block's variables become fields of an anonymous Zig
struct.  Each call to the factory allocates a fresh instance.  The struct's `call` method
is invoked on each call to the closure.

**Mutation detection:** The compiler inspects the lambda body and emits
`self: *@This()` (mutable self) when any capture field is directly assigned or passed to a
known-mutating method (`append`, `add`, `remove`, `set`, etc.).  For class-type captures
(which are already pointers), `self: @This()` is sufficient even when you call methods on
them — mutation goes through the pointer, not the field.

**Rules:**

- `capture` must be the first statement in the lambda body (before any other code).
- Declarations inside `capture` use the same `var name: Type = init` syntax as regular
  variables.  The initializer runs **once**, when the closure is created.
- Captured variables are mutable: `count += 1` in the example above works.
- Closures with a `capture` block are passed around as values of any `sig` type whose
  signature matches — the struct satisfies the `sig` via a `.call` method.
- **GUI use case**: `capture` is the idiomatic way to hold per-widget state in GUI
  callbacks without a global variable:

```zebra
def view(g: Gui, model: Model)
    var click_count = def(): void
        capture
            var clicks: int = 0
        clicks += 1
        print "Clicked ${clicks} times"
    if g.button("Click me")
        click_count()
```

---

## 20. `sig` — function type aliases

`sig` declares a named function-pointer type.  Use it to pass functions as
arguments or store them in variables:

```zebra
sig Comparator(a: int, b: int): int
sig Predicate(item: str): bool
sig Callback()                       # void return — no return type needed

def sort(items: List(int), cmp: Comparator)
    pass

static def ascending(a: int, b: int): int
    return a - b

def main
    var nums = @[3, 1, 4, 1, 5]
    sort(nums, ascending)
```

### How sigs work

- `sig` resolves to `*const fn(T1, T2, ...) R` in Zig.
- **Structural typing:** any `static def` or lambda with a matching parameter list and
  return type is compatible — no explicit `implements` required.
- **Calling through a `sig` variable:**

```zebra
sig Transform(x: int): int

static def double(x: int): int
    return x * 2

static def negate(x: int): int
    return -x

def applyAll(items: List(int), fn: Transform): List(int)
    var out = List(int)()
    for v in items
        out.add(fn(v))    # call through the sig — plain call syntax
    return out

def main
    var ns = @[1, 2, 3]
    var doubled = applyAll(ns, double)
    var negated = applyAll(ns, negate)
```

- **Lambda assignment:** a lambda whose signature matches is assignment-compatible with a
  `sig` variable:

```zebra
sig Callback()

var cb: Callback = def()
    print "called"

cb()    # invoke the stored callback
```

- **`sig` in `class` fields:** you can store callbacks as fields — useful for
  event-driven patterns:

```zebra
class Button
    var onClick: Callback? = nil

    def click()
        if .onClick as cb
            cb()
```

---

## 21. Type checks and unwrapping

```zebra
# Runtime type check (returns bool):
if obj is Dog
    print "is a dog"                  # `obj` is still typed as the original

# Force-unwrap optional:
var x: int? = 42
var y = x!                            # panics if nil  (`x to!` is a legacy alias)

# Combined type check + binding (requires LHS to be optional):
var maybe: Animal? = lookup()
if maybe is Animal as a
    print a.name                      # `a: Animal` (non-optional)

# Numeric conversions are methods, not cast operators:
var i = 3
var f = i.toFloat()                   # int → float
var s = i.toString()                  # int → str
```

There is no `expr as T` cast operator in current Zebra.  Where you'd reach for
a cast in another language:
- For optional / union / class **downcasts**, use `if x is T as binding`.
  The `as` here is a binding clause, not a cast expression.
- For **numeric conversions**, use the typed `.toFloat()` / `.toInt()` /
  `.toString()` methods on the source value.
- For raw bit-pattern conversions, drop into `zig"…"` (§23).

---

## 22. `^T` heap-indirection (recursive types only)

Used to break recursive struct/union cycles — the **only** reason to reach for `^T`.

```zebra
struct Node
    var value: int
    var next:  ^Node?                 # heap-boxed optional pointer

# Construction — boxing is automatic:
var a = Node(1, nil)
var b = Node(2, nil)
a.next = b                            # auto-boxes: allocates *Node, copies b in
```

### Rules

- `^T` in a field type → `*T` in Zig; `^T?` → `?*T`.
- **Auto-boxing:** assigning a value of type `T` to a `^T` field allocates a heap copy
  automatically.  No explicit `new` or `box(…)` call is needed.
- **Transparent in `branch`:** inside a `branch` arm that binds a `^T` union payload, the
  binding has type `T` — the pointer indirection is stripped for you.
- **`^ClassName` is a compile error** — classes already have reference semantics;
  double-boxing is rejected.

### `^T?` fields and nil

```zebra
struct TreeNode
    var value: int
    var left:  ^TreeNode?
    var right: ^TreeNode?

# Inserting a child — auto-boxes:
var root = TreeNode(value: 5, left: nil, right: nil)
var child = TreeNode(value: 3, left: nil, right: nil)
root.left = child                     # allocates *TreeNode, copies child into it

# Nil check:
if root.left as n
    print n.value                     # n: TreeNode (deref'd — pointer transparent)
```

### Union with `^T` payload

```zebra
union Expr
    num(value: int)
    add(left: ^Expr, right: ^Expr)

var e = Expr.add(left: Expr.num(1), right: Expr.num(2))
branch e
    on Expr.add as a
        # a.left: Expr (transparent — ^Expr auto-deref'd)
        print a.left
    on Expr.num as n
        print n.value
```

### Iterating `List(^T)`

When a `List` holds `^T` elements, the for-in binding has type `T` (the pointer is
stripped):

```zebra
var nodes: List(^Node) = List(^Node)()
# ... populate
for n in nodes
    print n.value    # n: Node (not ^Node)
```

---

## 23. `zig"…"` escape hatch

Inline Zig code, for stdlib wrappers or patterns Zebra doesn't support:

```zebra
def rawMemset(ptr: uint, size: uint)
    zig"@memset(@as([*]u8, @ptrFromInt(ptr))[0..size], 0);"
```

---

## 24. Contracts (`require` / `ensure` / `invariant`)

Contracts are Zebra's identity feature.  They emit runtime checks by default
and can be stripped via `--turbo`.

```zebra
def sqrt(x: float): float
    require
        x >= 0.0                     # pre-condition
    ensure
        result >= 0.0                # post-condition (uses `result` keyword)
        result * result <= x + 1e-9
    if x == 0.0
        return 0.0
    var g = x / 2.0
    while abs(g*g - x) > 1e-9
        g = (g + x/g) / 2.0
    return g
```

- `require` clauses run at function entry; failure panics with a clear message.
- `ensure` clauses run at function exit (any successful return path).  The
  `result` keyword inside `ensure` refers to the return value — its type is
  the function's declared return type, so `result.len`, `result.startsWith(…)`,
  etc. all work as expected.
- Both clause lists may contain multiple expressions (one per indented line).
- `ensure` does **not** fire on the error path of a `throws` function — only
  on successful return.

### `old` snapshots in `ensure`

```zebra
def increment(n: int): int
    ensure
        result == old n + 1          # snapshot pre-call value of `n`
    return n + 1
```

`old expr` snapshots `expr` at function entry; the snapshot is referenced by
the post-condition.  Useful when the caller-supplied value is later mutated
or shadowed inside the function.

### Class invariants

```zebra
class Counter
    var count: int

    cue init()
        count = 0

    invariant
        count >= 0                   # checked at end of init and exit of every public method

    def decrement
        count -= 1
```

The invariant is verified after `cue init` completes and after every public
method returns.  A violation panics with the offending class name + condition.

### `--turbo` flag

`zebra --turbo file.zbr` strips `require` / `ensure` / `invariant` from
codegen, producing release-style binaries with no contract overhead.  Use
during normal development without `--turbo` so contracts catch bugs early.

---

## 25. Reflection (`Reflect.*` and `@reflectable`)

Two tiers are supported:

### Tier 1 — `Reflect.className` / `fieldNames` / `fieldTypes`

Static field/type-name arrays for any class — emitted as `_reflect_<T>_*`
const arrays in `.rodata`.  Linker dead-strips them when unreferenced (zero
cost when unused):

```zebra
class User
    var name: str = ""
    var age:  int = 0

class Main
    static
        def main
            var u = User()
            print Reflect.className(u)        # "User"
            for name in Reflect.fieldNames(u)
                print name                    # "name", "age"
```

### Tier 3 — `@reflectable` + `Json.parseStrict(T, src): ?T`

For type-safe JSON deserialization, mark a class `@reflectable` and call
`Json.parseStrict`:

```zebra
@reflectable
class User
    var name: str = ""
    var age:  int = 0
    var rate: float = 0.0
    var ok:   bool = false

class Main
    static
        def main
            var src = "{\"name\":\"Alice\",\"age\":30,\"rate\":1.5,\"ok\":true}"
            if Json.parseStrict(User, src) as u
                print u.name                  # "Alice"
            else
                print "parse failed"
```

**Why `@reflectable` is required:** The annotation is an explicit opt-in signal to the
codegen to emit per-field lookup tables (`_reflect_<T>_field_names`,
`_reflect_<T>_field_types`).  Without it the tables are not emitted, keeping binary size
minimal.  A call to `Json.parseStrict(NonAnnotatedClass, …)` is a hard compile-time error
that names the missing annotation.

**Strict semantics:**
- Missing required key → `nil`.
- Type mismatch (`{"age":"30"}`) → `nil`.
- Extra key (`{…,"surprise":1}`) → `nil`.
- Top-level not an object → `nil`.
- Float field accepts integer JSON values (`5` → `5.0`).

**Hard-error gates at codegen time:**
- `Json.parseStrict(NotAClass, …)` →
  `'NotAClass' is not a class declared in this module`.
- `Json.parseStrict(NonReflectable, …)` →
  `Json.parseStrict requires '@reflectable class NonReflectable' — add the annotation to NonReflectable's declaration`.
- Field with non-primitive type (e.g. `var tags: List(int)`) →
  `field 'tags' has unsupported type 'List(int)' (only int/float/bool/str supported in 0.9)`.

**Scope-1 (current):** only `int` / `float` / `bool` / `str` (and `String` alias)
fields.  `T?`, `List(T)`, sized numerics, and nested `@reflectable` classes are deferred
— attempting to use them gives the hard-error above at compile time.

---

## 26. Key idioms summary

| Pattern              | Zebra                          | Notes                                    |
|----------------------|--------------------------------|------------------------------------------|
| Force-unwrap optional | `x!`                          | panics if nil; `x to!` is a legacy alias |
| Nil-coalescing       | `x orelse default`             | also works on error unions               |
| Optional unwrap bind | `if x as n`                    | `n: T` when `x: T?`                      |
| Type-check + bind    | `if obj is Dog as d`           | combined `is` + `as`                     |
| Substring test       | `"needle" in str`              | preferred over `.contains`               |
| Optional chain       | `obj?.field`                   | propagates nil                           |
| Error propagation    | `expr?`                        | explicit in cross-module / local-var calls |
| Auto-propagation     | `.method()`                    | same-file `throws` methods only          |
| Struct update copy   | `this except field = val`      | `this` (no dot) = the whole value        |
| Class downcast       | `if x is Dog as d`             | requires `x: Dog?`; binds `d: Dog`        |
| Int-to-float         | `x.toFloat()`                  | explicit conversion                      |
| Divide integers      | `int` division                 | use `%` for modulo                       |
| Field access (self)  | `.field`                       | leading-dot shorthand; shadow-resilient  |

---

## 27. Common gotchas

1. **`else` + `pass` must be on separate lines:**
   ```zebra
   # WRONG:
   else pass
   # RIGHT:
   else
       pass
   ```

2. **`if` inline form requires a colon — the colon is not optional:**
   ```zebra
   # WRONG (no colon):
   if x > 0 return x
   # RIGHT (block form):
   if x > 0
       return x
   # RIGHT (inline form — colon required):
   if x > 0: return x
   ```

3. **Multi-line `use` — all names must be on one line (no continuation):**
   ```zebra
   use ast exposing Decl, DeclEnum, DeclUnion, DeclStruct, TypeRef
   ```

4. **Method-body locals: `List(T)()` required — call the constructor:**
   ```zebra
   def foo()
       var items = List(int)()       # correct — init required for locals
       var items: List(int)          # ERROR — collection locals must be initialized
   ```

5. **Struct/class FIELD declarations use `var x: List(T)` (no init) — init goes in `cue init`:**
   ```zebra
   class Foo
       var items: List(int)          # field declaration, no init here
       cue init()
           items = List(int)()       # init here

   struct Bar
       var parts: List(str)
       cue init(parts: List(str))
           .parts = parts             # leading-dot shorthand
   ```
   The rule: `var X = List(T)()` is for **method bodies**.
   `var X: List(T)` is for **field declarations**.

6. **`StringBuilder` field → use `= StringBuilder()` in `cue init`.**
   The compiler special-cases `StringBuilder()` to emit `std.ArrayList(u8){}`.

7. **Method chaining on struct temporaries** works in `var`-init, `return`,
   and assignment positions (auto-materialised).  Expression-position chains
   (call args, compound expressions) still need a manual temp:
   ```zebra
   # OK — var init:
   var c = makeConfig().indented().withOwner("Foo")
   # OK — return:
   return makeConfig().indented()
   # NEEDS TEMP — call argument position:
   var c0 = makeConfig().indented()
   process(c0.withOwner("Foo"))
   ```

8. **`print` is a statement, not a function:** `print "hello"`, not `print("hello")`.
   For multiple values: `print "a", b, "c"`.

9. **Keyword escaping** — Zig keywords used as Zebra field names get a
   trailing-underscore convention: `type_`, `void_`.

10. **`cue init` with explicit params needs `.field` when param shadows field:**
    ```zebra
    cue init(x: int, y: int)
        .x = x                       # leading-dot shorthand: param `x` shadows field `x`
        .y = y
    ```
    Bare `x = x` would be self-assignment of the parameter; `.x = x` reaches the field.

11. **`for-else` on HashMap / string-split / chars iterators:** the `else` block
    is silently dropped (deferred work).  Only list `.items` iteration is fully
    supported.

12. **`allocate` block — strings/slices allocated inside a scoped block do NOT survive it:**
    ```zebra
    allocate Arena()
        var src = File.read("data.txt")
        var words = src.split(" ")
        process(words)
    # src and words are gone here — the sub-arena was freed
    ```
    Copy values you need to survive using assignment to outer variables
    (string concat, List addition, etc. all allocate into the outer arena):
    ```zebra
    var summary = ""
    allocate Arena()
        var src = File.read("data.txt")
        summary = summarise(src)     # copies result into outer arena
    print summary                    # safe
    ```
    The old `arena { }` keyword is removed.  Use `allocate Arena()` instead
    (the compiler will print a helpful error if you use the old form).

13. **CRLF line endings crash the tokenizer.**  `.zbr` files must use LF only.
    A `\r` produces `unexpected '\r' (CRLF line endings — convert to LF)`.

---

## 28. Memory model and `allocate` blocks

Zebra uses a single program-wide `ArenaAllocator`.  All allocations (strings,
lists, class instances) live until program exit.  You never free individual
values; the arena cleans up everything at once.  This makes memory management
invisible for typical programs.

### When you need bounded-scope memory: `allocate`

The `allocate <expr>` block redirects `_allocator` to any `AllocatorSource`-
compatible value for the duration of a lexical scope.  On exit the allocator
is cleaned up (if scoped) and `_allocator` reverts to the parent.

```zebra
allocate Arena()
    var src = File.read("big_file.txt")
    var parsed = parse(src)
    result = extract_summary(parsed)  # copies into parent arena
# big_file.txt buffer + all parse temporaries freed here
```

**Named allocator wrappers** (all implement `AllocatorSource`):

| Name | Zig backing | Scoped? | Notes |
|------|-------------|---------|-------|
| `Arena()` | `std.heap.ArenaAllocator` | ✓ | general sub-arena; most common choice |
| `Debug()` | `std.heap.DebugAllocator` | ✓ | leak detection; `GeneralPurposeAllocator` alias |
| `Page()` | `std.heap.page_allocator` | ✗ | singleton; no cleanup needed |
| `Smp()` | `std.heap.smp_allocator` | ✗ | thread-safe singleton; no cleanup |
| `C()` | `std.heap.c_allocator` | ✗ | libc malloc/free; no cleanup |
| `FixedBuffer(buf)` | `std.heap.FixedBufferAllocator` | ✓ | `buf` is a `[]byte` |
| `ThreadSafe(inner)` | `std.heap.ThreadSafeAllocator` | ✓ | wraps another `AllocatorSource` |
| `Pool(T)()` | `std.heap.MemoryPool(T)` | ✓ | single-type pool |
| `StackFallback(N)()` | `std.heap.stackFallback(N, _allocator)` | ✓ | stack-first, spills to parent |

You can also pass any class that implements `AllocatorSource` (`def allocator(): Allocator` + `def deinit()`).

Typical uses:
- **Large file processing in a loop** — `allocate Arena()` each iteration to discard
  temporaries before reading the next file.
- **Leak detection during development** — swap in `allocate Debug()` to catch
  unmatched allocations.
- **Stack-local scratch** — `allocate StackFallback(4096)()` avoids heap for small work.
- **Any batch operation** where you want to bound peak memory usage.

### What does NOT survive a scoped `allocate` block

Any `str`, `List`, or class instance allocated inside a scoped block is freed when
the block exits.  If you store a reference to it in an outer variable, that
reference becomes dangling.

```zebra
# Safe pattern:
var name = ""
allocate Arena()
    var src = File.read("config.txt")
    name = parse_name(src)            # _str_concat call copies into outer arena

# Unsafe — DO NOT DO THIS:
var ptr_into_block: str
allocate Arena()
    var src = File.read("config.txt")
    ptr_into_block = src              # WRONG: src freed when block exits
print ptr_into_block                  # dangling slice — undefined behaviour
```

Non-scoped wrappers (`Page()`, `Smp()`, `C()`) do not free on exit, so values
allocated inside survive naturally; `<-` degenerates to plain assignment for these.

### `<-` copy-out operator

The `<-` operator deep-copies a value from the inner allocator into the parent
allocator and assigns it to an outer variable — surviving the block's deinit:

```zebra
var result: str = ""
allocate Arena()
    var src = File.read("big_file.txt")
    var summary = process(src)
    result <- summary           # deep-copies 'summary' into the parent allocator
# src + all temporaries freed here; 'result' is safe

# Outside any allocate block: <- is a plain assignment (no copy needed)
var x: str = ""
x <- "hello"                    # equivalent to x = "hello"

# List copy-out
var words: List(str) = List()
allocate Arena()
    var inner: List(str) = List()
    inner.add("hello")
    inner.add("world")
    words <- inner              # deep-copies all elements into the parent allocator

# Class instance copy-out (including recursive ^T? fields)
var head: ^Node? = nil
allocate Arena()
    var n = Node("a", Node("b", nil))
    head <- n                   # recursively copies the entire linked list
```

- **`str`:** duplicated into the parent allocator via `alloc.dupe`.
- **`List(T)`:** a new ArrayList is allocated in the parent; each element is deep-copied.
- **Class/struct:** each field is recursively deep-copied (handles `^T?` linked lists).
- **Primitives (`int`, `float`, `bool`, `char`):** plain assignment — no heap involved.
- **`HashMap`:** not supported — `HashMap` copy-out is a compile error. Iterate and rebuild manually.
- **Outside a scoped block (or with a non-scoped wrapper):** plain assignment.

### Why individual `free` calls are absent

Unlike Zig or C, Zebra never emits `defer allocator.free(x)` for local string
variables.  With `ArenaAllocator`, individual frees are either a no-op (middle
of the arena) or dangerous (last allocation — Zig 0.15 rewinds the bump
pointer, corrupting any sub-slice still in use).  `allocate Arena()` is the
correct, safe mechanism for bounded reclaim.

---

## 29. Build and run

### Compiler subcommands

```bash
zebra file.zbr                        # compile and run (default backend)
zebra repl                            # interactive REPL
zebra test file.zbr                   # run test suite (see §33)
zebra build                           # project build system (see below)
zebra check file.zbr                  # dead-code analysis
zebra debug file.zbr                  # launch with LLDB-DAP debugger
zebra --emit-zig file.zbr             # emit Zig source without running
zebra --turbo file.zbr                # strip contract checks (faster)
zebra --gui-backend=libui_ng f.zbr    # GUI with native OS controls
```

### From the repository

```bash
# From repo root:
zig build run -- path/to/file.zbr            # compile and run
zig build test                                # run test suite
zig-out/bin/zebra.exe --emit-zig file.zbr     # selfhost compiler — Zig source to stdout
zig-out/bin/zebra-bootstrap.exe --emit-zig f  # Zig-implemented compiler (escape hatch)
zig build update-selfhost                     # regenerate selfhost/*.zig from *.zbr
```

The compiler resolves `use module_name` by looking for `module_name.zbr` in
the same directory as the input file, then in `selfhost/`, `test/`, and
stdlib paths.

### `zebra build` — project build system

Place a `build.zbr` file in your project root and run `zebra build`.
The `Build` module is a built-in; no `use` import is needed.

```python
def main()
    var b = Build.new()

    # exe(name, entry_source) → BuildTarget
    var app = b.exe("myapp", "src/main.zbr")
    app.platform("x86_64-linux")      # optional: cross-compilation target
    app.option("optimize", "Debug")    # optional: zig build-exe flag

    # lib(name, entry_source) → BuildTarget
    var lib = b.lib("mylib", "src/lib.zbr")

    # linkLib(other: BuildTarget) — record a dependency edge
    app.linkLib(lib)

    # b.dependency(name, version) — post-1.0 package manager stub (no-op now)
    b.dependency("some-pkg", "0.1.0")

    # b.run() — compile all exe targets via zig build-exe
    b.run()
```

**Declarative style (recommended):** omit the `b.run()` call entirely.
`zebra build` automatically calls it after `main()` returns — the same pattern
as Zig's own `build.zig`.  Calling `b.run()` explicitly still works (imperative
style); the auto-run is a no-op if the explicit call already ran.

```python
def main()
    var b = Build.new()
    b.exe("myapp", "src/main.zbr").option("optimize", "ReleaseSafe")
    # no b.run() needed — zebra build calls it automatically
```

**How `b.run()` works:** for each `exe` target it runs
`zebra --emit-zig <entry>` then `zig build-exe <zig_file> -femit-bin=zig-out/bin/<name>`.
`lib` and `test_` targets are stubs that print a "not yet implemented" message.

**BuildTarget chain methods** all return `self`, so they can be chained:

```python
b.exe("app", "src/main.zbr").platform("aarch64-linux").option("optimize", "ReleaseSafe")
```

| Method | Effect |
|---|---|
| `b.exe(name, entry)` | Add an executable target |
| `b.lib(name, entry)` | Add a library target (stub) |
| `b.run()` | Compile all registered targets |
| `target.platform(str)` | Set cross-compilation target triple |
| `target.option(key, val)` | Pass a build option through to zig |
| `target.linkLib(other)` | Record a lib dependency edge |
| `b.dependency(name, ver)` | Stub for future package manager |

### `zebra repl` — interactive REPL

Launch with `zebra repl`.  Enter Zebra statements and expressions one at a time.
Multi-line input is supported.

```
$ zebra repl
Zebra REPL 0.15 — type :help for commands
>>> var x = 10 + 5
>>> print x
15
>>> def double(n: int): int
...     return n * 2
>>> double(x)
30
```

**REPL commands** (prefix with `:`):

| Command | Action |
|---------|--------|
| `:help` | Print list of REPL commands |
| `:clear` | Clear the accumulated history (start fresh) |
| `:history` | Show all statements entered in this session |
| `:load <file>` | Load and run a `.zbr` file into the REPL environment |
| `:save <file>` | Save the current session history to a file |
| `:exit` / Ctrl-D | Exit the REPL |

**Multi-line input:** If a line ends with an indent (i.e. starts a block), the REPL
shows `...` and waits for the block body.  Complete the block with a blank line or
a dedented line to execute.

**Accumulation model:** Each input is appended to the session. Redefining a function
or variable runs the re-defined version but does not remove the old one from history
(`:clear` resets everything).

### `zebra check` — dead-code analysis

`zebra check file.zbr` reports:
- **Unused union arms** — union variants never matched in any `branch` expression.
- **Unreachable functions** — top-level `def` declarations never called anywhere in
  the module graph.

```bash
zebra check selfhost/codegen.zbr
# → warning: union arm 'Type_.str_slice' never matched
# → warning: def 'genDebugPrint' never called
```

Output goes to stdout, one warning per line.  Exit code 0 = no warnings.

### `zebra debug` — DAP integration

`zebra debug file.zbr` compiles the program and launches it under `lldb-dap`, exposing
the Debug Adapter Protocol on a local socket.  IDE clients (VS Code, ZebraIDE) connect
to this socket for breakpoints, stepping, and variable inspection.

See `docs/DEBUGGING.md` for:
- VS Code launch configuration
- ZebraIDE's built-in Debug button
- `--listen PORT` mode for custom integrations
- LLDB-DAP discovery / `LLDB_DISABLE_PYTHON` workarounds

### Compiler flags reference

| Flag | Effect |
|------|--------|
| `--emit-zig` | Write Zig source to stdout instead of compiling |
| `--output-dir DIR` | Write generated Zig files to `DIR/` |
| `--turbo` | Strip all contract checks (`require`/`ensure`/`invariant`) |
| `--gui-backend=libui_ng` | Use native OS controls (default: stub) |
| `--gui-backend=imgui` | Use Dear ImGui backend |
| `--gui-backend=tui` | Use terminal UI backend |
| `--zig-backend file.zbr` | Delegate to `zebra-bootstrap.exe` (Zig compiler) |
| `--listen PORT` | (debug mode) expose DAP on `PORT` instead of launching IDE |

---

## 30. GUI programming

Zebra has a built-in GUI API with an **MVU (Model-View-Update)** architecture.
Three backends are available: native OS controls via **libui-ng**, a terminal
UI via **ZigZag TUI**, and Dear ImGui (OpenGL/GLFW) for GPU-accelerated rendering.

### Running a GUI program

```bash
zebra --gui-backend=libui_ng myapp.zbr  # Native OS controls (Win32/GTK3/Cocoa) — recommended
zebra --gui-backend=tui      myapp.zbr  # Terminal UI (ZigZag — no GPU, no dependencies)
zebra --gui-backend=glfw     myapp.zbr  # Dear ImGui (OpenGL/GLFW)
zebra myapp.zbr                         # Default: stub backend (prints to stderr, for tests)
```

The compiler auto-scaffolds a `zig build` project next to the generated `.zig`
file (e.g. `myapp_gui_libui_ng/`, `myapp_gui_tui/`, `myapp_gui/`) and invokes
`zig build run`.  The project directory is reused on subsequent runs.

**libui-ng backend notes:**
- Native controls: Win32 on Windows, GTK3 on Linux, Cocoa on macOS.
- Retained-mode internally: Zebra's immediate-mode API is translated to a widget
  tree on frame 0 and updated on subsequent events. Widget order must be stable.
- `sameLine()`, `treeNode()`, table/tree APIs are no-ops (use `beginHBox` for
  horizontal layout).
- Low-level draw calls (`ll.*`) are no-ops.

**TUI backend notes:**
- Renders in the terminal using ANSI escape codes (alternate screen).
- Press `q`, `Q`, or `Escape` to quit.
- `sameLine()` has no visual effect (widgets stack vertically).
- Low-level draw calls (`ll.*`) are no-ops.

### `Gui.run` — MVU form (recommended)

```zebra
Gui.run(title: str, width: int, height: int, init, update, view)
```

**MVU (Model-View-Update)** keeps state explicit and transitions testable.

```zebra
struct Counter
    var count: int

union Msg
    inc
    dec
    reset

def makeCounter(): Counter
    return Counter(count: 0)

def update(model: Counter, msg: Msg): Counter
    branch msg
        on Msg.inc   return Counter(count: model.count + 1)
        on Msg.dec   return Counter(count: model.count - 1)
        on Msg.reset return Counter(count: 0)

def view(g: Gui, model: Counter)
    g.text("Count: " + model.count.toString())
    g.separator()
    if g.button("+"):  g.send(Msg.inc)
    if g.button("-"):  g.send(Msg.dec)
    if g.button("Reset"):  g.send(Msg.reset)

def main()
    Gui.run("Counter", 400, 200, makeCounter, update, view)
```

- `init` — called once, returns the initial model value
- `update(model, msg)` — pure function: old model + message → new model
- `view(g, model)` — renders widgets; call `g.send(msg)` to queue messages
- Messages are queued during `view` and processed after it returns

### `Gui.run` — frame-callback form (ImGui/TUI only)

```zebra
Gui.run(title: str, width: int, height: int, frame: def(g: Gui))
```

Calls `frame` once per rendered frame.  Use a `capture` block to keep state
across frames.

**Not supported** in the libui-ng retained-mode backend — libui-ng events are
callback-driven, not frame-polled.  For portable code, prefer MVU.

### MVU vs frame-callback — when to use each

| | MVU | Frame-callback |
|---|---|---|
| **State model** | Explicit typed struct — immutable transitions | Anything (mutable via `capture`) |
| **Testability** | High — `update` is a pure function | Low — state lives in closure |
| **Backend support** | All backends | ImGui + TUI only |
| **Best for** | Production apps, anything you want to test | Quick prototypes, IDE-style tools |
| **State that spans frames** | In the model struct | In a `capture` block |

**Use MVU when:**
- You want testable UI logic (test `update` without a GUI).
- You need libui-ng (native OS controls) or cross-backend portability.
- The app has clear, discrete state transitions.

**Use frame-callback when:**
- You're building a dev tool or ImGui-style editor where state is naturally mutable.
- You need the `CodeEditor` widget or low-level draw calls (`g.ll.*`), which are
  ImGui-only.
- You want minimal boilerplate for a quick prototype.

### Widget reference

| Call                                       | Returns  | Notes                                      |
|--------------------------------------------|----------|--------------------------------------------|
| `g.text(s)`                                | void     | Text label                                 |
| `g.button(label)`                          | bool     | True on click                              |
| `g.checkbox(label, value)`                 | bool     | New checked state                          |
| `g.slider(label, value, min, max)`         | float    | Drag slider (float range)                  |
| `g.input(label, value)`                    | str      | Single-line text input                     |
| `g.inputMultiline(label, value, w, h)`     | str      | Multi-line text area                       |
| `g.progressBar(label, value)`              | void     | Progress bar; `value` is 0.0–1.0           |
| `g.combobox(label, items, selected)`       | int      | Drop-down; `items: List(str)`, returns new index |
| `g.spinbox(label, value, min, max)`        | int      | Integer spinner with bounds                |
| `g.separator()`                            | void     | Horizontal rule                            |
| `g.sameLine()`                             | void     | Next widget on same line (ImGui/TUI only)  |
| `g.spacing()`                              | void     | Extra vertical space                       |
| `g.indent()` / `g.unindent()`             | void     | Indentation level                          |
| `g.panel(label, callback)`                 | void     | Collapsible child window (ImGui only)      |
| `g.beginPanel(id)` / `g.endPanel(id)`     | void     | libui-ng titled group box                  |
| `g.window(label, callback)`                | void     | Floating sub-window (ImGui only)           |
| `g.textColored(s, r, g, b, a)`            | void     | Colored text label                         |
| `g.selectable(label, selected)`            | bool     | Selectable list item                       |
| `g.send(msg)`                              | void     | Dispatch a message (MVU only)              |

### Layout boxes (libui-ng / stub / TUI)

```zebra
g.beginHBox("row", stretch: false)
    g.button("Left")
    g.button("Right")
g.endHBox()

# With `using` desugaring:
using g.hbox("row", false)
    g.button("Left")
    g.button("Right")
```

| Call                                | Notes                                  |
|-------------------------------------|----------------------------------------|
| `g.beginHBox(id, stretch)` / `g.endHBox()` | Horizontal container           |
| `g.beginVBox(id, stretch)` / `g.endVBox()` | Vertical container             |
| `g.hbox(id, stretch)` / `g.vbox(id, stretch)` | Factory for `using` desugaring |

### File dialogs (libui-ng only; stub/TUI return nil)

```zebra
if g.button("Open…")
    var p = g.openFile()
    if p as path
        g.send(Msg.opened(path))

if g.button("Alert")
    g.msgBox("Info", "Operation complete.")
```

| Call                               | Returns | Notes                                  |
|------------------------------------|---------|----------------------------------------|
| `g.openFile()`                     | `str?`  | System open-file dialog; nil on cancel |
| `g.saveFile()`                     | `str?`  | System save-file dialog; nil on cancel |
| `g.openFolder()`                   | `str?`  | System open-folder dialog              |
| `g.msgBox(title, msg)`             | void    | Modal informational dialog             |
| `g.msgBoxError(title, msg)`        | void    | Modal error dialog                     |

File dialogs must be **button-gated** — call them only when a button press has
been detected, never unconditionally from `view()`.

### `CodeEditor` widget

```zebra
var editor = CodeEditor.forZebra()        # factory — Zebra syntax preset
editor.setText(File.read("main.zbr"))
editor.setReadOnly(false)

# Inside view():
editor.render(g, "##editor", 700, 500)
var src = editor.getText()
editor.setErrorMarkers(diags)             # diags: List(IDEDiagnostic)
```

### Persistent frame state with `capture` (frame-callback form)

```zebra
Gui.run("IDE", 1000, 750, def(g: Gui)
    capture
        var editor = CodeEditor.forZebra()
        var inited: bool = false
    if not inited
        editor.setText(File.read("main.zbr"))
        inited = true
    editor.render(g, "##ed", 800, 600)
)
```

### Backend isolation

The GUI layer uses a `_GuiBackend` fn-pointer struct internally.  Swap the
backend by implementing the fn-ptr slots and changing `_gui_active_backend`
— no changes to user Zebra code required.

Available backends: `stub` (no-op, for tests), `libui_ng` (native OS controls),
`glfw`/`sdl2`/`dx12` (Dear ImGui), `tui` (ZigZag terminal).

---

## 31. Standard library API reference

### `sys` — process / OS

| Call                | Returns           | Notes                                        |
|---------------------|-------------------|----------------------------------------------|
| `sys.args()`        | `List(str)`       | Raw command-line arguments                   |
| `sys.exit(code)`    | noreturn          | Exit with given code                         |
| `sys.err(msg)`      | void              | Write to stderr (no newline)                 |
| `sys.errln(msg)`    | void              | Write to stderr + newline                    |
| `sys.getenv(name)`  | `str?`            | Environment variable or nil                  |
| `sys.run(argv)`     | `SysRunResult`    | Spawn subprocess; `{stdout, stderr, exit_code}` |
| `sys.sleep(ms)`     | void              | Sleep for `ms` milliseconds                  |
| `sys.readLine()`    | `str?`            | Read one line from stdin (strips `\n`); nil on EOF |

### `File` — file I/O (static)

| Call                          | Returns       | Notes                                         |
|-------------------------------|---------------|------------------------------------------------|
| `File.read(path)`             | `str`         | Read entire file as string                     |
| `File.write(path, data)`      | void          | Write string to file (creates or truncates)    |
| `File.append(path, data)`     | void          | Append string to file                          |
| `File.readLines(path)`        | `List(str)`   | Read file as list of lines                     |
| `File.exists(path)`           | `bool`        | True if file exists                            |
| `File.delete(path)`           | void          | Delete file (no-op if missing)                 |
| `File.rename(src, dst)`       | void          | Rename/move file                               |
| `File.copy(src, dst)`         | void          | Copy file                                      |
| `File.listDir(path)`          | `List(str)`   | List entry names in directory                  |
| `File.modtime(path)`          | `int`         | Modification time (ms since epoch); -1 missing |

### `Dir` — directory operations (static)

| Call                  | Returns | Notes                                      |
|-----------------------|---------|--------------------------------------------|
| `Dir.create(path)`    | void    | Create directory (no-op if exists)         |
| `Dir.createAll(path)` | void    | Create directory tree                      |
| `Dir.delete(path)`    | void    | Delete empty directory                     |
| `Dir.deleteAll(path)` | void    | Delete directory tree recursively          |
| `Dir.exists(path)`    | `bool`  | True if directory exists                   |

### `Arg` — command-line argument parsing

```zebra
var args = Arg.parse()
var path     = args.positional(0)            # str? — nth positional (0-based)
var verbose  = args.flag("--verbose")        # bool
var output   = args.option("--out", "")      # str with default
var present  = args.contains("--dry-run")    # bool
```

### `Math` — mathematics

| Call                            | Returns  |
|---------------------------------|----------|
| `Math.sin/cos/tan(x)`           | float    |
| `Math.asin/acos/atan(x)`        | float    |
| `Math.atan2(y, x)`              | float    |
| `Math.sqrt/exp/log/log2/log10(x)` | float  |
| `Math.floor/ceil/round/trunc(x)` | float   |
| `Math.pow(x, y)`                | float    |
| `Math.abs(x)`                   | numeric  |
| `Math.min(a, b)` / `Math.max(a, b)` | numeric |
| `Math.PI`, `Math.E`, `Math.TAU` | float constants |

### `Json` — JSON values

| Call                                 | Returns       | Notes                                   |
|--------------------------------------|---------------|-----------------------------------------|
| `Json.parse(src)`                    | `JsonValue?`  | Parse JSON to a tagged union value      |
| `Json.parseStrict(T, src)`           | `?T`          | Strict parse to `@reflectable class T`  |
| `Json.stringify(v)`                  | `str`         | Serialise a JsonValue                   |
| `Json.object()` / `Json.array()`     | `JsonValue`   | Empty object/array constructors         |
| `v.getStr/getInt/getFloat/getBool(k)` | typed       | Typed field access on a JsonValue       |

### `Hash` — hashing

| Call                              | Returns | Notes                              |
|-----------------------------------|---------|-------------------------------------|
| `Hash.sha256(s)`                  | `str`   | Hex digest                          |
| `Hash.sha512(s)`                  | `str`   |                                     |
| `Hash.md5(s)`                     | `str`   |                                     |
| `Hash.blake3(s)`                  | `str`   |                                     |
| `Hash.hmac256(msg, key)`          | `str`   | HMAC-SHA256 hex                     |

### `Random` — random numbers

| Call                              | Returns | Notes                              |
|-----------------------------------|---------|-------------------------------------|
| `Random.randInt(low, high)`       | int     | `[low, high]`, inclusive            |
| `Random.randFloat()`              | float   | `[0.0, 1.0)`                        |
| `Random.randBool()`               | bool    |                                     |
| `Random.bytes(n)`                 | List(byte) | Random bytes                     |
| `Random.seed(s)`                  | void    | Seed the PRNG                       |

### `Regex` — regular expressions

| Call                              | Returns        | Notes                              |
|-----------------------------------|----------------|-------------------------------------|
| `Regex.compile(pattern)`          | `Regex`        | Compile a pattern (Thompson NFA)    |
| `re.test(s)`                      | bool           | Match anywhere in `s`               |
| `re.match(s)`                     | bool           | Match from start of `s`             |
| `re.find(s)`                      | str            | First matching substring            |
| `re.findAll(s)`                   | `[]str`        | All non-overlapping matches         |
| `re.replace(s, repl)`             | str            | Replace all matches with `repl`     |
| `re.groups(s)`                    | `[]str`        | Capture groups: index 0 = full match, 1+ = groups |

### `DateTime` — date/time

**Constructors**

| Call                              | Returns    | Notes                               |
|-----------------------------------|------------|--------------------------------------|
| `DateTime.now()`                  | `DateTime` | Current wall-clock time              |
| `DateTime.fromEpoch(ms)`          | `DateTime` | From milliseconds since Unix epoch   |
| `DateTime.of(y,m,d)`             | `DateTime` | Midnight UTC on that date            |
| `DateTime.of(y,m,d,h,min,s)`     | `DateTime` | Full UTC date+time                   |

**Field access** (computed from `epoch_ms`)

| Field        | Returns | Notes               |
|--------------|---------|----------------------|
| `dt.year`    | int     | Gregorian year       |
| `dt.month`   | int     | 1–12                 |
| `dt.day`     | int     | 1–31                 |
| `dt.hour`    | int     | 0–23                 |
| `dt.minute`  | int     | 0–59                 |
| `dt.second`  | int     | 0–59                 |
| `dt.weekday` | int     | 1=Mon … 7=Sun (ISO)  |

**Methods**

| Call                              | Returns        | Notes                                        |
|-----------------------------------|----------------|-----------------------------------------------|
| `dt.inZone(zone)`                 | `DateTime`     | Shift to named IANA timezone (see below)      |
| `dt.inCalendar(cal)`              | `CalendarView` | Calendar-specific lens (Gregorian, Hebrew, …) |
| `dt.addDays(n)`                   | `DateTime`     |                                               |
| `dt.addHours(n)`                  | `DateTime`     |                                               |
| `dt.addMinutes(n)`                | `DateTime`     |                                               |
| `dt.addSeconds(n)`                | `DateTime`     |                                               |
| `dt.addMonths(n)`                 | `DateTime`     |                                               |
| `dt.addYears(n)`                  | `DateTime`     |                                               |
| `dt.toEpoch()`                    | int            | Milliseconds since Unix epoch                 |
| `dt.toIso8601()`                  | str            | e.g. `"2024-03-15T14:30:45"`                 |
| `dt.format(pattern)`              | str            | `"yyyy-MM-dd HH:mm:ss"` etc.                  |
| `dt.daysBetween(other)`           | int            |                                               |
| `dt.secondsBetween(other)`        | int            |                                               |

**`dt.inZone(zone)` — IANA timezone support**

Returns a new `DateTime` whose `epoch_ms` is shifted by the UTC offset of the
named IANA zone, accounting for DST rules where applicable.  Unknown zone names
fall back to UTC (no crash).  The zone table is dead-stripped by the linker when
`inZone` is never called — **zero binary-size cost if unused**.

```zebra
var epoch = DateTime.fromEpoch(0)
var ny    = epoch.inZone("America/New_York")
print ny.year   # 1969
print ny.hour   # 19   (UTC-5 winter)

var summer = DateTime.of(2024, 7, 4, 12, 0, 0)
var ny_edt = summer.inZone("America/New_York")
print ny_edt.hour   # 8   (UTC-4 summer DST)
```

Supported DST rules: US (post-2007 EESA), EU, AU Eastern, New Zealand.
Representative zones (≈ 75 total):

| Zone                    | Std offset | DST          |
|-------------------------|------------|---------------|
| `"UTC"`                 | UTC+0      | no DST        |
| `"America/New_York"`    | UTC-5      | US DST (−4)   |
| `"America/Chicago"`     | UTC-6      | US DST (−5)   |
| `"America/Denver"`      | UTC-7      | US DST (−6)   |
| `"America/Los_Angeles"` | UTC-8      | US DST (−7)   |
| `"Europe/London"`       | UTC+0      | EU DST (+1)   |
| `"Europe/Paris"`        | UTC+1      | EU DST (+2)   |
| `"Asia/Tokyo"`          | UTC+9      | no DST        |
| `"Australia/Sydney"`    | UTC+10     | AU DST (+11)  |
| `"Pacific/Auckland"`    | UTC+12     | NZ DST (+13)  |

### `Http` / `HttpResponse`

| Call                                          | Returns         |
|-----------------------------------------------|-----------------|
| `Http.get(url)`                               | `HttpResponse?` |
| `Http.post(url, body)`                        | `HttpResponse?` |
| `Http.json(url, json)`                        | `HttpResponse?` |
| `Http.postJson(url, json)`                    | `HttpResponse?` |
| `HttpResponse.ok(body)` / `notFound(body)` / etc. | `HttpResponse` |
| `r.status / r.text / r.headers`               | mixed           |

### `Ws` — WebSocket client and server

`Ws.connect(url)` opens a WebSocket connection to `ws://` or `wss://` URLs.
`Ws.serve(port, handler)` runs a plain-TCP WebSocket server on `port`, calling
`handler` once per accepted connection. `recv()` blocks on the calling thread.

```zebra
# ── client ──────────────────────────────────────────────────────────────────
var conn = Ws.connect("ws://echo.example.com/ws")
if conn as ws
    ws.send("hello")
    var msg = ws.recv()
    if msg as m
        print(m)
    ws.close()

# ── server ───────────────────────────────────────────────────────────────────
Ws.serve(8765, def(ws: WsConn)
    var msg = ws.recv()
    if msg as m
        ws.send("echo: " + m)
    ws.close()
)
```

| Call                              | Returns      | Notes                                        |
|-----------------------------------|--------------|-----------------------------------------------|
| `Ws.connect(url)`                 | `WsConn?`    | `ws://` or `wss://`; nil on handshake failure |
| `Ws.serve(port, handler)`         | void         | Accepts in a loop; calls `handler(WsConn)` per client |
| `ws.send(msg)`                    | void         | Send a UTF-8 text frame (RFC 6455)            |
| `ws.recv()`                       | `str?`       | Block until a message arrives; nil on close/error |
| `ws.close()`                      | void         | Send close frame and shut down the connection |

**Notes:**
- `wss://` (TLS) is supported for `Ws.connect`; `Ws.serve` uses plain TCP (put a reverse proxy for TLS serving).
- Client→server frames are automatically masked (RFC 6455 §5.3).
- Pings from the server are answered automatically with pong.

### Networking — `Tcp`, `Udp`, `Net`

| Call                              | Returns         | Notes                              |
|-----------------------------------|-----------------|-------------------------------------|
| `Tcp.connect(host, port)`         | `TcpConn?`      |                                     |
| `Tcp.serve(port, handler)`        | void            | Accepts in a loop; calls `handler(TcpConn)` per client |
| `Net.resolve(host)`               | `[]str`         | DNS lookup                          |

#### `Udp` — datagram sockets

```zebra
# Send side: unbound socket (OS picks ephemeral port)
var s: UdpSocket = Udp.socket()
s.send("127.0.0.1", 9000, "hello")
s.close()

# Receive side: bind to a known port
var r: UdpSocket = Udp.bind(9000)
var data: str = r.recv(4096)   # returns up to 4096 bytes as str
r.close()
```

| Call                              | Returns     | Notes                                     |
|-----------------------------------|-------------|-------------------------------------------|
| `Udp.socket()`                    | `UdpSocket` | Unbound; OS picks ephemeral source port   |
| `Udp.bind(port)`                  | `UdpSocket` | Bound to `port` on all interfaces         |
| `sock.send(host, port, data)`     | void        | `host` must be an IP literal, not a name  |
| `sock.recv(max_bytes)`            | str         | Blocks until a datagram arrives           |
| `sock.close()`                    | void        |                                           |

- `Udp.socket()` and `Udp.bind()` both return a `UdpSocket`; the difference is whether the OS binds a listening port.
- `send` requires an IP-address literal (`"127.0.0.1"`, `"::1"`); use `Net.resolve` first if you have a hostname.

### `Csv` — RFC 4180 CSV

| Call                              | Returns      | Notes                              |
|-----------------------------------|--------------|-------------------------------------|
| `Csv.parse(src)`                  | `CsvTable`   | Headers + rows                     |
| `t.row(i).field(name)`            | str          | By column name                     |
| `CsvWriter()`                     | `CsvWriter`  | Builder for output                 |

### `Mime`, `Uri`, `Terminal`, `Timer`

| Call                              | Returns      | Notes                                       |
|-----------------------------------|--------------|----------------------------------------------|
| `Mime.lookup(filename)`           | str          | MIME type by extension                       |
| `Uri.parse(s)`                    | `UriResult?` | Scheme/host/path/query/fragment              |
| `Terminal.clearScreen()` etc.     | void         | ANSI helpers                                 |
| `Timer.start()`                   | `Timer`      | `t.elapsedMs()` for measurement              |

### `Compress` — gzip compression

| Call                    | Returns      | Notes                              |
|-------------------------|--------------|------------------------------------|
| `Compress.gzip(data)`   | `List(byte)` | gzip compress a string             |
| `Compress.gunzip(data)` | `List(byte)` | gzip decompress                    |

### `Log` — structured logging

| Call                              | Returns | Notes                                        |
|-----------------------------------|---------|----------------------------------------------|
| `Log.info(msg)`                   | void    | Timestamped info line to stderr              |
| `Log.warn(msg)`                   | void    |                                              |
| `Log.error(msg)`                  | void    |                                              |
| `Log.json(level, msg, data)`      | void    | JSON-lines format: `{"level":…,"msg":…,…}`   |
| `Log.setFile(path)`               | void    | Redirect subsequent log output to a file     |

### `Crypto` — cryptographic primitives

| Call                                      | Returns | Notes                             |
|-------------------------------------------|---------|-----------------------------------|
| `Crypto.encrypt(plaintext, key)`          | str     | AES-256-GCM; base64-encoded output |
| `Crypto.decrypt(ciphertext, key)`         | `str?`  | Returns nil on auth failure        |
| `Crypto.deriveKey(password, salt)`        | str     | HKDF-SHA256; 32-byte hex output   |

### `Atomic(T)` — lock-free atomic cells

```zebra
var counter = Atomic(int)(0)
counter.add(1)
var v = counter.load()
```

| Call                   | Returns | Notes                           |
|------------------------|---------|---------------------------------|
| `Atomic(T)(init)`      | `Atomic(T)` | Create cell with initial value |
| `a.load()`             | T       | Atomic read (seq-cst)           |
| `a.store(v)`           | void    | Atomic write (seq-cst)          |
| `a.add(n)` / `sub(n)`  | T       | Fetch-and-add; returns **old** value |
| `a.swap(v)`            | T       | Atomic exchange; returns old    |

Supported types: `int`, `bool`.

All operations use **sequentially-consistent** memory ordering (Zig
`.seq_cst`).  This is the safest and least surprising choice; for
high-throughput scenarios where relaxed ordering would suffice, use `zig"…"`
to call Zig's `@atomicRmw` directly.

**`Atomic` vs `Chan`:**

| | `Atomic(T)` | `Chan(T)` |
|---|---|---|
| Best for | Shared counters, flags, one-shot signals | Producer/consumer pipelines |
| Blocking | Never | `send` blocks when full; `recv` blocks when empty |
| Ordering | Implicit seq-cst | Message order preserved |

```zebra
# Shared counter across threads:
var total = Atomic(int)(0)
sys.go(lambda  var _ = total.add(1) )
sys.go(lambda  var _ = total.add(1) )
sys.sleep(50)
print total.load()   # 2 (both increments visible)

# One-shot "done" flag:
var done = Atomic(bool)(false)
sys.go(lambda
    doWork()
    done.store(true)
)
while not done.load()
    sys.sleep(10)
```

### `ThreadPool(n)` — bounded worker pool

```zebra
var pool = ThreadPool(4)
pool.submit(def() doWork())
pool.wait()                    # blocks until all submitted tasks complete
```

| Call                    | Notes                                         |
|-------------------------|-----------------------------------------------|
| `ThreadPool(n)`         | Create pool with `n` worker threads           |
| `pool.submit(lambda)`   | Queue a zero-arg lambda for async execution   |
| `pool.wait()`           | Block until all queued tasks finish           |

### `Path` — path utilities

| Call                          | Returns | Notes                              |
|-------------------------------|---------|-------------------------------------|
| `Path.join(a, b)`             | str     | Join path segments (OS separator)   |
| `Path.dirname(p)`             | str     | Parent directory component          |
| `Path.basename(p)`            | str     | Filename without directory          |
| `Path.ext(p)` / `extension(p)` | str   | Extension including dot (e.g. `.zig`) |
| `Path.stem(p)`                | str     | Basename without extension          |
| `Path.isAbsolute(p)`          | bool    |                                     |
| `Path.absolute(p)`            | str     | Resolve relative path to absolute   |

### `Http.serve` — HTTP server

```zebra
Http.serve(8080, def(req: HttpRequest, res: HttpResponse)
    if req.path == "/hello"
        res.text("Hello, Zebra!")
    else
        res.notFound("not found")
)
```

### `Progress` — terminal progress bars

```zebra
var pb = Progress.bar(100, "loading")
for item in items
    pb.tick()
pb.done()
```

### `Reflect` — Tier 1 reflection

```zebra
Reflect.className(obj)               # str — class name
Reflect.fieldNames(obj)              # []str — field names
Reflect.fieldTypes(obj)              # []str — field type strings
```

See §25 for `@reflectable` + `Json.parseStrict` (Tier 3).

---

## 32. SIMD vector types

Zebra supports SIMD vector types using the `{elemType}x{lanes}` naming
convention (Rust portable-simd style).  They compile directly to Zig
`@Vector(N, T)` and are supported on x86-64 (SSE2/AVX2/AVX-512) and
AArch64 (NEON) via Zig's automatic LLVM lowering.

### Type names

| Zebra type   | Zig type          | Typical width      |
|--------------|-------------------|--------------------|
| `f32x4`      | `@Vector(4, f32)` | 128-bit (SSE/NEON) |
| `f32x8`      | `@Vector(8, f32)` | 256-bit (AVX2)     |
| `f32x16`     | `@Vector(16, f32)`| 512-bit (AVX-512)  |
| `f16x8`      | `@Vector(8, f16)` |                    |
| `i32x4`      | `@Vector(4, i32)` | 128-bit            |
| `i16x16`     | `@Vector(16, i16)`|                    |
| `u8x32`      | `@Vector(32, u8)` | 256-bit            |
| `i64x2`      | `@Vector(2, i64)` |                    |

Element types: `f16`, `f32`, `f64`, `i8`, `i16`, `i32`, `i64`,
`u8`, `u16`, `u32`, `u64`.  Any positive lane count is accepted.

### Operations

```zebra
# Constructor — list each lane value
var a: f32x8 = f32x8(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0)

# Splat — broadcast a scalar to all lanes
var zero: f32x8 = f32x8.splat(0.0)

# Load from a slice — slice must have at least N elements
var data = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
var v: f32x8 = f32x8.load(data)

# Native arithmetic — element-wise, same type
var b: f32x8 = a + zero
var c: f32x8 = a * a
var d: f32x8 = a - b
var e: f32x8 = a / f32x8.splat(2.0)

# Reduction — collapse to scalar
var s:  float32 = a.sum()          # @reduce(.Add, a)
var mx: float32 = a.max_element()  # @reduce(.Max, a)
var mn: float32 = a.min_element()  # @reduce(.Min, a)

# Dot product
var dp: float32 = a.dot(b)         # @reduce(.Add, a * b)

# Type annotations use the SIMD type name directly
var iv: i32x4 = i32x4(10, 20, 30, 40)
var isum: int32 = iv.sum()
```

### Notes

- SIMD types use Zig/C short names (`f32`, `i16`) not Zebra long names
  (`float32`, `int16`) as the element prefix.
- Arithmetic operators (`+`, `-`, `*`, `/`) are element-wise.
- Comparison and logical operators on SIMD vectors are not yet supported.
- Selfhost parity (for `selfhost/*.zbr` round-trip) is tracked as a future sprint.

### CPU target and SIMD width

By default Zebra compiles for the SSE2 baseline (`x86_64` generic target), which
runs on any x86-64 machine but limits SIMD operations to 128-bit (`f32x4`, `i32x4`).
Wider types like `f32x8` or `f32x16` compile and run at baseline, but LLVM
decomposes them into multiple narrower instructions — correct, but not optimal.

Use `--cpu` to control the target CPU:

```bash
zebra file.zbr                       # SSE2 baseline — always correct
zebra --cpu=native file.zbr          # host CPU features — fastest, but host-only binary
zebra --cpu=x86_64+avx2 file.zbr     # explicit AVX2 — optimal f32x8; runs on any AVX2 machine
zebra --cpu=x86_64+avx512f file.zbr  # AVX-512 — SIGILL on AVX2/SSE2 machines
```

**SIGILL hazard**: compiling with a wide CPU target (`+avx512f`) and running on a
narrower machine (AVX2 or SSE2) produces `SIGILL` at runtime — Zig/LLVM bakes the
instruction set into the binary at compile time.  `--cpu native` is safe only when
the binary will run on the same machine (or an identical micro-architecture) that
compiled it.

Runtime CPU dispatch (detect features at startup, select best kernel) is a post-1.0
item tracked in `NEXT_STEPS.md §9`.

## 33. Test module — `zebra test`

Zebra has a built-in test runner invoked with `zebra test <file.zbr>`.

### Writing tests

Any top-level zero-parameter function whose name starts with `test_` is
automatically discovered and run:

```zebra
def test_addition()
    assert_eq 1 + 1, 2
    assert_ne 0, 1

def test_strings()
    assert_eq "hello", "hello"
    assert_ne "foo", "bar"

def test_booleans()
    assert_true  5 > 3
    assert_false 1 > 2
    assert_true  not false
```

### Assert statements

| Statement | Meaning |
|-----------|---------|
| `assert_eq <lhs>, <rhs>` | Fail unless `lhs == rhs` |
| `assert_ne <lhs>, <rhs>` | Fail unless `lhs != rhs` |
| `assert_true <expr>` | Fail unless `expr` is true |
| `assert_false <expr>` | Fail unless `expr` is false |

Each assert throws `error.ZebraError` on failure with a descriptive message.
Test functions are automatically typed `anyerror!void` — no `throws` needed.

### Running tests

```bash
zebra test path/to/test_file.zbr
```

Output:
```
PASS: test_addition
PASS: test_strings
PASS: test_booleans

3 passed, 0 failed
```

Exit code is `0` on all-pass, `1` if any test failed. Each test runs
independently; a failure in one test does not abort the others.

### Filtering tests with `@tag`

Apply one or more string tags to a test function:

```zebra
@tag("unit", "math")
def test_addition()
    assert_eq 1 + 1, 2

@tag("integration")
def test_database()
    assert_true db_ping()
```

Run only the tests whose tags include a given value:

```bash
zebra test --tag unit path/to/test_file.zbr
```

**Automatic tags** are applied without any annotation:

| Auto-tag | Applies to |
|----------|-----------|
| File stem | All tests in the file (e.g. `foo_test` for `foo_test.zbr`) |
| Class/struct name | `static def test_*()` methods inside that class/struct |

So given a file `math_test.zbr` containing:

```zebra
class Arithmetic
    @tag("unit")
    static def test_add()
        assert_eq 2 + 2, 4
```

Running `zebra test --tag math_test` runs every test in the file; running
`--tag Arithmetic` runs only tests inside the `Arithmetic` class; running
`--tag unit` runs only tests explicitly tagged `"unit"`.

### Notes

- Test files should not define `def main()` — the test runner generates its
  own entry point automatically.
- `def main()` is silently suppressed when compiling in test mode.
- Both the Zig backend (`--zig-backend`) and the selfhost pipeline support
  `zebra test`.

## 34. Tuple / multi-return

Functions can return multiple values via a tuple return type.

```zebra
def minmax(a: int, b: int): (int, int)
    if a < b
        return (a, b)
    return (b, a)

def main()
    # Positional destructure
    var (lo, hi) = minmax(7, 3)
    print lo   # 3
    print hi   # 7

    # Hold as a tuple value, then index
    var t = minmax(1, 9)
    print t.0  # 1
    print t.1  # 9
```

### Rules

- Tuple return type: `(T1, T2, …)` with two or more elements.
- Tuple literal: `(expr1, expr2, …)` — same syntax as grouped-expression but with a comma.
- Positional destructure: `var (x, y) = f()` — binds each name to the matching element.
- Index access: `t.0`, `t.1` — integer literal after `.`, zero-based.
- Mixed types are supported: `(str, int)`, `(float, bool)`, etc.
- `List((T1, T2))` stores tuples in a list; iterate with `for a, b in list` (see §10).
  - The list variable must have an explicit `List((T1, T2))` type annotation — inferred types do not trigger destructuring.
  - Arity must match: `for a, b in list` where `list` holds 3-tuples is a compile error.

### Zig mapping

`(T1, T2)` maps to `struct { T1, T2 }` (Zig anonymous tuple struct).
`(a, b)` maps to `.{ a, b }`.
`t.0` maps to `t.@"0"`.

## 35. Channels and threads — `Chan(T)` + `sys.go()`

### Chan(T)

`Chan(T)` is a thread-safe buffered channel. Construct with a capacity:

```zebra
var ch: Chan(int) = Chan(int)(4)   # capacity 4
```

| Method | Returns | Description |
|--------|---------|-------------|
| `ch.send(val)` | `void` | Send a value; blocks when full |
| `ch.recv()` | `int?` | Receive a value; blocks when empty; `nil` when closed + empty |
| `ch.close()` | `void` | Signal no more values; recv drains remaining then returns nil |

The `<-` operator is syntactic sugar:

```zebra
ch <- 42          # send: ch.send(42)
var v: int? = nil
v <- ch           # recv: v = ch.recv()
```

### sys.go()

`sys.go(lambda)` spawns a fire-and-forget background thread:

```zebra
sys.go(lambda
    # runs on a new thread; captures surrounding vars
    ch.send(1)
    ch.send(2)
    ch.close()
)
```

The lambda can capture variables from the enclosing scope. Captured variables
are copied into the thread closure at spawn time.

### Producer / consumer pattern

```zebra
var ch: Chan(int) = Chan(int)(4)

sys.go(lambda
    for i in 1..5
        ch.send(i)
    ch.close()
)

var sum: int = 0
var done: bool = false
while not done
    var v: int? = ch.recv()
    if v as n
        sum = sum + n
    else
        done = true
# sum == 15
```

### Notes

- `Chan(T)` uses page-allocator; do not use inside short-lived `allocate` blocks.
- Closing an already-closed channel is a no-op.
- Sending to a closed channel panics at runtime.
- `sys.go()` accepts any zero-parameter lambda (with or without captures).
- Threads are detached — no join mechanism yet; use a channel to signal completion.

### ThreadPool

`ThreadPool` runs a bounded set of worker threads and distributes submitted tasks among them.

```zebra
var pool: ThreadPool = ThreadPool(4)   # 4 worker threads
var counter: Atomic(int) = Atomic(int)(0)

var i: int = 0
while i < 8
    pool.submit(def()
        capture
            var counter: Atomic(int) = counter
        var _: int = counter.add(1)
    )
    i = i + 1

pool.wait()              # blocks until all submitted tasks complete
print counter.load()     # 8
```

**Notes:**
- `ThreadPool` is a plain type (not generic); the thread count is a constructor argument.
- `pool.submit(lambda)` accepts any zero-parameter Zebra lambda (with or without captures).
- `pool.wait()` blocks until all in-flight tasks finish.
- **Submit after `wait` is supported** — calling `submit` after `wait` returns queues more
  work; a subsequent `wait` blocks on those new tasks.  The pool is reusable.
- Workers are spawned at construction; they run until the pool is garbage-collected.
- `ThreadPool` uses `page_allocator`; do not use inside short-lived `allocate` blocks.
- **Task panics are not caught** — if a submitted lambda panics, the worker thread
  terminates.  Design tasks to not panic (validate inputs before submitting).

**`ThreadPool` vs `sys.go()`:**

| | `ThreadPool(n)` | `sys.go(lambda)` |
|---|---|---|
| Worker count | Fixed `n` | Unbounded (new thread per call) |
| Backpressure | Natural — submit blocks when all workers are busy | None — each call spawns immediately |
| Result collection | Via `Atomic` or `Chan` | Via `Chan` |
| Best for | CPU-bound parallel work | Fire-and-forget I/O tasks |

```zebra
# Pattern: ThreadPool + Chan to collect results
var ch: Chan(int) = Chan(int)(8)
var pool: ThreadPool = ThreadPool(4)

for i in 0..8
    pool.submit(def()
        capture
            var idx: int = i
            var ch: Chan(int) = ch
        ch.send(idx * idx)
    )

pool.wait()
ch.close()

var sum = 0
var done = false
while not done
    var v: int? = ch.recv()
    if v as n
        sum = sum + n
    else
        done = true
print sum    # 0+1+4+9+16+25+36+49 = 140
```

## 36. Type aliases with constraints

A `type` declaration creates a named alias for a base type, optionally with a runtime constraint.

```zebra
type PositiveInt  = int   where value > 0
type NonEmptyStr  = str   where value.len > 0
type Ratio        = float where value >= 0.0 and value <= 1.0
type UncheckedInt = int                # no constraint
```

### Transparency

The alias is **transparent** — it maps to the same Zig type as its base. No wrapper struct is created. `PositiveInt` variables hold `i64` and are interchangeable with `int` in arithmetic, assignments, and function calls.

```zebra
type PositiveInt = int where value > 0

var count: PositiveInt = 42   # OK — 42 > 0
var doubled: int = count * 2  # fine — transparent
```

### Constraint syntax

The constraint uses the keyword `value` as the implicit binding for the variable being declared:

```zebra
type Name = BaseType where <expr-using-value>
```

The constraint expression has access to all the methods and operators of the base type. For `str`, `value.len`, `value.startsWith(...)`, etc. are all valid.

### Runtime check

After each `var x: AliasType = expr` declaration, the compiler emits:

```zig
{ const value = x; if (!(constraint)) std.debug.panic("type constraint 'AliasType' failed\n", .{}); }
```

The check fires at runtime when the variable is initialized, not when the alias is declared.

### --turbo strips checks

Pass `--turbo` to compile with contracts and type-alias checks stripped. Equivalent to release mode for constraint-heavy code.

### Notes

- Only `var` declarations with an explicit alias type annotation trigger checks. Function return values or implicit coercions do not.
- The `where` clause is optional — `type RawInt = int` is a valid unconstrained alias.
- Aliases do not participate in the type system beyond name transparency; there is no alias-coercion error.

## 37. Refinement types (parametric aliases)

A type alias can carry **value parameters** that are bound into the constraint expression.  This lets the same alias family describe a whole range of bounds without repeating the constraint.

```zebra
type Bounded(lo: int, hi: int) = int where value >= lo and value <= hi

var score: Bounded(0, 100) = 85    # OK
var neg:   Bounded(-50, 50) = -20  # OK
# var bad: Bounded(0, 100) = 150   # runtime panic: "type constraint 'Bounded' failed"
```

### Declaration syntax

```
type AliasName(param1: T1, param2: T2, ...) = BaseType where <expr-using-value-and-params>
```

The parameters are available in the `where` expression alongside `value`:

```zebra
type Temperature(min: int, max: int) = int where value >= min and value <= max

var temp: Temperature(-273, 1000) = 37   # body temperature — OK
```

### Struct base types

The base type can be a struct. The constraint can inspect struct fields through `value.field`:

```zebra
struct Range
    var lo: int
    var hi: int

type ValidRange = Range where value.lo < value.hi

var r: ValidRange = Range(lo: 0, hi: 10)   # OK — lo < hi
```

(Struct aliases do not support value parameters in v1.)

### Transparency

Refinement types are transparent like plain aliases — `Bounded(0, 100)` variables hold `i64` in the generated Zig and are interchangeable with `int`.

### Generated check

After `var score: Bounded(0, 100) = 85`, the compiler emits:

```zig
{
    const lo: i64 = 0;
    const hi: i64 = 100;
    const value = score;
    if (!(value >= lo and value <= hi)) std.debug.panic("type constraint 'Bounded' failed\n", .{});
}
```

### --turbo

`--turbo` strips all alias constraint checks, including refinement type checks.

---

## 38. `using EXPR` — resource scope blocks

`using EXPR` executes a block with a resource that has a `begin()` / `end()` lifecycle.  Any object with both methods works — no interface declaration required.

```zebra
class CountGroup
    var entered: int
    var exited: int
    cue init()
        .entered = 0
        .exited  = 0
    def begin(): void
        .entered = .entered + 1
    def end(): void
        .exited  = .exited + 1

def main(): void
    var g = CountGroup()
    using g
        print "inside"
    # g.entered == 1, g.exited == 1 here
```

### Desugaring

```
using EXPR
    body...
```

expands to:

```zebra
{
    const _in_N = EXPR
    _in_N.begin()
    defer _in_N.end()
    body...
}
```

`EXPR` is evaluated exactly once.  `end()` fires only if `begin()` completes — if `begin()` raises, `end()` is not called.

### GUI layout groups

The GUI stdlib uses `using` for layout containers:

```zebra
using g.vbox("##main", true)       # vertical box (stretch = true)
    using g.hbox("##row", false)   # horizontal box inside
        g.button("OK", .ok)
        g.button("Cancel", .cancel)
    g.text("Status: ready")
```

`g.vbox(id, stretch)` and `g.hbox(id, stretch)` return layout group objects with `begin()` / `end()`.

### Rules and gotchas

- The `using EXPR` header and the first body line must be on adjacent lines — no blank line between them.
- Nesting is supported (`using outer` containing `using inner`).
- `using` is unambiguous: the infix `in` operator (e.g. `"x" in list`) is a separate token and unaffected.
- The type used in `using EXPR` must define `def begin()` and `def end()` — the compiler enforces this at compile time.

---

## 39. `with` — contextual self

`with obj` makes `obj` the implicit receiver for bare-name assignments and bare method
calls inside the block.  It is a compile-time textual rewrite — no runtime cost.

```zebra
with g
    text("Status: ready")          # → g.text("Status: ready")
    button("OK", .ok)              # → g.button("OK", .ok)
    x = 5                          # → g.x = 5
```

**What is rewritten (top-level statements only):**

| Source | After rewrite |
|--------|--------------|
| `method(args)` | `obj.method(args)` |
| `field = val` | `obj.field = val` |

**What is NOT rewritten:**

- Statements nested inside `if`, `for`, `while`, `branch`, etc. inside the `with` block.
  Those require the full `obj.method(...)` form.
- Expressions (the rewrite only targets statement positions).
- `return`, `var`, and other statement forms that aren't bare calls or assignments.

**Nested `with`:**

```zebra
with builder
    begin("container")         # → builder.begin("container")
    with inner_builder
        text("hello")          # → inner_builder.text("hello")
    end()                      # → builder.end()  (outer with is still active)
```

The inner `with` takes precedence for its own block.  The outer `with` resumes when the
inner block closes.

**Interaction with captures:**

Inside a `with` block, captured variables and local variables take precedence over
bare-name rewriting.  If `text` is a local variable, `text = val` assigns the local, not
`obj.text = val`.

**Top-level-only rule:**

The rewrite applies only to statements directly inside the `with` block:

```zebra
with g
    text("hello")                   # rewritten → g.text("hello")
    if someCondition
        text("inside if")           # NOT rewritten (nested) — use g.text(...)
    for item in items
        button(item.name, item.id)  # NOT rewritten (nested) — use g.button(...)
```

**Primary use case:** GUI `view()` functions with many widget calls — avoids repeating
the `g.` prefix on every call.  See §30 for GUI examples.

---

## 40. SQLite — embedded relational database

Zebra ships with a bundled SQLite amalgamation (`sqlite3.c`). The compiler injects it automatically when any SQLite API is used — no build flags needed.

**Setup**: the `vendor/sqlite/sqlite3.c` file must be present alongside the compiler binary (`{exe_dir}/vendor/sqlite/sqlite3.c`).

### Opening a database

```zebra
var db: SqliteDb? = Sqlite.open("myapp.db")   # nil on failure
var db: SqliteDb? = Sqlite.open(":memory:")    # in-memory database
```

`Sqlite.open` returns `SqliteDb?` — always check for nil before use.

### Executing statements

```zebra
d.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
d.exec("INSERT INTO users VALUES (?, ?)", [1, "alice"])   # parameterised
d.exec("UPDATE users SET name=? WHERE id=?", ["bob", 1])
```

Parameters are bound positionally via `[...]` list literals. Supported types: `int`, `str`, `float`.

### Querying rows

```zebra
var rows = d.query("SELECT * FROM users ORDER BY id")
for row in rows
    print row.asInt("id").toString() + " " + row.asStr("name")
```

`db.query(sql)` returns a snapshot list; `for row in rows` iterates over it.

Row accessor methods:

| Method | Return type | Notes |
|---|---|---|
| `row.asInt(col)` | `int` | Reads `INTEGER`/`REAL` as int |
| `row.asStr(col)` | `str` | Reads `TEXT`/`BLOB` as string |
| `row.asFloat(col)` | `float` | Reads `REAL`/`INTEGER` as float |
| `row.asBool(col)` | `bool` | Non-zero int → `true` |

`col` is the column name string.

### Transactions

```zebra
d.begin()
d.exec("INSERT INTO users VALUES (?, ?)", [3, "carol"])
d.commit()      # or d.rollback() to discard
```

### Closing

```zebra
d.close()
```

### Typical pattern

```zebra
def main()
    var maybe_db: SqliteDb? = Sqlite.open("app.db")
    if maybe_db == nil
        print "could not open database"
        return
    var db: SqliteDb = maybe_db to!
    db.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER, body TEXT)")
    db.exec("INSERT INTO notes VALUES (?, ?)", [1, "hello world"])
    var rows = db.query("SELECT * FROM notes")
    for row in rows
        print row.asInt("id").toString() + ": " + row.asStr("body")
    db.close()
```

---

## 41. `namespace` — grouping declarations

`namespace` wraps a block of top-level declarations (classes, structs, enums, functions,
variables) under a named scope.  It is the Zebra equivalent of a Zig `const Foo = struct { ... }`.

```zebra
namespace Colors
    struct Rgb
        var r: int
        var g: int
        var b: int

    def fromHex(hex: int): Rgb
        return Rgb(r: (hex >> 16) & 0xFF, g: (hex >> 8) & 0xFF, b: hex & 0xFF)

# Usage:
var red = Colors.Rgb(r: 255, g: 0, b: 0)
var blue = Colors.fromHex(0x0000FF)
```

- All declarations inside the `namespace` block are accessed with `Name.Member` syntax.
- Methods inside a namespace can call each other without the namespace prefix.
- `namespace` bodies use the same indentation rules as `class` bodies.
- `namespace` supports: `def`, `var`, `class`, `struct`, `enum` declarations.

**Practical use:** namespaces group related helpers that don't belong in a class —
utility functions, type collections, constants.

```zebra
namespace MathUtils
    var PI: float = 3.14159265358979

    def circleArea(r: float): float
        return PI * r * r

    def clamp(x: int, lo: int, hi: int): int
        if x < lo: return lo
        if x > hi: return hi
        return x
```

### Nested namespaces

Two equivalent syntaxes for nested namespaces are supported:

**Dotted path** — `namespace Outer.Inner { ... }`:
```zebra
namespace Outer.Inner
    static def greet(): str
        return "hi"

def main()
    print Outer.Inner.greet()   # prints "hi"
```

**Nested body** — `namespace Outer { namespace Inner { ... } }`:
```zebra
namespace Outer
    namespace Inner
        static def greet(): str
            return "hi"

def main()
    print Outer.Inner.greet()   # prints "hi"
```

Both emit identical Zig — nested `pub const` structs:
```zig
pub const Outer = struct {
    pub const Inner = struct {
        pub fn greet() []const u8 { ... }
    };
};
```

**Practical use:** dotted syntax is concise for a single leaf; nested syntax is
better when the outer namespace also has direct members:
```zebra
namespace Sql
    static def version(): str
        return "1.0"

    namespace Sqlite
        static def open(path: str): int
            pass

    namespace Postgres
        static def connect(url: str): int
            pass

# Usage:
print Sql.version()
var db = Sql.Sqlite.open("mydb.db")
var pg = Sql.Postgres.connect("postgresql://localhost/mydb")
```

---

## 42. `extend` — adding methods to existing types

`extend` adds new methods to a type that is already defined — including built-in types
like `str` and `int`.  The added methods are called with the same `.method()` syntax as
built-in ones.

```zebra
extend str
    def shout(): str
        return this.toUpper() + "!"

    def wordCount(): int
        return this.split(" ").len

# Usage (after the extend block):
var s = "hello world"
print s.shout()       # → HELLO WORLD!
print s.wordCount()   # → 2
```

- `this` inside an `extend` body refers to the receiver value.
- The extended type can be a built-in (`str`, `int`, `float`, `bool`, `char`) or a
  user-defined `class` or `struct`.
- Extension methods are resolved at compile time — the compiler emits a standalone
  function `_ext_TypeName_methodName(self, ...)` and rewrites call sites.
- `extend` can also implement an interface or include a mixin:
  ```zebra
  extend str is Printable
      def show(): str
          return this
  ```
- Extensions are scoped to the file where they appear.  They are not exported across
  module boundaries.

**Common use cases:**

```zebra
extend int
    def isEven(): bool
        return this % 2 == 0

    def abs(): int
        if this < 0: return -this
        return this

extend List(str)
    def joinWith(sep: str): str
        return this.join(sep)
```

---

## 43. `@derive(Debug, Eq, Hash)` — auto-generated methods

`@derive` placed on a `struct` declaration instructs the compiler to auto-generate
implementations of `toString`, `eql`, and/or `hash` based on the struct's fields.

```zebra
@derive(Debug, Eq, Hash)
struct Point
    var x: float
    var y: float

# Generated automatically — no need to write these:
#   def toString(): str    → "Point(x=1.0, y=2.0)"
#   def eql(other: Point): bool
#   def hash(): int
```

**What each trait generates:**

| Trait | Method generated | Behavior |
|-------|-----------------|----------|
| `Debug` | `toString(): str` | `"TypeName(field1=val1, field2=val2)"` format |
| `Eq` | `eql(other: Self): bool` | Field-by-field equality; also enables `==` on the struct |
| `Hash` | `hash(): int` | FNV-1a over all fields; required for use as a `HashMap` key |

**Usage:**

```zebra
@derive(Debug, Eq, Hash)
struct Color
    var r: int
    var g: int
    var b: int

def main()
    var red   = Color(r: 255, g: 0,   b: 0)
    var red2  = Color(r: 255, g: 0,   b: 0)
    var green = Color(r: 0,   g: 255, b: 0)

    print red.toString()          # → Color(r=255, g=0, b=0)
    print red.eql(red2)           # → true
    print red.eql(green)          # → false

    var seen = HashMap(Color, bool)()
    seen.set(red, true)
    print seen.get(red)           # → true  (uses derived hash + eql)
```

**Notes:**

- Any subset of `(Debug, Eq, Hash)` may be specified.
- If you write your own `toString` / `eql` / `hash`, the `@derive` version for that
  trait is suppressed — user methods take precedence.
- `Eq` also rewires the `==` operator on the struct so `a == b` calls `a.eql(b)`.
- `Hash` requires all fields to have a hash-able type.  Fields that are themselves
  structs must also carry `@derive(Hash)`.
- `@derive` applies only to `struct` — not `class`, `enum`, or `union`.

---

## 44. `DynLib` — dynamic library plugins

`DynLib` loads shared libraries (`.dll` / `.so` / `.dylib`) at runtime and calls their
functions through a Zebra interface.  This is the plugin/extension point for code that
lives outside the main binary.

### Opening and closing

```zebra
var lib = DynLib.open("myplugin.dll")   # returns *_DynLib (panics if not found)
lib.close()                             # unloads the library
```

### Calling functions via an interface

Define an `interface` matching the plugin's methods, then call `.lookup`:

```zebra
interface IGreeter
    def greet(name: str): str
    def version(): int

var lib = DynLib.open("greeter.dll")
var g = lib.lookup(IGreeter, "greeter")   # "greeter" = factory symbol name
print g.greet("World")
print g.version()
lib.close()
```

`lib.lookup(IFace, "sym")` looks up `sym` in the DLL as a **factory function**
`fn() *IFace`.  It calls the factory to get the fat-pointer, then returns it.
The returned value satisfies the `interface` type — call its methods with
normal `.method()` syntax.

### Writing a plugin in Zebra — `@export class`

Use `@export("sym") class Foo implements IFace` to make Zebra emit the factory
function automatically.  The compiler generates `pub export fn sym() *IFace` that
wraps a module-static singleton of `Foo` in the interface fat-pointer:

```zebra
# greeter.zbr — compile with: zebra --shared greeter.zbr
interface IGreeter
    def greet(name: str): str

@export("greeter")
class HelloGreeter implements IGreeter
    def greet(name: str): str
        return "Hello, " + name
```

Compile the producer with `zebra --shared greeter.zbr` to produce a shared
library.  The consumer loads it with `DynLib.open` + `lib.lookup(IGreeter, "greeter")`.

**Requirements:**
- The class must implement at least one interface.  The factory wraps the **first**
  listed interface.
- The class init must take no arguments (the factory calls `ClassName.init()` internally).
- Both compilers emit identical output.

### Simple C-callable exports — `export def`

For individual functions with C-compatible types, use `export def`:

```zebra
export def addOne(x: int): int
    return x + 1
```

Emits `pub export fn addOne(x: i64) i64` — callable from C or any language with
FFI support.  Types must be C-compatible (primitives only — `str` is a Zig slice,
not a C pointer, so `str` parameters are not directly C-callable).

### Notes

- `DynLib` is a class; `DynLib.open` returns `*_DynLib`.  Assign to a typed `var` for
  clarity: `var lib: *_DynLib = DynLib.open(...)`.
- The compiler tracks `DynLib.open` result variables and rewrites `.close()` and
  `.lookup()` calls to the correct Zig intrinsics.
- Load-time failure (library not found) panics at runtime — no error return.  Wrap in
  `try`/`catch` via a `throws` wrapper if you need graceful failure.
- Platform note: the library path follows the OS convention.  On Windows, `.dll`; on
  Linux, `lib*.so`; on macOS, `*.dylib`.  Use `sys.getenv("PLUGIN_PATH")` to resolve
  paths at runtime.
