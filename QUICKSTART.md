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
- `def name: T` (no parens) is a **getter**: callers write `obj.name`, not `obj.name()`.
  The body is a normal method body.
- Field access inside methods: bare `count` (no `self.` needed).
  External: `obj.count`.
- Constructor call: `Counter()` or `Counter(arg1, arg2)`.

---

## 6. Structs (value types)

Structs are copied on assignment.  Methods take `self: *StructType` in Zig.

```zebra
struct Point
    var x: int
    var y: int

    cue init(x: int, y: int)
        this.x = x
        this.y = y

    def distSq(): int
        return x*x + y*y

    def withX(nx: int): Point         # returns a modified copy
        var p = this except
            x = nx
        return p
```

- `this` refers to the struct value.  Use `this.field` when a param shadows a
  field name.
- `this except field = value, ...` — copy with overrides; the primary
  immutable-update idiom.
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
var items = List(int)()              # empty list
items.add(1)
items.add(2)
var n = items.count()                # length
var x = items.at(0)                  # index (bounds-checked)
items.remove(0)                      # remove by index
var has = items.any(def(x) = x > 2)  # true if any element matches predicate
var ok  = items.all(def(x) = x > 0)  # true if every element matches predicate

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
var v = node?.value to! + 1          # unwrap result of optional chain
```

- `x to!` is the force-unwrap operator.  Panics if nil.
- `??` is nil-coalescing (like `orelse` in Zig).
- `?.` is optional member access — propagates nil.
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
        this.name = name

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
    var _items: List(T)

    cue init()
        _items = List(T)()

    def push(item: T)
        _items.add(item)

    def pop(): T?
        if _items.count() == 0
            return nil
        var last = _items.at(_items.count() - 1)
        _items.remove(_items.count() - 1)
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

Use ordinary methods for computed state.  `def name: T` is shorthand for
`def name(): T` — a zero-arg method with a return type — and callers always
include the parentheses:

```zebra
class Circle
    var _radius: float

    cue init(r: float)
        _radius = r

    def radius: float            # same as `def radius(): float`
        return _radius

    def area: float
        return Math.PI * _radius * _radius

# Use:
var c = Circle(5.0)
print c.radius()                  # parentheses required
print c.area()
```

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
| Auto-propagation     | `self.method()`                | same-file `throws` methods only          |
| Struct update copy   | `this except field = val`      |                                          |
| Class downcast       | `if x is Dog as d`             | requires `x: Dog?`; binds `d: Dog`        |
| Int-to-float         | `x.toFloat()`                  | explicit conversion                      |
| Divide integers      | `int` division                 | use `%` for modulo                       |
| Field-style getter   | `def name: T` (no parens)      | called as `obj.name`                     |

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
           this.parts = parts
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

10. **`cue init` with explicit params needs `this.field` when param shadows field:**
    ```zebra
    cue init(x: int, y: int)
        this.x = x                   # 'x' param shadows 'x' field
        this.y = y
    ```

11. **`for-else` on HashMap / string-split / chars iterators:** the `else` block
    is silently dropped (deferred work).  Only list `.items` iteration is fully
    supported.

12. **`arena` block — strings/slices allocated inside do NOT survive the block:**
    ```zebra
    arena
        var src = File.read("data.txt")
        var words = src.split(" ")
        process(words)
    # src and words are gone here — the sub-arena was freed
    ```
    Copy values you need to survive using assignment to outer variables
    (string concat, List addition, etc. all allocate into the outer arena):
    ```zebra
    var summary = ""
    arena
        var src = File.read("data.txt")
        summary = summarise(src)     # copies result into outer arena
    print summary                    # safe
    ```

13. **CRLF line endings crash the tokenizer.**  `.zbr` files must use LF only.
    A `\r` produces `unexpected '\r' (CRLF line endings — convert to LF)`.

---

## 28. Memory model and the `arena` block

Zebra uses a single program-wide `ArenaAllocator`.  All allocations (strings,
lists, class instances) live until program exit.  You never free individual
values; the arena cleans up everything at once.  This makes memory management
invisible for typical programs.

### When you need bounded-scope memory: `arena`

The `arena` keyword creates a scoped sub-arena.  On exit the sub-arena is
destroyed — everything allocated inside it is freed, and `_allocator` reverts
to the parent arena.

```zebra
arena
    var src = File.read("big_file.txt")
    var parsed = parse(src)
    result = extract_summary(parsed)  # copies into parent arena
# big_file.txt buffer + all parse temporaries freed here
```

Typical uses:
- **Large file processing in a loop** — read, process, discard each file's
  memory before reading the next.
- **Compute-intensive stdlib use** — regex matches, heavy string transforms —
  where intermediate allocations would otherwise accumulate.
- **Any batch operation** where you want to bound peak memory usage.

### What does NOT survive an `arena` block

Any `str`, `List`, or class instance allocated inside the block is freed when
the block exits.  If you store a reference to it in an outer variable, that
reference becomes dangling.

```zebra
# Safe pattern:
var name = ""
arena
    var src = File.read("config.txt")
    name = parse_name(src)            # _str_concat call copies into outer arena

# Unsafe — DO NOT DO THIS:
var ptr_into_block: str
arena
    var src = File.read("config.txt")
    ptr_into_block = src              # WRONG: src freed when arena exits
print ptr_into_block                  # dangling slice — undefined behaviour
```

### Why individual `free` calls are absent

Unlike Zig or C, Zebra never emits `defer allocator.free(x)` for local string
variables.  With `ArenaAllocator`, individual frees are either a no-op (middle
of the arena) or dangerous (last allocation — Zig 0.15 rewinds the bump
pointer, corrupting any sub-slice still in use).  The `arena` block is the
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
| `re.test(s)`                      | bool           | Match anywhere                      |
| `re.match(s)`                     | bool           | Match from start                    |
| `re.find(s)`                      | str            | First match                         |

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
