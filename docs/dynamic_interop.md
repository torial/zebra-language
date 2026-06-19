# Dynamic-language interop in Zebra

Status: **`Reflect.hostKind` shipped (2026-06-19); runtime-dynamic layer designed, deferred.**

This note records the architecture for integrating dynamically-typed source
languages (Luau, JavaScript/NodeJS, Python, …) into statically-typed Zebra, so
the thread isn't lost. It was driven by the GameEngine Luau→Zebra translator
needing `type(x)`/`typeof(x)`, but the design is deliberately language-neutral.

## The problem

Dynamic languages carry runtime-typed values; Zebra is statically typed and
compiles to Zig. Interop needs two things:

1. a **representation** for "a value whose type may not be known until runtime", and
2. **operations** on it: type queries (`type(x)`), field access (`x.foo`),
   calls (`x()`), coercing arithmetic.

The guiding constraint: **the compiler must not know any source language.**
Adding Luau, JS, or Python support must not require a Zebra release. So
language knowledge lives in the *consumer* (the engine / bridge), not in
zebra-language.

## Layering (who owns what knowledge)

| Layer | Owns | Lives in | Changes per new language? |
|---|---|---|---|
| Substrate reflection | "what Zig category is this value" | **zebra-language** (1 builtin) | **No** |
| Protocol contract | the `Dynamic` interface shape | **zebra-language** (1 stdlib module) | **No** |
| Language semantics | Luau/JS type names, field/call behavior | **consumer** (GameEngine, NodeJS bridge) | only that consumer |

## Layer 1 — `Reflect.hostKind(x)` (SHIPPED)

A language-neutral compiler builtin. Returns the **Zig substrate category** of
`x`'s compile-time type as a string:

```
"nil" | "bool" | "int" | "float" | "string" | "function" | "ref"
```

- Implemented by extending the existing `Reflect` namespace (reuses its
  resolver/TC recognition). TypeChecker: returns `str`. CodeGen
  (`genReflectCall`, both `src/CodeGen.zig` and `selfhost/CodeGen.zbr`): emits a
  comptime `switch (@typeInfo(@TypeOf(x))) { … }`.
- Resolved by Zig at **comptime** — zero runtime cost. `@TypeOf` does **not**
  evaluate its operand, so `Reflect.hostKind(f())` is side-effect-safe.
- String detection mirrors the preamble: a pointer is `"string"` if its child is
  `u8` **or** an array of `u8` (uncoerced string literals are `*const [N:0]u8`).
- Why a builtin and not a library function: getting `@TypeOf` of an arbitrary
  statically-typed argument *without an explicit type argument* can't be done
  from user-land. Zebra generic functions need the explicit type arg at the call
  site (`identity(int)(x)`), and the `zig'…'` escape hatch can't safely embed a
  non-trivial argument expression. `hostKind` is the one irreducible primitive.

These categories describe **Zig's** type system, not any source language, so
they correctly belong to the compiler and are frozen.

## Layer 3 — per-language name tables (consumer side)

The consumer maps the neutral category → its language's type string. GameEngine
ships (in `zbra/luaucompat.zbr`, not zebra-language):

```
def luaTypeName(k: str): str          # k = Reflect.hostKind(x)
    if k == "int" or k == "float": return "number"
    if k == "bool":                return "boolean"
    if k == "string":              return "string"
    if k == "function":            return "function"
    if k == "nil":                 return "nil"
    return "table"
```

The translator emits `luaTypeName(Reflect.hostKind(x))`. A future NodeJS bridge
ships its own `jsTypeName` + uses the same `Reflect.hostKind` — **no Zebra
change**.

### Known imprecision (acceptable for the gradual-port regime)

`Reflect.hostKind` answers the *static* question. Two cases it can't resolve,
both deferred to Layer 2:

- **`type` vs `typeof`**: Luau `type(instance)` is `"userdata"` but
  `typeof(instance)` is `"Instance"`. The translator maps both to the same
  helper; `hostKind` returns `"ref"` for both → `luaTypeName` picks `"table"`.
  Precise per-object naming needs the runtime `Dynamic` layer.
- **Genuinely runtime-dynamic values** (a variable that may hold a number *or* a
  string at runtime): `hostKind` reports the *static* type. A boxed dynamic value
  needs Layer 2's union + `typeName()`.

In the current GameEngine "gradual port" regime — where the translator maps Luau
values to native Zebra types wherever it can — these cases are rare, so the
comptime path covers ~all of `type(x)`.

## Layer 2 — runtime-dynamic values (DESIGNED, DEFERRED)

Build this only when a real runtime-dynamic case forces it (faithful Lua
semantics, or a value whose type genuinely varies at runtime). Two pieces:

### 2a. A per-language tagged-union value type (the Lua `TValue` model)

```
union LuaValue                        # consumer-side; JS would have JsValue
    Nil
    Bool: bool
    Number: float
    Str: str
    Table: ^LuaTable
    Function: ^LuaFunc
    Userdata: ^Instance               # Roblox typeof → "Instance"
```

`type(x)`/`typeof(x)` becomes a `branch x` over the variant — exact, including
the `userdata`/`Instance` distinction `hostKind` can't make. This is Zebra's
existing union+`branch` machinery; no compiler change.

### 2b. A `Dynamic` interface (the interop protocol — GraalVM `InteropLibrary` /
.NET `IDynamicMetaObjectProvider`)

Declared **once** in a zebra-language stdlib module (e.g. `dynamic`), language-
neutral:

```
interface Dynamic
    def typeName(): str               # language-specific type string
    def getField(name: str): Dynamic
    def setField(name: str, v: Dynamic)
    def call(args: List(Dynamic)): Dynamic
    def index(i: Dynamic): Dynamic
    # + coercions: asBool/asNumber/asStr
```

Each backend implements it: `class LuaTable implements Dynamic`,
`class JsObject implements Dynamic`, `class Instance implements Dynamic`.
Primitives go through the union (2a), **not** the interface — Zig can't attach a
vtable to `i64`/`bool`, so boxing primitives into the interface would defeat the
point.

`Reflect.hostKind` of a `Dynamic`/`LuaValue` returns `"ref"`; the front door then
dispatches to the impl's `typeName()`. So the builtin (static path) and the
interface (dynamic path) compose: comptime when the type is known, vtable when
it isn't.

### Why not the pure-`dynamic` (.NET DLR) model

A `dynamic`-everywhere model (every value a boxed tagged value with runtime
member binding + call-site caching) is maximally compatible but the heaviest to
build and the slowest — wrong for a perf-sensitive target like the game. Zig's
comptime lets the static-known path (the common case) be free, which the DLR
couldn't do. So: comptime fast-path + union/interface for true dynamics, not a
uniform runtime binder.

## Decision record

- **Regime: gradual port**, not faithful-dynamic. Translator maps to native
  Zebra types; dynamics are the exception. (Revisit if Zebra becomes a general
  polyglot host — the NodeJS-bridge idea points that way.)
- **Shipped now:** `Reflect.hostKind` (Layer 1) + GameEngine `luaTypeName`
  (Layer 3).
- **Deferred:** `LuaValue` union (2a) + `Dynamic` interface (2b) until a real
  runtime-dynamic case needs them.
