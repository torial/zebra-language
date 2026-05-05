# Zebra Style Guide — DRAFT

> **Status:** v0 draft for review. Not authoritative. Once Sean signs off section
> by section, the contents (or curated subset) move into `STYLE_GUIDE.md` at
> repo root and become a sweep target across `selfhost/`, `test/`, and
> `examples/`.
>
> **Confidence markers:**
> - ✅ ESTABLISHED — repeated in QUICKSTART + recent code; safe to enforce.
> - 📋 PROPOSED — Claude's recommendation; needs Sean's call.
> - ❓ OPEN — codebase is split; surfaces a decision Sean should make.
> - ⚠️ COMPILER-DRIVEN — current "rule" is a workaround for a known limit;
>   flips when the bug clears. Tracked separately in §X.

This guide is "of the possible, what to prefer." For *what's possible at all*,
read [QUICKSTART.md](../QUICKSTART.md) first — sections cross-referenced as
`QS §N`.

---

## §0. Ground rules

1. **One canonical way per pattern.** When two forms work, this guide picks
   one. Mixing them in the same codebase has a real cost (greppability, IDE
   tooling, sweep diffs).
2. **Workarounds are not style.** A pattern that exists because a compiler
   bug forces it goes in §13, not in the main guide. When the bug clears,
   the rule flips. Don't bake workarounds into idiom.
3. **The selfhost compiler is not a style oracle.** It was written incrementally
   across many compiler versions; it carries legacy patterns that newer
   `examples/` and `test/` files no longer use. When `selfhost/*.zbr`
   disagrees with QUICKSTART, QUICKSTART wins (and selfhost is on the sweep
   list).

---

## §1. Three foundational decisions (resolved 2026-05-04)

### Q1 — Field access inside methods ✅ RESOLVED

**Canonical: `.field` (leading-dot shorthand).**

Verified working in the compiler: `.count = .count + 1` resolves to
`self.count = (self.count + 1)`. The leading-dot is **explicit receiver
access** — it lets a local variable freely shadow a field name without
blocking access to the field:

```zebra
class Counter
    var count: int

    def increment()
        var count = 99           # local shadows field — fine
        .count = .count + 1      # still reaches the field
        print count              # prints 99  (the local)
        print .count             # prints the incremented field

# Constructor disambiguation:
cue init(count: int)
    .count = count               # ✓ explicit; param `count` doesn't block
```

Style rules:
- ✅ Use `.field` everywhere you'd otherwise write `this.field`. Same
  result, less noise.
- ✅ Bare `name` is still legal **when no local shadows the field**, but
  **prefer `.field`** for consistency and shadow-resilience. (Saves you when
  someone later adds a `var name = ...` in the method.)
- ❌ `this.field` is non-canonical. Sweep target across selfhost
  (1,149 occurrences) and examples.

Why this beats both prior options: it's shorter than `this.`, more
shadow-safe than bare access, and visually distinguishes "self-receiver"
(`.x`) from local variables in the same method body.

### Q2 — `def name: T` shorthand ✅ RESOLVED

**Canonical: always `def name(): T`. Drop the no-parens shorthand.**

```zebra
# ✓ Canonical:
def radius(): float
    return _radius

# ✗ Non-canonical (sweep target):
def radius: float
    return _radius
```

Sweep targets: 38 occurrences across 17 files (see §1 Q2 listing in v0
draft). After the sweep, file a bug to **remove the no-parens form from
the grammar** so it can't drift back in.

### Q3 — Underscore-prefix on fields ✅ RESOLVED

**Verified: `_` has no compiler-level meaning.** `f._hidden` from outside
the class works without complaint. It is pure social convention.

**Canonical: no new `_` prefixes; leave existing as-is until BUG-115
resolves.**  See §21 Q-d for the full rationale.  Short version: dropping
existing prefixes now and re-adding them later (if 0.14 ships real
privacy keywords) would be churn-then-rewrite.  Pinning at "no new"
keeps the codebase consistent with the eventual choice in either
direction.

Compiler-generated identifiers (`_allocator`, `_arena`, `_intern`,
`_error_ctx`, `_str_pool`) are out of scope — those are emitted as-is
by `src/CodeGen.zig` and aren't user-authored.

📋 **Tracker:** BUG-115.  Final sweep direction (drop or convert to
`private`) decided when 0.14 lands or BUG-115 is closed wontfix.

---

## §2. File and module layout

### 2.1 Filename ↔ module name ✅ ESTABLISHED

- File stem = module name. `parser.zbr` → `use parser`.
- One primary class/file. Partials use `.<facet>.zbr` suffix:
  `Foo.zbr` + `Foo.json.zbr` + `Foo.ui.zbr`.

### 2.2 Top-of-file ordering 📋 PROPOSED

```zebra
# 1. File-level header comment (purpose, one paragraph).
# parser.zbr — recursive-descent parser. Token stream → PNode tree.

# 2. use statements, alphabetised within group.
use Token exposing TokenKind
use Lexer
use ast exposing Decl, TypeRef

# 3. sig declarations.
sig Comparator(a: int, b: int): int

# 4. enums, then structs, then unions, then classes.
enum TokKind ...
struct Span ...
union Expr ...
class Parser ...

# 5. Top-level functions.
def helper(x: int): int
    return x

# 6. main last.
def main()
    ...
```

Rationale: declarations come before use; types before functions; `main` last
so the reader's eye lands on entry behaviour after seeing the building blocks.
Selfhost largely follows this; some examples don't.

### 2.3 `use` line shape ✅ ESTABLISHED

