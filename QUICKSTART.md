# Zebra Language Quick Reference

This file is the **agent-facing quick reference** for the Zebra language (.zbr files).
It covers syntax, semantics, and idioms needed to read and write Zebra without
scanning the full compiler source. For the compiler's own implementation see `src/`.

> **Reading order:** §1–§14 cover everyday syntax.  §15–§23 are reference for
> specialised features.  §24–§25 cover contracts and reflection (Zebra's identity
> features).  §26 is idioms; §27 is gotchas.  §28–§31 are memory/build/GUI/stdlib.

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

- Defaults appear after the type annotation: `name: T = expr`.
- Call sites mix positional and named args; named args may appear in any order
  *after* the last positional arg.

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
    print x to!                      # `to!` = force-unwrap (like .? in Zig)

# Optional-unwrap binding form:
if y as n
    print "y is ${n}"                # n is non-optional int

# Combined with type check (LHS must be optional):
var maybeUser: User? = lookup()
if maybeUser is User as u            # binds u: User (non-optional)
    print u.name

# Nil-coalescing:
var z = x ?? 0                       # use 0 if nil

# Optional chaining:
var n = node?.next                   # nil if node is nil
var s = node?.toString()             # method call — nil if node is nil
var v = node?.value to! + 1          # unwrap result of optional chain
```

- `x to!` is the force-unwrap operator.  Panics if nil.
- `??` is nil-coalescing (like `orelse` in Zig).
- `?.` is optional member/method access — propagates nil.  Result type is `T?`.
  If the accessed member is already `T?`, the result is still `T?` (flattened, not `T??`).
- `if x as n` (when `x: T?`) binds `n: T` in the then-branch.

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

# `try expr` prefix — propagates error upward:
var r = try divide(10, 2)
```

- `throws` on a `def` makes it return `anyerror!T`.
- Inside a `throws` method, calls to other `throws` methods in the **same file**
  auto-propagate (compiler emits `try`).  For cross-module `throws` calls or
  calls on local variables, use explicit `?` suffix.
- `raise "msg"` creates an error string; `raise "msg", obj` attaches a
  `_Stringable` details object.
- `catch` clauses appear after the method body at the same indent as `def`;
  they wrap the entire body.  Multiple `catch` clauses are allowed; each has an
  optional `|binding|` and typed variant `|e: ErrorType|`.

`Result(T)` is available as a secondary error-as-value type, but exceptions
are the primary model.

---

## 13. Control flow

```zebra
# if / else if / else
if x > 0
    print "positive"
else if x < 0
    print "negative"
else
    print "zero"

# while
var i = 0
while i < 10
    print i
    i += 1

# while with bind-and-guard:
while line = reader.readLine() != nil
    process(line to!)

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

# String interpolation
var msg = "Hello, ${name}!  You have ${count} items."

# StringBuilder
var sb = StringBuilder()
sb.append("hello")
sb.append(" world")
var result = sb.build()              # str (drains the builder)
```

- `in` operator: `if "needle" in haystack` — substring test.
- Inside `${…}`, non-string values get an implicit `.toString()` call.

### Raw strings

Prefix `r` disables escape processing and interpolation.  Useful for regex and
Windows paths:

```zebra
var pattern = r"\d+\.\d+"            # backslashes literal
var path    = r"C:\Users\Sean"
```

Both `r'…'` and `r"…"` forms are accepted.

### Triple-quoted strings (`"""…"""`)

Multi-line literals without escape processing:

```zebra
var html = """
    <html>
        <body>Hello</body>
    </html>
"""

var sql = """SELECT * FROM users WHERE name = 'Alice'"""   # inline form
```

Leading/trailing whitespace is stripped.  No `${…}` interpolation inside
triple-quoted strings.

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

There is no special property / getter syntax in current Zebra.  The
`prop` / `get` / `set` / `body` / `post` keywords were removed 2026-04-19.

Use ordinary methods for computed state.  Always declare with explicit
parentheses (`def name(): T`) — callers always write parens too:

```zebra
class Circle
    var radius: float

    cue init(r: float)
        radius = r

    def diameter(): float
        return .radius * 2.0

    def area(): float
        return Math.PI * .radius * .radius

# Use:
var c = Circle(5.0)
print c.radius                    # field access — no parens
print c.area()                    # method call — parens
```

