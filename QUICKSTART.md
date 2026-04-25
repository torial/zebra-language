# Zebra Language Quick Reference

This file is the **agent-facing quick reference** for the Zebra language (.zbr files).
It covers syntax, semantics, and idioms needed to read and write Zebra without
scanning the full compiler source. For the compiler's own implementation see `src/`.

---

## 1. File structure

```zebra
# comment
use ast exposing Decl, TypeRef        # import from module, expose names into scope
use codegen                            # import module (access via codegen.Name)

# top-level functions
def helper(x as int) as str
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
- No explicit `main` — programs have a `class Main` with `static def main`, or a top-level `def main()`.

---

## 2. Variables

```zebra
var x = 42                     # inferred type (int)
var name as str = "hello"      # explicit type annotation
var flag as bool               # declaration without init (must assign before use)
var opt as int? = nil          # optional int, initially nil
```

- `var` is always mutable. There is no `let` / `const` in Zebra source.
- The compiler emits `const` or `var` in Zig based on mutation analysis — you don't control this.
- Type annotations use `as Type` syntax.

---

## 3. Primitive types

| Zebra       | Zig             | Notes                         |
|-------------|-----------------|-------------------------------|
| `int`       | `i64`           | default integer               |
| `uint`      | `u64`           |                               |
| `float`     | `f64`           | default float                 |
| `bool`      | `bool`          |                               |
| `char`      | `u21`           | Unicode codepoint             |
| `str`       | `[]const u8`    | immutable string slice        |
| `String`    | `[]const u8`    | alias for str                 |
| `int8–128`  | `i8–i128`       | sized integers                |
| `uint8–128` | `u8–u128`       |                               |
| `float16–128` | `f16–f128`    |                               |
| `StringBuilder` | `std.ArrayList(u8)` | growable string buffer |
| `void`      | `void`          |                               |

Optionals: `T?` → `?T` in Zig. `nil` → `null`.

---

## 4. Functions (top-level `def`)

```zebra
def add(a as int, b as int) as int
    return a + b

def greet(name as str)       # void return (no `as Type`)
    print "Hello, ${name}"

def divide(a as int, b as int) as int throws   # can raise errors
    if b == 0
        raise "division by zero"
    return a / b
```

- `throws` makes the method return `anyerror!T` in Zig.
- `raise "msg"` → returns a Zig error (wraps the string in a named error set).
- Call: `add(1, 2)` — parentheses always required.

---

## 5. Classes (reference types)

Classes are heap-allocated. Variables hold a pointer (`*ClassName` in Zig).
Assigning a class variable copies the pointer, not the object.

```zebra
class Counter
    var count as int

    cue init()                    # constructor
        count = 0

    def increment
        count += 1

    def value() as int
        return count

    static def create() as Counter    # static method
        return Counter()
```

- `cue init(params...)` is the constructor. No return type.
- `static def` = static method. Inside static methods, `this` is unavailable.
- Field access inside methods: `count` (no `self.` needed). External: `obj.count`.
- Constructor call: `Counter()` or `Counter(arg1, arg2)`.

---

## 6. Structs (value types)

Structs are copied on assignment. Methods take `self: *StructType` in Zig.

```zebra
struct Point
    var x as int
    var y as int

    cue init(x as int, y as int)
        this.x = x
        this.y = y

    def distSq() as int
        return x*x + y*y

    def withX(nx as int) as Point    # returns a modified copy
        var p = this except
            x = nx
        return p
```

- `this` refers to the struct value. Use `this.field` when param shadows field name.
- **`this except field = value, ...`** — creates a copy with specified fields overridden. This is the primary idiom for immutable-style context forking.
- Method chaining on temporaries is BANNED — see Section 14.

---

## 7. `struct except` — context forking

```zebra
struct Config
    var indent as int
    var owner  as str
    var verbose as bool

    def indented() as Config
        var c = this except
            indent = indent + 1
        return c

    def withOwner(name as str) as Config
        var c = this except
            owner = name
        return c