- One `use` per line. **No line continuations** (QS §27 gotcha #3).
- `exposing` list is comma-separated, all on the same physical line:
  ```zebra
  use ast exposing Decl, DeclEnum, DeclUnion, DeclStruct, TypeRef
  ```
- If the list is too long for one line, split into multiple `use ast exposing
  X, Y` lines for the same module — the compiler merges them.

### 2.4 `main` form 📋 PROPOSED

Both legal:
```zebra
class Main
    static
        def main
            ...
```
vs.
```zebra
def main()
    ...
```

📋 **Recommend top-level `def main()`** for new code. Cleaner; `class Main`
is legacy from when top-level wasn't supported. Selfhost still uses
`class Main` — flag for sweep.

---

## §3. Naming

### 3.1 Identifier conventions ✅ ESTABLISHED

| Kind                  | Convention             | Example                |
|-----------------------|------------------------|------------------------|
| Module / filename     | `lower_snake_case`     | `cg_helpers.zbr`       |
| Class / struct / enum / union / interface / mixin | `PascalCase` | `Parser`, `TokKind`   |
| Method / function     | `lowerCamelCase`       | `parseExpr`, `nextToken` |
| Variable / parameter / field | `lowerCamelCase`     | `tokenStream`, `count` |
| Generic type param    | Single `PascalCase` letter | `T`, `K`, `V`        |
| Enum / union variant  | `lower_snake_case` with trailing `_` if the bare name collides with a Zig keyword | `int_`, `void_`, `red`, `green` |
| Constant              | `PascalCase` (read like a static class member) | `Math.PI`, `Math.TAU` |

⚠️ Trailing `_` on variants like `int_`, `str_`, `void_` is **Zig-keyword
collision avoidance**, not stylistic. Don't add it gratuitously to non-colliding
variants. (QS §27 gotcha #9)

### 3.2 Boolean and predicate names ✅ STRONGLY RECOMMENDED

- Predicate methods (return `bool`) start with `is`, `has`, `should`, `can`,
  or read as a question: `isOpenCall()`, `hasNext()`, `contains(x)`.
- Boolean fields likewise: `isReady`, `hasError`. Not `ready` (ambiguous: state
  or count?).

Reviewers should flag deviations.  Strict enforcement isn't possible —
some legacy or domain-specific names legitimately don't match — but the
default is unambiguous: prefix or rephrase.

### 3.3 Spell out field and parameter names 📋 PROPOSED

Don't abbreviate **field names** or **method parameters**:

```zebra
# ✓ Spelled out:
class Parser
    var tokens: List(Token)
    var position: int

    def consume(expected: TokenKind): Token
        ...

# ✗ Cryptic abbreviations:
class Parser
    var tks: List(Token)            # what's a tk?
    var p: int                      # parser? position? pointer?

    def consume(t: TokenKind): Token
        ...
```

**Local-scope variables inside a short method body are fine to
abbreviate** — `var l = lhs.lower()`, `var r = rhs.lower()` in a 4-line
method is readable.  The rule is for names that escape the method body
(fields, parameters, return values).

---

## §4. Variables

### 4.1 Annotate at boundaries; infer in bodies ✅ ESTABLISHED (QS §2)

```zebra
# ✓ Function signatures always typed.
def parseLine(src: str): List(Token) throws
    ...

# ✓ Local variables: rely on inference.
var n = 42
var name = "hello"
var items = List(int)()

# ✓ Annotate locals only when inference is wrong or unclear.
var maybe: float? = text.toFloat()    # signal optional explicitly
var tokens: List(Token) = []          # empty literal needs annotation
```

### 4.2 Mutability — there is no `let` ✅ ESTABLISHED

Zebra has only `var`. The compiler decides `const` vs `var` in the emitted
Zig. Don't try to signal "logically constant" via naming or comment — use it
as a constant and let the compiler emit `const`.

### 4.3 Empty-collection literals 📋 PROPOSED

```zebra
# ✓ With annotation — preferred when starting empty.
var items: List(int) = []

SEAN: WHAT ABOUT AS SUPPORTED: 
`var items = List(int)()`

# ✓ Without annotation — when there's an obvious first value.
var items = [1, 2, 3]

# ✗ Don't mix:
var items: List(int) = List(int)()    # redundant
```

### 4.4 Field declaration vs local init ✅ ESTABLISHED (QS §27 gotcha #4-5)

The rule is **mechanical** — get this wrong and the compiler errors:

```zebra
# ✓ Field declarations: type only, no init.
class Foo
    var items: List(int)
    var sb: StringBuilder
    cue init()
        items = List(int)()
        sb = StringBuilder()

# ✓ Method-body locals: must call constructor / use literal.
def foo()
    var items = List(int)()           # constructor form
    var nums = [1, 2, 3]              # literal form
    # var items: List(int)            # ERROR — uninitialised collection local
```

---

## §5. Functions and methods

### 5.1 Top-level functions ✅ ESTABLISHED (QS §4)

```zebra
def add(a: int, b: int): int
    return a + b

def greet(name: str)              # no return type → void
    print "hello, ${name}"
```

- Always-required: parens at the **call** site (`add(1, 2)`).
- Return type is annotated unless `void`. **Don't** write `: void` — omit.

### 5.2 Method modifiers ✅ ESTABLISHED

- `static def foo()` for type-associated methods (no `this`).
- For more than one static, use the **group form**:
  ```zebra
  class Foo
      static
          def create(): Foo
              ...
          def factory(): Foo
              ...
  ```
- Bare `static def` for a single static is fine but flag if a class grows a
  second; convert to group.

### 5.3 `cue init` constructor ✅ ESTABLISHED

⚠️ **No constructor overloading.** Multiple `cue init` declarations on the
same class is **not supported** — see the box below.


```zebra
class Counter
    var count: int

    cue init()                        # zero-arg ctor
        count = 0

    cue init(start: int)              # multi-arg via different name
        # No overloading. If you need multiple ctors, use static factories:
        count = start
```

⚠️ Zebra does not support constructor overloading. If you need multiple
construction shapes, use `static def make(...)` factories returning the type.

### 5.4 Named and default parameters ✅ ESTABLISHED (QS §4)

```zebra
def open(path: str, mode: str = "r", buffered: bool = true): File throws
    ...

# Call site:
open("data.txt")
open("data.txt", mode: "w")
open("data.txt", buffered: false)
```

✅ **STRICT: every boolean argument at a call site uses the named form**,
regardless of whether the parameter was declared positional or named.

> **Signature-design implication:** boolean parameters tend to read more
> naturally at the **end** of the parameter list, so callers can use
> positional args for the leading "real" arguments and named args only
> for the booleans (`open(path, mode, buffered: false)` — not `open(true,
> path, mode)`).  This isn't a rule, but it's the path of least friction
> when the named-bool rule meets a partial-named call site.
```zebra
# ✓ Canonical:
parse(src, strict: true)
serve(handler, reuse: false)

# ✗ Non-canonical (sweep target):
parse(src, true)
serve(handler, false, true)
```

Why: positional booleans are a known cross-language footgun, and the named
form is identical at the call site except for the label. Sweep regex:
`\([^)]*,\s*(true|false)\s*[,)]` flags candidate sites for review.

### 5.5 `def name(): T` always ✅ RESOLVED — see §1 Q2

Always declare with explicit parens.  Drop the no-paren shorthand
(`def name: T`).  Sweep target: 38 occurrences across 17 files.
---

## §6. Classes vs structs vs enums vs unions

### 6.1 The decision tree ✅ ESTABLISHED

| You have...                                | Use         |
|--------------------------------------------|-------------|
| Reference identity / shared state / large object | `class`  |
| Small, copy-by-value record (rule of thumb: ≤ ~6 fields, ≤ 64 bytes) | `struct` |
| Closed list of named cases, no payload     | `enum`      |
| Closed list of named cases, payloads vary  | `union`     |

**Why the struct size rule of thumb (~6 fields / ~64 bytes):** structs are
copied on assignment, return, and parameter passing.  Above ~64 bytes
(roughly the L1 cache line on most x86_64), each copy starts costing
real cycles; above ~6 fields, the value is harder to read at a glance
than a class with named accessors.  Both numbers are heuristics, not
hard limits — a 10-field struct of `int`s (80 bytes) is fine if it's
copied rarely; a 3-field struct of large strings is questionable if
copied in a hot loop.  When in doubt, prefer `class` for "object-like"
data and `struct` for "value-like" data.

### 6.2 Recursive shapes use union + `^T` ✅ ESTABLISHED (QS §22)

```zebra
union Expr
    num_:  float                  # primitive payload — inline
    bin:   ^Bin                   # recursive — heap-boxed
    unary: ^Un

struct Bin
    var op:    char
    var left:  ^Expr
    var right: ^Expr
```

Three iron rules:
- `^T` only on **struct, primitive, or union** payloads.
- `^ClassName` is a **compile error** (BUG-078). Classes are already
  references; double-boxing is illegal.
- Inside a `branch on Variant as r`, `r` has type `T` — the pointer is
  **transparent**, never `*T`.

### 6.3 `struct except` for immutable update ✅ ESTABLISHED (QS §6, §7)

```zebra
def withOwner(name: str): Config
    var c = this except
        owner = name
    return c
```

Use `except` for any logically-immutable struct. Avoid mutating struct fields
in place when an `except` copy reads more naturally — Zebra's idiom is
functional update.

---

## §7. Field access inside methods ✅ ESTABLISHED — see §1 Q1

**Canonical: `.field` shorthand.**

```zebra
# ✓ Field access:
def increment()
    .count = .count + 1
    print .count

# ✓ Constructor with shadowing param:
cue init(count: int, name: str)
    .count = count
    .name = name

# ✓ Bare access (legal, but prefer `.field` for consistency):
def total(): int
    return count + bonus            # works if no local shadows

# ✗ Non-canonical (sweep target):
cue init(count: int)
    this.count = count

# ✗ Non-canonical (sweep target):
def increment()
    this.pos = this.pos + 1
```

**Why `.field` over bare access:** if a future edit adds a local that shadows
the field name, `.field` keeps working unchanged; bare access silently
flips meaning. `.field` is the strictly safer default.

---

## §8. Optionals and nil

### 8.1 Use `if x as n` over `to!` when binding ✅ ESTABLISHED (QS §11)

```zebra
# ✓ Canonical:
if user as u
    print u.name

# ✗ Non-canonical (replaceable):
if user != nil
    print user to!.name

# ✗ Verbose:
var u = user to!
print u.name
```

`to!` is for forced-unwrap *expressions* where you've already proven non-nil
out-of-band — typically a single-line force-unwrap inside a bigger
expression. Inside an `if` test, prefer the binding form.

### 8.2 Nil-coalescing for defaults ✅ ESTABLISHED

```zebra
var name = config.name ?? "anonymous"    # ✓
```

### 8.3 Optional chaining for one-shot reads ✅ ESTABLISHED

```zebra
var n = node?.next?.value                # propagates nil
```

### 8.4 Type-check + bind combined ✅ ESTABLISHED (QS §21)

```zebra
# ✓ When LHS is optional and you want to downcast:
var maybeUser: User? = lookup()
if maybeUser is User as u
    print u.name
```

---

## §9. Error handling

### 9.1 `throws` is the default error model ✅ ESTABLISHED (QS §12)

`Result(T)` exists but is a fallback. Default to `throws`.

### 9.2 Same-file calls auto-propagate; cross-module / local-var need `?` ✅ ESTABLISHED

```zebra
# Inside a `throws` method, calling another `throws` method on `this` or
# bare-named in the same file:
def caller(): int throws
    var n = parseInt(src)             # ✓ auto-propagates
    return n + 1

# Cross-module or via local variable: explicit `?`
def caller2(p: Parser): int throws
    var t = p.nextToken()?            # ✓ explicit propagation
    return t.kind
```

### 9.3 Method-level `catch` for top-level recovery ✅ ESTABLISHED

```zebra
def runOne(src: str)
    var p = Parser(src)
    p.start()?
    var ast = p.parseExpr(0)?
    print "  ${src}  =  ${formatExpr(ast)}"
catch |e|
    print "  ${src}  -> error: ${e.message}"
```

The `catch` clauses sit at the same indent as `def`, **after the body**.
This is the canonical recovery boundary for entry-point methods.

### 9.4 Inline `catch fallback` for expression-level defaults ✅ ESTABLISHED

```zebra
var n = parseInt(s) catch 0           # ✓ when a fallback is genuinely correct
```

### 9.5 `raise` formatting

#### Compiler code (`src/`, `selfhost/`) ✅ MANDATORY — closed taxonomy

Every `raise` in compiler code uses one of the following tag forms:

| Tag         | When                                                |
|-------------|-----------------------------------------------------|
| `lex:`      | Tokenizer / lexer errors                            |
| `parse:`    | Parser errors                                       |
| `resolve:`  | Resolver / scope errors                             |
| `tc:`       | Type-checker errors                                 |
| `cg:`       | Codegen errors                                      |
| `oom`       | Allocation failure (no colon — bare tag)            |
| `abort`     | User-requested abort                                |
| `panic`     | Programmer-error / unrecoverable                    |
| `internal`  | "Should not happen" / compiler bug surfaced as error|

```zebra
# ✓ Canonical:
raise "lex: unexpected character"
raise "parse: missing ')'"
raise "tc: type mismatch", TypeMismatch(expected, actual)
raise "internal: unreachable codegen path"

# ✗ Non-canonical — unknown tag (sweep target):
raise "compile: oh no"
raise "something failed"
```

The taxonomy is **closed** — anything outside the table fails sweep
review.  Sweep predicate: `raise "<word>:` where `<word>` ∉ the closed
list, plus untagged `raise "..."` strings whose first word isn't `oom` /
`abort` / `panic` / `internal`.

#### Stdlib + user code ❓ DEFERRED

No rule yet.  The codebase doesn't have enough `raise` sites in stdlib
modules (`Http`, `Json`, `File`, `Tcp`, etc.) to know what tags will be
load-bearing.  Write tags when they help; don't when they don't.

Re-open when:
- Stdlib `raise` site count crosses ~50 (currently well below).
- A third-party Zebra package surfaces "I can't tell where this error
  came from" friction.
- Sean has a perspective on stdlib's natural error categories.

---

## §10. Pattern matching

### 10.1 Two forms, one rule ✅ ESTABLISHED (QS §9)

- **Single variant + bind payload** → `if x is Union.variant as r`
- **Multi-variant dispatch** → `branch x ... on Union.v as r`

```zebra
# ✓ Single variant:
if e is Expr.member as m
    return genMember(m)

# ✓ Multi-variant:
branch e
    on Expr.int_ as n
        return n
    on Expr.str_ as s
        return s.len
    else
        pass
```

### 10.2 `branch` exhaustiveness ✅ ESTABLISHED

A `branch` without an `else` must cover every variant. With an `else`, the
fallback handles the remainder. Choose `else pass` (on its own line — see QS
§27 gotcha #1) when the remainder is genuinely a no-op.

### 10.3 Struct-field patterns 📋 PROPOSED

```zebra
branch p
    on Point(x: 0, y: 0)
        print "origin"
    on Point(x: 0)
        print "on Y axis"
    else
        print "elsewhere"
```

Use sparingly — these are useful for small, finite-shape structs (Point,
Color). For complex structs prefer guard expressions inside arms.

For `guard ... else` (the early-return form, distinct from match-arm
guards), see QUICKSTART §13 ("guard (early return on nil/false)").  For
match-arm guards inside `branch on ...`, see QUICKSTART §13's branch
struct-pattern subsection — guard expressions can attach to individual
arms.

---

## §11. Strings

### 11.1 Interpolation over concatenation ✅ ESTABLISHED (QS §14)

```zebra
# ✓ Canonical:
var msg = "${count} items in ${name}"

# ✗ Non-canonical when interpolation works:
var msg = count.toString() + " items in " + name
```

### 11.2 StringBuilder for hot paths and loops ✅ ESTABLISHED

Threshold rule: if you're concatenating in a loop, or building output longer
than ~3-4 segments, use `StringBuilder`.

```zebra
var sb = StringBuilder()
for tok in tokens
    sb.append(tok.text)
    sb.append(" ")
return sb.build()
```

### 11.3 String literal forms ✅ ESTABLISHED

| Form         | Use case                                | Interpolation? |
|--------------|-----------------------------------------|----------------|
| `"..."`      | Default                                 | ✅              |
| `'...'`      | Same as `"..."` (Zebra-only)            | ✅              |
| `r"..."` / `r'...'` | Regex, Windows paths             | ❌              |
| `"""..."""`  | Multi-line literals (HTML, SQL)         | ❌              |
| `c'x'`       | Single Zig `u8` char literal            | n/a            |

✅ **`"..."` is the primary form.** Switch to `'...'` *only* when the
string contains an unescaped `"` you'd otherwise have to escape:

```zebra
# ✓ Default — double-quoted:
var name = "Alice"
var msg = "hello, ${name}"

# ✓ Single-quoted when content contains `"`:
var html = '<a href="/">home</a>'

# ✗ Single-quoted with no `"` in content (sweep target):
var name = 'Alice'
```

**Edge case — both `"` and `'` appear in the content:** the "use the
delimiter your content doesn't contain" rule doesn't apply when the
content has both.  In that case you have to escape one of them.  Pick
the form that needs **fewer** escapes:

```zebra
# Content has both " and ' AND uses ${name}:
# Option A — outer "..." with escaped inner ":
var msg = "Then he said, \"Stop it, ${name}\", that's mine!"

# Option B — outer '...' with escaped inner ':
# (interpolation works in single-quoted strings too — see QS §14)
var msg = 'Then he said, "Stop it, ${name}", that\'s mine!'
```

Either is canonical.  Option A is preferred when in doubt — keeps the
default `"` family.  Triple-quoted (`"""..."""`) won't help here because
it doesn't interpolate (QS §14).


Why: triple-quoted form (`"""..."""`) makes `"` the delimiter family;
the rule is mechanical (one decision: does the string contain `"`?).

### 11.4 `c'x'` for char comparisons ✅ ESTABLISHED

```zebra
# ✓ In tokenizers and char-by-char loops:
if c == c' ' or c == c'\t'
    continue
```

This is a Zig `u8` literal. Don't compare a `char` against a 1-char string.

> **Note on the question `str[0] = c" "`:** two issues. (1) The char-literal
> syntax is `c'x'` (single quotes), not `c"x"` (double quotes) — `c"…"`
> is not a recognised literal form. (2) `str` is `[]const u8` (immutable
> string slice — see QS §3), so `str[0] = …` would assign through a
> const slice, which is rejected.  For mutable byte content, use
> `StringBuilder` (it owns the buffer and lets you `append` / mutate).

---

## §12. Collections and iteration

### 12.1 Construction ✅ ESTABLISHED

- Locals — literal form preferred when there's a known initial set:
  `var nums = [1, 2, 3]`. Constructor when starting empty:
  `var items = List(int)()`.
- Fields — type-only declaration, init in `cue init`. (See §4.4.)

### 12.2 Iteration ✅ ESTABLISHED (QS §13)

```zebra
for item in items                # plain
for i, item in items             # with index
for k, v in dict                 # HashMap entries
for i in 0 to n                  # numeric range
for i in 0 to n step 2           # with stride
```

⚠️ `for-else` is fully supported only on `List` iteration. HashMap, string
split, chars — `else` is silently dropped (deferred work). Don't write
`for-else` over those iterators yet.

> **Forward-looking idea (Sean, 2026-05-04):** the `for…else` keyword is
> famously confusing in Python — `else` reads as "alternative" but
> actually means "loop ran to completion without `break`."  A possible
> rename to `for…exited` (or `for…completed`) would make the semantics
> obvious at a glance.  Listed in §22 as an open language proposal.

### 12.3 Don't fake tuples with `List(T)` out-params ⚠️ COMPILER-DRIVEN

`examples/pratt_calc.zbr:206-222` returns two ints via two `List(int)`
out-params. That's a workaround for missing tuple returns.

📋 **Until tuple returns land:** prefer a small `struct` or a class. Mark
the workaround in code with `# TODO(zebra-tuples)` so a sweep can clear it.

```zebra
# ✗ Workaround we should retire:
def infixBp(kind: TokKind, left_out: List(int), right_out: List(int))

# ✓ Idiom in the meantime:
struct BpPair
    var left: int
    var right: int
def infixBp(kind: TokKind): BpPair
    if kind == TokKind.plus
        return BpPair(10, 11)
    ...
```

---

## §13. Compiler-limit-driven patterns (NOT canonical style)

These patterns exist because the compiler currently can't express the natural
form. They are workarounds — when each underlying bug clears, the rule flips
to the natural form. **Sweep the codebase when each lands.**

📋 **Tracking:** each item in this section that's a real compiler limitation
(not just a stale code pattern) should get a tracking BUG-XXX filed against
the **0.13 syntax-cleanup window** (per `project_zebra.md` release table:
*"0.13 — Syntax & ergonomics cleanup"*). When 0.13 closes its bugs, sweep
the codebase mechanically: each rule in this section becomes a single grep.

### 13.1 `this.field = this.field + 1` instead of `this.field += 1` ⚠️ — BUG-111

Verified: zero occurrences of `this.field += 1` across the entire codebase.
The compound-assign form on `this.X` (and presumably `.X`) is broken or
unsupported.  Filed as **BUG-111** against the 0.13 syntax-cleanup window.
Until fixed:

```zebra
# Current workaround:
this.pos = this.pos + 1
```

Once fixed: rewrite to `this.pos += 1`. **Don't enshrine the verbose form
as style.**

### 13.2 Type-annotating substring slices ⚠️ — BUG-113

Filed as **BUG-113** against the 0.13 syntax-cleanup window.
`pratt_calc.zbr:134` — comment from the file itself:
> "the compiler's TC currently loses the slice's str type once it passes
> through a `var`, so we annotate explicitly to guide `.toFloat()` to the
> right dispatch."

```zebra
# Workaround:
var text: str = this.src[start..this.pos]
var maybe: float? = text.toFloat()

# Future canonical:
var maybe = this.src[start..this.pos].toFloat()
```

### 13.3 `0 - x` for unary negation — RESOLVED: not a workaround

Verified 2026-05-04: unary `-x` works on `int` and `float`. The `0 - x` and
`0.0 - x` forms in `pratt_calc.zbr:304` and elsewhere are unnecessary. Plain
sweep target — replace with `-x`. Not compiler-driven.

### 13.4 Method-chain temporaries in expression position ⚠️ — BUG-027 (partial)

Tracked as **BUG-027** in `BUGS.md`.  Status as of 2026-05-04 is mixed:
the var-init / return / assignment positions were fixed (commits de0ec8e
+ 8c16fd9 via `hoistCallChain`); the `BUGS.md` entry says
expression-position (call args, compound expressions) **remains open**,
while `NEXT_STEPS.md` reference table says BUG-027 was fully closed
2026-04-23 via labeled blocks.  These two disagree.

📋 **Verification action:** before the 0.13 sweep, write a one-line
reproducer for `process(makeConfig().withOwner("Foo"))` and confirm it
compiles + runs.  If yes, update QS §27 gotcha #7 + close §13.4 here.
If no, BUG-027 reopens specifically for the expression-position arm.

Currently:
```zebra
# WORKS — var-init / return / assignment:
var c = makeConfig().indented().withOwner("Foo")

# NEEDS MANUAL TEMP — call argument position:
var c0 = makeConfig().indented()
process(c0.withOwner("Foo"))
```

When BUG-(method-chain-expression-position) lands: sweep manual temps in
`test/` and selfhost.

### 13.5 `selfhost/*.zbr` uses `class Main` ⚠️

Top-level `def main()` is now supported. Selfhost wasn't ported. Sweep when
no other in-flight changes block it.

### 13.6 Selfhost uses `this.` everywhere — see §1 Q1 ⚠️

If Q1 resolves to (a) bare access, this becomes a sweep target. Listed here
so the sweep is mechanical: grep `this\.` inside method bodies, remove unless
the next token shadows a parameter name.

---

## §14. Generics

### 14.1 Instantiation form ✅ ESTABLISHED (QS §17)

```zebra
var s = Stack(int)()                  # type arg, then ctor args
var p = Pair(str, int)("k", 1)
```

### 14.2 Constraint clauses ✅ ESTABLISHED

```zebra
class SortedList(T where T implements Comparable)
    ...
```

Full form (`T where T implements X`), not the shorthand `T where Comparable`.

---

## §15. Lambdas

### 15.1 Implicit capture is the default ✅ ESTABLISHED (QS §19)

Free variables auto-close. Don't write a `capture` block unless you need
**persistent per-instance state across frames** (the GUI case in QS §30).

```zebra
# ✓ Implicit capture:
var counter = 0
var bump = def()
    counter += 1

# ✓ Explicit capture only when needed:
Gui.run("App", 800, 600, def(g: Gui)
    capture
        var state = AppState()       # allocated once, reused per frame
    state.tick()
    state.render(g)
)
```

### 15.2 Expression vs statement-body lambdas ✅ ESTABLISHED

```zebra
# ✓ Expression form for one-liners (predicates, comparators):
items.any(def(x) = x > 0)
items.sort(def(a, b) = a.id - b.id)

# ✓ Statement form when the body is multi-statement:
var consume = def(x: int)
    log("seen", x)
    process(x)
```

---

## §16. Contracts

### 16.1 Use them ✅ ESTABLISHED (QS §24)

Contracts are Zebra's **identity feature**. They emit runtime checks by
default; `--turbo` strips them for release.

```zebra
def sqrt(x: float): float
    require
        x >= 0.0
    ensure
        result >= 0.0
        result * result <= x + 1e-9
    ...
```

### 16.2 What deserves a contract 📋 PROPOSED

- **`require`** — use on public functions when invalid input is a *caller
  bug* (programmer error), not a runtime condition that user input might
  legitimately produce.  Example: `require x >= 0` on a `sqrt(x)` is right;
  `require name != ""` on a function that gets called with form-input
  strings is wrong (use a `throws` error instead — empty input is a
  user-data condition, not a caller bug).
- **`ensure`** — use when the post-condition is a load-bearing invariant
  callers will rely on.  Example: a sort function ensures
  `result.sorted()`.
- **`invariant`** — use on classes/structs that have reachable-but-illegal
  states the methods must protect.  Example: a `BankAccount` with
  `invariant balance >= 0`.

Don't write a contract that the type system already enforces.  Two
non-examples:

```zebra
# ✗ Type system already guarantees this — the param can never be nil:
def f(x: int)
    require
        x != nil          # x is `int`, not `int?` — always non-nil

# ✗ Same for non-optional class params — the type guarantees non-nil:
def g(user: User)
    require
        user != nil       # `User` (not `User?`) is non-nil by construction
```

### 16.3 `old` snapshots ✅ ESTABLISHED

Use `old expr` in `ensure` when the parameter is mutated or shadowed inside
the function and you need the original value:
```zebra
def increment(n: int): int
    ensure
        result == old n + 1
    return n + 1
```

---

## §17. Reflection — use sparingly ✅ ESTABLISHED (QS §25)

- **Tier 1** (`Reflect.className`, `fieldNames`, `fieldTypes`) is zero-cost
  when unreferenced. Use freely for debug printers, dev-loop logging.
- **Tier 3** (`@reflectable` + `Json.parseStrict`) is the sanctioned path for
  type-safe JSON deserialisation. Don't write hand-rolled `Json.parse` +
  field-by-field copy code — it's strictly worse.

📋 **Don't use Tier 1 in business logic.** *(PROPOSED — needs refinement;
Sean has flagged the line as deserving a sharper rule before promoting.)*
Switching on field names is brittle and a smell. If the runtime needs to
dispatch by name, file a feature request — there's likely a missing
language feature.

---

## §18. Memory and arenas ✅ ESTABLISHED (QS §28)

- **Default**: do nothing. The program-wide arena handles everything.
- **Wrap in `arena { ... }`** when:
  - Processing many large files in a loop.
  - A single batch operation produces large temporaries you don't need
    after.
- **The copy-out idiom**:
  ```zebra
  var summary = ""
  arena
      var src = File.read("data.txt")
      summary = summarise(src)        # _str_concat copies into outer arena
  print summary                       # safe
  ```
- **Don't** assign a slice from inside the arena to an outer variable —
  the slice's backing buffer is freed when the block exits, leaving the
  outer reference dangling.  **Workaround: force a copy into the outer
  arena.**  Any operation that allocates fresh memory at the assignment
  site does this:

  ```zebra
  # ✗ DANGLING — outer ref points at freed sub-arena memory:
  var name: str = ""
  arena
      var src = File.read("config.txt")
      name = src                       # bare assignment — borrows the slice

  # ✓ COPY-OUT via concat — the empty-string concat triggers a fresh alloc
  # in the *outer* arena, so `name` owns the bytes when the sub-arena dies:
  arena
      var src = File.read("config.txt")
      name = "" + src                  # `_str_concat` allocates outward

  # ✓ COPY-OUT via String constructor / explicit dup helper:
  arena
      var src = File.read("config.txt")
      name = String(src)               # if available; verify in-stdlib

  # ✓ COPY-OUT via builder:
  arena
      var src = File.read("config.txt")
      var sb = StringBuilder()
      sb.append(src)
      name = sb.build()                # builder owns its own buffer
  ```

  The general rule: **anything that allocates** (concat, builder,
  constructor) at the boundary copies; bare slice assignment doesn't.
  When in doubt, use the `"" + src` idiom — it's explicit about
  triggering a fresh allocation.

  > **Forward-looking (2026-05-04):** Sean's idea — reuse the channel
  > receive operator `<-` for arena boundary copy-out, on the
  > generalization that "`<-` means *ownership transfer across a
  > semantic boundary*" (channels cross thread boundaries; this would
  > cross arena/scope boundaries).  Syntax would become
  > `name <- src`, replacing the `"" + src` magic-concat idiom with a
  > first-class, grep-friendly token.  Disambiguation is type-driven
  > (RHS `Chan(T)` → channel receive; otherwise → scope copy-out).
  > Listed in §22 — needs design work on deep-copy semantics, recursive
  > copy depth, and per-type cost model before it can land.

---

## §19. Comments

### 19.1 What to skip ✅ ESTABLISHED (per global CLAUDE.md)

- Restating what the code says.
- "// removed X" stubs — just remove.
- Tracking issue references that rot (`# fix for issue #123`) — those belong
  in commit messages.

> **Deferred:** the positive "what to comment" rule (file headers, section
> dividers, method docstrings) needs a high-level codebase pass first —
> selfhost files vary widely and an automated summary pass would help
> calibrate the rule before it's enforced.  Listed in §22.

---

## §20. Anti-patterns checklist (sweep targets)

When the guide is finalised, each of these becomes a grep / lint check.

| Anti-pattern                                         | Sweep target                      | See |
|------------------------------------------------------|-----------------------------------|-----|
| `this.field` instead of `.field`                     | Replace with `.field`             | §1 Q1, §7 |
| `if x != nil` followed by `x to!`                    | Replace with `if x as n`          | §8.1 |
| `count.toString() + " items"` style concat           | Replace with `"${count} items"`   | §11.1 |
| `_underscorePrefix` on **new** fields                | Don't add; existing left as-is    | §1 Q3, §21 Q-d |
| `def name: T` no-paren form                          | Convert to `def name(): T`        | §1 Q2 |
| `class Main` + `static def main` in new code         | Replace with `def main()`         | §2.4 |
| `List(int)` out-params instead of struct return      | Refactor to struct                | §12.3 |
| `^ClassName` in union variants                       | Compile error — remove `^`        | §6.2 |
| `0 - x` / `0.0 - x` instead of `-x`                  | Replace                           | §13.3 |
| `: void` return annotation                           | Drop                              | §5.1 |
| Bare `raise "msg"` with no `tag:` prefix             | Add tag                           | §9.5 |
| `for-else` over HashMap/chars/split                  | Convert to manual sentinel        | §12.2 |
| Positional `true` / `false` in call args             | Named form: `flag: true`          | §5.4 |
| `'string'` with no `"` in content                    | Convert to `"string"`             | §11.3 |

---

## §21. Open question resolutions (2026-05-04)

The four §21 calls are now resolved.  Each links to the section it modifies
and a one-line rationale.

### Q-a — Named-arg-for-bools: **STRICT** ✅

Any boolean literal (`true` / `false`) passed as a call argument uses the
named form, regardless of position.  The named form
(`open(path, buffered: false)`) is canonical regardless of whether the
parameter was declared positional or named.

- **Sweep regexes (use both):**
  - First-or-only positional: `\b\w+\(\s*(true|false)\s*[,)]`
  - Second-or-later positional: `\([^)]*,\s*(true|false)\s*[,)]`
- **Why:** `parse(true)` is just as ambiguous as `parse(src, true)` —
  the rule has to cover any positional bool, not just second-and-later.
- **Updates:** §5.4 rephrased from "recommend" to "always."

### Q-b — `tag:` prefix on `raise`: **MANDATORY for compiler code only; deferred for stdlib** ✅

**Compiler code** (`src/`, `selfhost/`) — the rule is mandatory and the
taxonomy is closed:
- Phase tags: `lex:` / `parse:` / `resolve:` / `tc:` / `cg:`
- General-purpose tags (when phase doesn't apply): `oom`, `abort`, `panic`, `internal`

Anything outside this list fails sweep review.  Sweep predicate is now
mechanical: `raise "<word>:` where `<word>` ∉ the closed list, OR `raise
"<text>"` where `<text>` doesn't begin with one of the general-purpose
tags.

**Stdlib + user code** — **rule deferred.**  The codebase doesn't yet
have enough `raise` sites in stdlib to know what tags will be load-
bearing.  Locking in a taxonomy now risks calcifying one that future-us
would carve differently.  Revisit when stdlib grows past ~50 `raise`
sites or when a third-party Zebra package adds friction.

- **Why this split:** compiler phases are obvious and stable
  (`lex`/`parse`/`tc`/`cg` aren't going anywhere).  Stdlib error
  vocabulary is genuinely unsettled — `Http`, `Json`, `File`, `Tcp` each
  have their own natural error categories that haven't been audited.
- **Updates:** §9.5 split into compiler-mandatory + stdlib-deferred
  subsections.  Sweep predicate is mechanical for the compiler half;
  the stdlib half explicitly says "no rule yet."

### Q-c — `"..."` vs `'...'`: **`"..."` primary; `'...'` only for `"`-heavy strings** ✅

Default to double-quoted.  Switch to single-quoted only when the string
contains an unescaped `"` you'd otherwise have to escape (e.g.
`'<a href="...">'`).

- **Codebase verification (2026-05-04):** selfhost has 4,047 double-quoted
  strings vs 168 single-quoted (~24:1).  Test files: 106 single-quoted
  occurrences across 11 files.  Total sweep size ~270 strings — small
  enough to be a one-pass conversion.
- **Why:** triple-quoted form (`"""..."""`) establishes `"` as the
  delimiter family.  The rule is mechanical (one decision: does the
  string contain `"`?).
- **Sweep target:** `'...'` strings containing zero `"` characters →
  convert to `"..."`.
- **Updates:** §11.3 rephrased.

### Q-d — Real `private` / `internal` keywords: **DEFER to 0.14 / 1.0** ✅

BUG-115 stays open as a language proposal but is not on the 0.13 roster.

- **Why:** 0.13 already has a packed roster (BUG-111/112/113, four
  sweeps, book docs).  Adding visibility keywords is a meaningful
  language change requiring design work — module-private semantics,
  interaction with partial files, static-method rules — that doesn't fit
  in a "syntax cleanup" milestone.
- **Style guide stance:** **no new `_` prefixes** in code authored from
  2026-05-04 onward.  **Existing `_` prefixes stay** until BUG-115
  resolves.  Avoids a churn-now-rewrite-later cycle if 0.14 lands real
  privacy keywords (the existing prefixes might map onto them
  naturally).
- **Sweep target (later, not now):** decided post-BUG-115.  If 0.14
  lands `private`, sweep `_field` → `private field`.  If BUG-115 is
  closed wontfix, sweep `_field` → `field`.
- **Re-open trigger:** if a real callsite (a third-party Zebra package,
  or an embedded-target review) flags lack of privacy as friction,
  revisit and prioritise for 0.14.

---

## §22. Remaining open questions for Sean

Smaller calls still pending Sean's review:

### Resolved smaller calls

- **§3.2 (boolean naming):** ✅ **STRONGLY RECOMMENDED.** Predicate methods
  and boolean fields prefix with `is`/`has`/`should`/`can`, or read as a
  question.  Not strictly enforced (some legacy or domain-specific names
  may legitimately not match), but reviewers should flag.  §3.2 updated.
- **§3.3 (abbreviated names — clarification):** the rule said "fields and
  method parameters spell out the full name" (`tokens`, not `tks`;
  `position`, not `p`).  Renamed for clarity in §3.3.

### Deferred — codebase pass needed first

- **File header comments (was §19.1):** the canonical "one paragraph,
  what + why" rule needs calibration against selfhost — files vary
  widely.  Plan: auto-generate file-header summaries via an LLM pass over
  every `.zbr` in `selfhost/` + `examples/`, then have Sean curate the
  output, then promote the rule.  Listed as a future low-CPU work item.

### Forward-looking language proposals (Sean, 2026-05-04)

These came up in style-guide review.  They're not style decisions — each
is a potential 0.13/0.14 language change.  Listed here so they don't get
lost; each warrants a separate design write-up if Sean wants to advance
it:

| Proposal | Where it came up | Sketch |
|----------|-----------------|--------|
| `catch \|e\|` → drop the pipes (`catch e`) | §9.3 | Simplifies to a single delimiter; matches modern lang feel.  Parser change; no semantic shift. |
| `for…else` → `for…exited` (or `for…completed`) | §12.2 | Avoids the Python-style "else looks like alternative" footgun.  Tokenizer + parser rename; backward-compatibility break (or accept both during transition). |
| `raise` tag enforcement via enum/union type | §9.5 | Make the closed taxonomy a real type instead of a string convention.  `raise CompilerErr.lex("unexpected character")` would be type-checked.  Bigger change (touches error model); probably 0.14+. |
| Tuple returns (prioritize sooner) | §12.3 | Currently in `concept_zebra-warts` W6 / 1.0 milestone.  Sean flagged as worth bringing forward — would close the BUG-091-class workarounds (out-param `List(int)` boxes). |
| `<-` as scope-boundary copy-out | §18 | Reuse the channel receive operator for arena copy-out: `name <- src` instead of `name = "" + src`.  Generalization: `<-` means "ownership transfer across a semantic boundary" (channels cross threads; this crosses scope/arena).  Disambiguation: type-driven (RHS `Chan(T)` → channel receive; else → scope copy).  Open questions: deep-copy depth for `List(T)` / classes / nested structs; per-type cost model; OOM failure semantics.  Needs a small design doc before it can land. |

---

## §22. Process — once this guide is approved

1. Lock the rules. Move from `docs/STYLE_GUIDE_DRAFT.md` →
   `STYLE_GUIDE.md` at repo root.
2. Sweep order (lowest-blast-radius first):
   1. `examples/` (~6 files)
   2. `test/` (~150 files; mechanical changes only)
   3. `selfhost/*.zbr` (last; round-trip via bootstrap_check.sh after)
3. After each sweep batch: `zig build test` + `zig build update-selfhost` +
   `tools/bootstrap_check.sh` to confirm no regressions.
4. Each compiler-limit-driven rule (§13) gets a tracking BUG-XXX so when the
   bug closes, the sweep is one grep.

---

*End of draft. Sean: please review section by section. Suggestion: start
with §1 (the three Open Questions); the rest is downstream.*