Field privacy: there are no `private` / `internal` keywords today.  A
leading underscore on a field name (`_radius`) is purely social convention
and has zero compiler enforcement — see BUG-115.  Style guide stance:
**don't add new `_` prefixes**, but leave existing ones as-is until
BUG-115 resolves (avoids churn-then-rewrite if real privacy keywords
land in 0.14).

For direct field exposure, declare the field public and access `c._radius`
directly.  No "computed property" sugar is provided.

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
  per-instance state — see §30 for a GUI example.

---

## 20. `sig` — function type aliases

`sig` declares a named function-pointer type.  Use it to pass functions as
arguments without wrapping them in closures:

```zebra
sig Comparator(a: int, b: int): int
sig Predicate(item: str): bool
sig Callback()                       # void return

def sort(items: List(int), cmp: Comparator)
    pass

static def ascending(a: int, b: int): int
    return a - b

def main
    var nums = @[3, 1, 4, 1, 5]
    sort(nums, ascending)
```

- `sig` resolves to a `*const fn(T1, T2) R` pointer in Zig.
- Any `static def` at module scope with a matching signature is
  assignment-compatible.

---

## 21. Type checks and unwrapping

```zebra
# Runtime type check (returns bool):
if obj is Dog
    print "is a dog"                  # `obj` is still typed as the original

# Force-unwrap optional:
var x: int? = 42
var y = x to!                         # panics if nil

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

Used to break recursive struct cycles:

```zebra
struct Node
    var value: int
    var next:  ^Node?                 # heap-boxed optional pointer

# Construction — boxing is automatic:
var a = Node(1, nil)
var b = Node(2, nil)
a.next = b                            # auto-boxes: allocates *Node, copies b in
```

- `^T` in a field type → `*T` in Zig.
- `^T?` → `?*T`.
- Assignment to a `^T` field auto-boxes: allocates a heap copy.
- Inside a `branch` on a union with `^T` payload, the binding has type `T`
  (pointer is transparent).
- `^ClassName` is a **compile error** — classes already have reference
  semantics; double-boxing is rejected.

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

Strict semantics:
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
fields.  Sized numerics, `T?`, `List(T)`, and nested `@reflectable` classes
are deferred.

---

## 26. Key idioms summary

| Pattern              | Zebra                          | Notes                                    |
|----------------------|--------------------------------|------------------------------------------|
| Force-unwrap optional | `x to!`                       | panics if nil                            |
| Nil-coalescing       | `x ?? default`                 |                                          |
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

2. **`if` single-line form — body must be on a new indented line:**
   ```zebra
   # WRONG:
   if x > 0 return x
   # RIGHT:
   if x > 0
       return x
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

---

## 30. GUI programming