```

**Critical rule:** You CANNOT chain these calls on temporaries:
```zebra
# WRONG — compile error (temporary is *const Config):
var c = makeConfig().indented().withOwner("Foo")

# RIGHT — materialize each step:
var c0 = makeConfig()
var c1 = c0.indented()
var c  = c1.withOwner("Foo")
```

---

## 8. Enums

```zebra
enum Color
    red
    green
    blue

enum Status(int)             # backed by int
    ok = 0
    err = 1
```

Usage: `Color.red`, `Status.ok`.

---

## 9. Unions (tagged unions)

```zebra
union Expr
    int_: int
    str_: str
    void_                    # payload-less variant
    node_: ^Node             # heap-indirection payload (^T only valid for structs/primitives)

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

- `^T` payload: the pointer is transparent — the branch-binding variable has type `T`, not `*T`.
- `^T` is valid only for struct/primitive/union payloads. Using `^ClassName` where `ClassName` is a class is a **compile error** — classes are already reference types; `^ClassName` would double-box to `**T`. Use `item: ClassName` directly.
- `else` with `pass` is required for non-exhaustive branches.

```zebra
# Single-variant check with payload binding — use `if x is Union.Variant as r`
var e = Expr.int_(42)
if e is Expr.int_ as n
    print "got int: ${n}"    # n is the int payload
else
    print "not int"

# Standalone `is` check (no binding):
var ok = e is Expr.int_          # true — union variant check
var ok2 = e is MyClass           # true — class type-tag check
```

**Style rule — `if ... is ... as` vs `branch`:**
- Use `if x is Union.Variant as r` when checking a **single variant** and binding its payload.
  This is more concise and reads naturally ("if x is a Member expression, bind it as m").
- Use `branch x` when dispatching across **multiple variants** of a union.
  `branch` is exhaustive-by-default and enforces complete coverage with `else`.

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
var items = List(int)()          # empty list
items.add(1)
items.add(2)
var n = items.count()            # length
var x = items.at(0)             # index (bounds-checked)
items.remove(0)                  # remove by index
var has = items.any(def(x) = x > 2)   # true if any element matches predicate
var ok  = items.all(def(x) = x > 0)   # true if every element matches predicate

# HashMap
var m = HashMap(str, int)()
m.set("a", 1)
var v = m.get("a")              # returns int? (optional)
var has = m.contains("a")       # bool

# Iteration
for item in items
    print item

for k, v in m
    print "${k} = ${v}"
```

---

## 11. Optional types and nil

```zebra
var x as int? = nil
var y as int? = 42

if x != nil
    print x to!              # `to!` = force-unwrap (like .? in Zig)

var z = x ?? 0               # nil-coalescing: use 0 if nil

# Optional chaining:
var n = node?.next           # nil if node is nil
var v = node?.value to! + 1  # unwrap result of optional chain
```

- `x to!` is the force-unwrap operator. Panics if nil.
- `??` is nil-coalescing (like `orelse` in Zig).
- `?.` is optional member access — propagates nil.

---

## 12. Error handling

```zebra
def divide(a as int, b as int) as int throws
    if b == 0
        raise "division by zero"
    return a / b

def caller() as int throws
    var r = divide(10, 2)     # auto-propagates (same-file throws methods)
    return r

# Method-level catch (catch clauses after the method body):
def risky()
    var r = divide(10, 0)
    print r
catch |e|
    print "Error: " + e.message

# Inline postfix catch — fallback value on error:
var r = divide(10, 0) catch 0

# Explicit propagation with `?`:
var r = someObj.method()?    # propagates if method throws

# `try expr` prefix — propagates error upward:
var r = try divide(10, 2)
```

- `throws` on a `def` makes it return `anyerror!T`.
- Inside a `throws` method, calls to other `throws` methods in the same file auto-propagate (emit `try`).
- For cross-module `throws` calls or local variable method calls, use explicit `?` suffix.
- `raise "message"` creates an error.
- `catch` clauses appear after the method body at the same indent as `def` — they wrap the entire body.
- Multiple catch clauses are allowed; each has an optional `|binding|` and typed variant `|e: ErrorType|`.

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

# for-in (list)
for item in items
    print item

# for-in with index
for i, item in items
    print "${i}: ${item}"

# for-num (numeric range)
for i in 0 to 10       # 0..9
    print i
for i in 0 to 10 step 2
    print i

# for-else (else runs when loop completes without break, including empty iterable)
for item in items
    if item == target
        found = item
        break
else
    found = default_value

# guard (early return on nil/false)
guard x != nil else
    return

# branch (pattern matching on unions)
branch expr
    on ExprKind.int_ as n
        return n
    on ExprKind.str_ as s
        return s.len
    else
        pass
```

---

## 14. String operations

```zebra
var s = "hello"
var t = "world"
var u = s + ", " + t           # concatenation
var n = s.len                  # length (int)
var c = s[0]                   # char at index
var sub = s[1..3]              # substring slice
var up = s.upper()
var lo = s.lower()
var trimmed = s.trim()
var b = s.startsWith("hel")   # bool
var b2 = s.endsWith("lo")     # bool
var idx = s.indexOf("ll")     # int? (nil if not found)
var parts = s.split(",")      # List(str)
var joined = items.join(", ") # str

# String interpolation
var msg = "Hello, ${name}! You have ${count} items."

# StringBuilder
var sb = StringBuilder()
sb.append("hello")
sb.append(" world")
var result = sb.build()       # str (drains the builder)
```

- `in` operator for substring check: `if "needle" in haystack`
- `"needle" in haystack` is preferred over `haystack.contains("needle")` when TC can't resolve the method.

### Raw strings

Prefix `r` disables escape processing and interpolation. Useful for regular expressions and Windows paths:

```zebra
var pattern = r"\d+\.\d+"       # backslashes literal — no need to double-escape
var path    = r"C:\Users\Sean"  # Windows path without escaping
```

Both `r'...'` and `r"..."` forms are accepted.

### Triple-quoted strings (`"""..."""`)

Multi-line string literals without escape sequences:

```zebra
var html = """
    <html>
        <body>Hello</body>
    </html>
"""

var sql = """SELECT * FROM users WHERE name = 'Alice'"""  # inline form also works
```

Leading/trailing whitespace is stripped from the resulting string. No interpolation (`${...}`) inside triple-quoted strings.

---

## 15. Modules and cross-module usage

```zebra
# file: math_utils.zbr
def square(x as int) as int
    return x * x

struct Vec2
    var x as float
    var y as float

    def length() as float
        return Math.sqrt(x*x + y*y)
```

```zebra
# file: main.zbr
use math_utils exposing square, Vec2    # expose into scope

def main
    var n = square(5)         # direct call
    var v = Vec2(3.0, 4.0)
    print v.length()

# OR without exposing:
use math_utils

def main
    var n = math_utils.square(5)
    var v = math_utils.Vec2(3.0, 4.0)
```

**Cross-module type annotation:**
```zebra
var v as math_utils.Vec2 = math_utils.Vec2(1.0, 2.0)
# OR with exposing:
var v as Vec2 = Vec2(1.0, 2.0)
```

---

## 16. Interfaces and mixins

```zebra
interface Printable
    def show() as str

class Dog mixes Printable
    var name as str

    cue init(name as str)
        this.name = name

    def show() as str
        return "Dog(${name})"

# `is` check:
if obj is Printable
    print obj.show()
```

---

## 17. Generics

```zebra
class Stack(T)
    var _items as List(T)

    cue init()
        _items = List(T)()

    def push(item as T)
        _items.add(item)

    def pop() as T?
        if _items.count() == 0
            return nil
        var last = _items.at(_items.count() - 1)
        _items.remove(_items.count() - 1)
        return last

# Usage:
var s = Stack(int)()
s.push(1)
s.push(2)
var top = s.pop()
```

- Generic class instantiation: `Stack(int)()` — type arg then constructor args.
- Type params can have constraints: `class Cache(K where Hashable)`.

---

## 18. Properties