Zebra has a built-in immediate-mode GUI API backed by Dear ImGui (via the
[zgui](https://github.com/zig-gamedev/zgui) bindings).

### Running a GUI program

```bash
zebra --gui-backend=glfw myapp.zbr
```

The compiler auto-scaffolds a `zig build` project (e.g. `myapp_gui/`) next to
the generated `.zig` file, writes a pinned `build.zig.zon`, and invokes
`zig build run`.  The project directory is reused on subsequent runs.

### Minimal example

```zebra
class Main
    static
        def main
            Gui.run("Hello", 400, 300, def(g: Gui)
                g.text("Hello, Zebra!")
                if g.button("Click me")
                    g.text("Clicked!")
            )
```

### `Gui.run`

```zebra
Gui.run(title: str, width: int, height: int, frame: def(g: Gui))
```

Calls `frame` once per rendered frame until the window is closed.  Use a
`capture` block inside the lambda to keep state alive across frames.

### Widget reference

| Call                                     | Returns | Notes                              |
|------------------------------------------|---------|-------------------------------------|
| `g.text(s)`                              | void    | Text label                          |
| `g.button(label)`                        | bool    | True on click                       |
| `g.checkbox(label, value)`               | bool    | New checked state                   |
| `g.slider(label, value, min, max)`       | float   | Drag slider                         |
| `g.input(label, value)`                  | str     | Single-line text input              |
| `g.inputMultiline(label, value, w, h)`   | str     | Multi-line text area                |
| `g.separator()`                          | void    | Horizontal rule                     |
| `g.sameLine()`                           | void    | Next widget on same line            |
| `g.spacing()`                            | void    | Extra vertical space                |
| `g.indent()` / `g.unindent()`            | void    | Indentation level                   |
| `g.panel(label, callback)`               | void    | Collapsible child window            |
| `g.window(label, callback)`              | void    | Floating sub-window                 |

### `CodeEditor` widget

```zebra
var editor = CodeEditor.forZebra()        # factory — Zebra syntax preset
editor.setText(File.read("main.zbr"))
editor.setReadOnly(false)

# Inside frame lambda:
editor.render(g, "##editor", 700, 500)
var src = editor.getText()
editor.setErrorMarkers(diags)             # diags: List(IDEDiagnostic)
```

### Persistent frame state with `capture`

```zebra
Gui.run("IDE", 1000, 750, def(g: Gui)
    capture
        var state = IDEState()
        var editor = CodeEditor.forZebra()
        var inited: bool = false
    if not inited
        editor.setText(File.read("main.zbr"))
        inited = true
    editor.render(g, "##ed", 800, 600)
)
```

The `capture` block is allocated once when the lambda struct is first created
and reused every frame.

### Backend isolation

The GUI layer uses a `_GuiBackend` fn-pointer struct internally.  Swap the
backend by implementing the fn-ptr slots and changing `_gui_active_backend`
— no changes to user Zebra code required.

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

| Call                              | Returns        | Notes                              |
|-----------------------------------|----------------|-------------------------------------|
| `DateTime.now()`                  | `DateTime`     | Current time                        |
| `dt.epochMs`                      | int            | Milliseconds since epoch            |
| `dt.inCalendar(Calendar.X)`       | `CalendarView` | Calendar-specific lens              |
| `view.year/month/day/...`         | int            | Calendar fields                     |
| `view.format(pattern)`            | str            |                                     |

### `Http` / `HttpResponse`

| Call                                          | Returns         |
|-----------------------------------------------|-----------------|
| `Http.get(url)`                               | `HttpResponse?` |
| `Http.post(url, body)`                        | `HttpResponse?` |
| `Http.json(url, json)`                        | `HttpResponse?` |
| `Http.postJson(url, json)`                    | `HttpResponse?` |
| `HttpResponse.ok(body)` / `notFound(body)` / etc. | `HttpResponse` |
| `r.status / r.text / r.headers`               | mixed           |

### Networking — `Tcp`, `Udp`, `Net`

| Call                              | Returns         | Notes                              |
|-----------------------------------|-----------------|-------------------------------------|
| `Tcp.connect(host, port)`         | `TcpConn?`      |                                     |
| `Udp.socket()`                    | `UdpSocket`     |                                     |
| `Net.resolve(host)`               | `[]str`         | DNS lookup                          |

### `Csv` — RFC 4180 CSV

| Call                              | Returns      | Notes                              |
|-----------------------------------|--------------|-------------------------------------|
| `Csv.parse(src)`                  | `CsvTable`   | Headers + rows                     |
| `t.row(i).field(name)`            | str          | By column name                     |
| `CsvWriter()`                     | `CsvWriter`  | Builder for output                 |

### `Mime`, `Uri`, `Compress`, `Log`, `Terminal`, `Timer`

| Call                              | Returns      | Notes                                       |
|-----------------------------------|--------------|----------------------------------------------|
| `Mime.lookup(filename)`           | str          | MIME type by extension                       |
| `Uri.parse(s)`                    | `UriResult?` | Scheme/host/path/query/fragment              |
| `Compress.gunzip(bytes)`          | `List(byte)` | gzip decompress (gzip stub: Zig 0.15 limit) |
| `Log.info(msg)` / `warn / error`  | void         | Stderr-formatted logger                      |
| `Terminal.clearScreen()` etc.     | void         | ANSI helpers                                 |
| `Timer.start()`                   | `Timer`      | `t.elapsedMs()` for measurement              |

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