```zebra
class Circle
    var _radius as float

    cue init(r as float)
        _radius = r

    prop radius as float
        return _radius

    prop area as float
        return Math.PI * _radius * _radius
```

- `prop name as Type` defines a read-only computed property.
- Access: `c.radius` (no parens).

---

## 19. Lambda / closures

```zebra
var double = (x as int) -> x * 2
var items = List(int)()
items.add(1)
items.add(2)

# Higher-order (not yet widely supported — use explicit loops):
# items.map(double)
```

---

## 20. `sig` — function type aliases

`sig` declares a named function-pointer type. Use it to pass functions as arguments without wrapping them in closures:

```zebra
sig Comparator(a as int, b as int) as int
sig Predicate(item as str) as bool
sig Callback() as void

def sort(items as List(int), cmp as Comparator)
    # cmp(a, b) — call it like any method
    pass

static def ascending(a as int, b as int) as int
    return a - b

def main
    var nums = @[3, 1, 4, 1, 5]
    sort(nums, ascending)
```

- `sig` names a `*const fn(T1, T2) R` pointer type in Zig.
- Any `static def` at module scope with a matching signature is assignment-compatible.
- Useful for callbacks, strategy pattern, higher-order functions.

---

## 21. Type checks and casts

```zebra
if obj is Dog
    var d = obj as Dog      # downcast
    print d.name

var x as int? = 42
var y = x to!               # force-unwrap optional (panics if nil)
```

---

## 22. `^T` heap-indirection (recursive types only)

Used to break recursive struct cycles:

```zebra
struct Node
    var value as int
    var next  as ^Node?    # heap-boxed optional pointer

# Construction — boxing is automatic:
var a = Node(1, nil)
var b = Node(2, nil)
a.next = b                 # auto-boxes: allocates *Node, copies b into it
```

- `^T` in a field type declaration → `*T` in Zig.
- `^T?` → `?*T` in Zig.
- Assignment to a `^T` field auto-boxes: allocates a heap copy.
- Inside a `branch` on a union with `^T` payload, the binding has type `T` (pointer is transparent).

---

## 23. `zig"..."` escape hatch

Inline Zig code (for stdlib wrappers or when Zebra doesn't support a pattern):

```zebra
def rawMemset(ptr as uint, size as uint)
    zig"@memset(@as([*]u8, @ptrFromInt(ptr))[0..size], 0);"
```

---

## 24. Key idioms summary

| Pattern | Zebra | Notes |
|---------|-------|-------|
| Force-unwrap optional | `x to!` | panics if nil |
| Nil-coalescing | `x ?? default` | |
| Substring test | `"needle" in str` | prefer over `.contains` |
| Optional chain | `obj?.field` | propagates nil |
| Error propagation | `expr?` | explicit in local/cross-module calls |
| Auto-propagation | `self.method()` | same-file throws methods only |
| Struct update copy | `this except field = val` | `struct except` idiom |
| Force cast | `x as Type` | downcast after `is` check |
| Int-to-float | `x.toFloat()` | explicit conversion |
| Divide integers | use `int` division | `%` for modulo |

---

## 25. Common gotchas

1. **`else` + `pass` must be on separate lines:**
   ```zebra
   # WRONG:
   else pass
   # RIGHT:
   else
       pass
   ```

2. **`if` single-line form — body must be on new indented line:**
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
       var items = List(int)()    # correct — init required for locals
       var items as List(int)     # ERROR — collection locals must be initialized
   ```

5. **Struct/class FIELD declarations use `as List(T)` (no init) — init goes in `cue init`:**
   ```zebra
   class Foo
       var items as List(int)    # correct — field declaration, no init here
       cue init()
           items = List(int)()   # init here (or receive via param and assign)

   struct Bar
       var parts as List(str)    # correct — struct field
       cue init(parts as List(str))
           this.parts = parts
   ```
   The rule: `var X = List(T)()` is for **method bodies**. `var X as List(T)` is for **field declarations**.

6. **`StringBuilder` field → use `= StringBuilder()` in cue init:**
   The compiler special-cases `StringBuilder()` to emit `std.ArrayList(u8){}`.

7. **Struct method chaining on temporaries fails** (see Section 7). Always use named intermediate vars.

8. **`print` is a statement, not a function:** `print "hello"` not `print("hello")`.
   For multiple values: `print "a", b, "c"`.

9. **Keyword escaping** — Zig keywords used as Zebra field names must be renamed with trailing underscore convention in codegen output: `type_` not `type`, `void_` not `void`.

10. **`cue init` with explicit params needs `this.field` when param shadows field:**
    ```zebra
    cue init(x as int, y as int)
        this.x = x    # 'x' param shadows 'x' field
        this.y = y
    ```

11. **`for-else` on HashMap/string-split/chars iterators**: the `else` block is silently
    dropped for these paths (Path 2, deferred). Only list `.items` iteration is fully supported.

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
        summary = summarise(src)    # copies result into outer arena
    print summary                   # safe
    ```

---

## 26. Memory model and the `arena` block

**Book note — must be covered thoroughly in the language book.**

Zebra uses a single program-wide `ArenaAllocator`. All allocations (strings,
lists, class instances) live until program exit. You never free individual
values; the arena cleans up everything at once. This makes memory management
invisible for typical programs.

### When you need bounded-scope memory: `arena`

The `arena` keyword creates a scoped sub-arena. On exit the sub-arena is
destroyed — everything allocated inside it is freed, and `_allocator` reverts
to the parent arena.

```zebra
arena
    var src = File.read("big_file.txt")
    var parsed = parse(src)
    result = extract_summary(parsed)   # copies into parent arena
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
the block exits. If you store a reference to it in an outer variable, that
reference becomes dangling.

Safe patterns for passing values out:
```zebra
var name = ""
arena
    var src = File.read("config.txt")
    name = parse_name(src)    # _str_concat call copies into outer arena
```

Unsafe (do not do this):
```zebra
var ptr_into_block as str
arena
    var src = File.read("config.txt")
    ptr_into_block = src      # WRONG: src freed when arena exits
print ptr_into_block          # dangling slice — undefined behaviour
```

### Why individual `free` calls are absent

Unlike Zig or C, Zebra never emits `defer allocator.free(x)` for local
string variables. With `ArenaAllocator`, individual frees are either a
no-op (middle of the arena) or dangerous (last allocation — Zig 0.15
rewinds the bump pointer, corrupting any sub-slice still in use). The
`arena` block is the correct, safe mechanism for bounded reclaim.

---

## 27. Build and run

```bash
# From repo root:
zig build run -- path/to/file.zbr    # compile and run
zig build test                        # run test suite

# Multi-file with imports:
zig build run -- selfhost/codegen_test.zbr   # auto-discovers imports
```

The compiler resolves `use module_name` by looking for `module_name.zbr` in the same directory as the input file, then in `selfhost/`, `test/`, and stdlib paths.

---

## 28. GUI programming

Zebra has a built-in immediate-mode GUI API backed by Dear ImGui (via the
[zgui](https://github.com/zig-gamedev/zgui) bindings).

### Running a GUI program

Pass `--gui-backend=glfw` to the compiler:

```bash
zebra --gui-backend=glfw myapp.zbr
```

The compiler auto-scaffolds a `zig build` project (e.g. `myapp_gui/`) next to
the generated `.zig` file, writes a pinned `build.zig.zon`, and invokes
`zig build run`. The project directory is reused on subsequent runs.

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

Calls `frame` once per rendered frame until the window is closed. Use a
`capture` block inside the lambda to keep state alive across frames.

### Widget reference

| Call | Returns | Notes |
|------|---------|-------|
| `g.text(s)` | void | Displays a text label |
| `g.button(label)` | bool | Returns true on click |
| `g.checkbox(label, value)` | bool | Returns new checked state |
| `g.slider(label, value, min, max)` | float | Drag slider |
| `g.input(label, value)` | str | Single-line text input |
| `g.inputMultiline(label, value, w, h)` | str | Multi-line text area |
| `g.separator()` | void | Horizontal rule |
| `g.sameLine()` | void | Next widget on same line |
| `g.spacing()` | void | Extra vertical space |
| `g.indent()` / `g.unindent()` | void | Indentation level |
| `g.panel(label, callback)` | void | Collapsible child window |
| `g.window(label, callback)` | void | Floating sub-window |

### `CodeEditor` widget

`CodeEditor` is a builtin type for editable code panels:

```zebra
var editor = CodeEditor.forZebra()     # factory — Zebra syntax preset
editor.setText(File.read("main.zbr"))
editor.setReadOnly(false)

# Inside frame lambda:
editor.render(g, "##editor", 700, 500)
var src = editor.getText()
editor.setErrorMarkers(diags)          # diags: List(IDEDiagnostic)
```

### Persistent frame state with `capture`

State that must survive across frames (editor content, file path, loaded flag)
goes in a `capture` block at the top of the frame lambda:

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

The GUI layer uses a `_GuiBackend` fn-pointer struct internally. The current
backend is `_gui_active_backend`. To add a new backend, implement the fn-ptr
slots (see `src/CodeGen.zig` preamble) and swap the constant — no changes to
user Zebra code required. The `codeEditorFn` slot is reserved for a future
ImGuiColorTextEdit integration.

---

## 29. Standard library API reference

### `sys` — process / OS

| Call | Returns | Notes |
|------|---------|-------|
| `sys.args()` | `List(str)` | Raw command-line arguments |
| `sys.exit(code)` | noreturn | Exit with given code |
| `sys.err(msg)` | void | Write to stderr (no newline) |
| `sys.errln(msg)` | void | Write to stderr + newline |
| `sys.getenv(name)` | `str?` | Environment variable or nil |
| `sys.run(argv)` | `SysRunResult` | Spawn subprocess; returns `{stdout, stderr, exit_code}` |
| `sys.sleep(ms)` | void | Sleep for `ms` milliseconds |

### `File` — file I/O (static)

| Call | Returns | Notes |
|------|---------|-------|
| `File.read(path)` | `str` | Read entire file as string |
| `File.write(path, data)` | void | Write string to file (creates or truncates) |
| `File.append(path, data)` | void | Append string to file |
| `File.readLines(path)` | `List(str)` | Read file as list of lines |
| `File.exists(path)` | `bool` | True if file exists |
| `File.delete(path)` | void | Delete file (no-op if missing) |
| `File.rename(src, dst)` | void | Rename/move file |
| `File.copy(src, dst)` | void | Copy file |
| `File.listDir(path)` | `List(str)` | List entry names in directory |
| `File.modtime(path)` | `int` | Modification time in ms since epoch; -1 if missing |

### `Dir` — directory operations (static)

| Call | Returns | Notes |
|------|---------|-------|
| `Dir.create(path)` | void | Create directory (no-op if exists) |
| `Dir.createAll(path)` | void | Create directory tree |
| `Dir.delete(path)` | void | Delete empty directory |
| `Dir.deleteAll(path)` | void | Delete directory tree recursively |
| `Dir.exists(path)` | `bool` | True if directory exists |

### `Arg` — command-line argument parsing

```zebra
var args = Arg.parse()
var path       = args.positional(0)   # ?str — nth positional (0-based)
var verbose    = args.flag("--verbose")    # bool
var output     = args.option("--out", "")  # str with default
var present    = args.contains("--dry-run") # bool
```

### `Math` — mathematics

| Call | Returns |
|------|---------|
| `Math.sin/cos/tan(x)` | float |
| `Math.asin/acos/atan(x)` | float |
| `Math.atan2(y, x)` | float |
| `Math.sqrt/exp/log/log2/log10(x)` | float |
| `Math.floor/ceil/round/trunc(x)` | float |
| `Math.pow(x, y)` | float |
| `Math.abs(x)` | numeric |
| `Math.min(a, b)` / `Math.max(a, b)` | numeric |
| `Math.PI`, `Math.E`, `Math.TAU` | float constants |
