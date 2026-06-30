# Node.js native addons — `zebra --target node-addon`

Compile a Zebra source file to a Node.js native addon (`.node`) plus a `.js`
require()-shim and a `.d.ts` TypeScript declaration file. Annotate functions
with `@node_export`; the compiler emits N-API wrappers and a module registration
function so Node can `require()` and call them directly.

```zbr
# math.zbr
@node_export
def add(a: int, b: int): int
    return a + b

@node_export
def greet(name: str): str
    return "Hello, " + name + "!"
```

```bash
zebra --target node-addon math.zbr     # → math.node, math.js, math.d.ts (next to the source)
```

```js
const m = require('./math.js');         // or require('./math.node')
m.add(2, 3);        // 5
m.greet('Zebra');   // "Hello, Zebra!"
```

This document is for maintainers of the feature. User-facing syntax lives in
QUICKSTART §45; the phased plan and history are in
`wiki/pages/concepts/concept_zebra-node-addon-impl-plan.md` and
`SELFHOST_JOURNAL.md`.

## What it does

`@node_export` may sit on a **top-level `def`** or on a class method inside a
**`static` block**. The JS export name is the method name; a name exported more
than once in a module is a compile-time error.

Supported types (1.0):

| Zebra (any width)     | JS          | N-API extract / wrap |
|-----------------------|-------------|----------------------|
| `int*`                | `number`    | `napi_get_value_int64` / `napi_create_int64` |
| `float*`              | `number`    | `napi_get_value_double` / `napi_create_double` |
| `bool`                | `boolean`   | `napi_get_value_bool` / `napi_get_boolean` |
| `str` / `String`      | `string`    | `napi_get_value_string_utf8` (size-probe + alloc) / `napi_create_string_utf8` |
| `void` (return only)  | `undefined` | `napi_get_undefined` |

Any other parameter/return type, a `throws` method, an instance (non-static)
method, or a method with no body is a **compile-time error** — exports are never
silently skipped.

## How it is built

The output is produced by `zig build-lib`, using the recipe proven by the Phase 0
spike (`spike/`):

```
zig build-lib <intermediate>.zig -dynamic -lc \
    -I<node>/include/node [<node>/x64/node.lib] \
    -femit-bin=<stem>.node
```

- `-femit-bin=<stem>.node` writes the loadable addon **directly** — the `.node`
  is a shared library Node `dlopen`s; there is no rename step.
- Headers (and, on Windows, `node.lib`) come from the **node-gyp cache** — no
  vendored headers. Populate it once with `npx --yes node-gyp install`.
- Discovery order (`resolveNodeApi`): `ZEBRA_NODE_INCLUDE` / `ZEBRA_NODE_LIB`
  env overrides first, else scan `%LOCALAPPDATA%/node-gyp/Cache/<ver>/`
  (Windows) or `~/.cache/node-gyp/<ver>/` (Unix) for `include/node/node_api.h`,
  picking the lexically-greatest version directory.

## Where the code lives

Everything is gated behind node-addon mode and is a no-op in every other mode.

| Concern | Bootstrap (`src/`) | Selfhost (`selfhost/`) |
|---------|--------------------|------------------------|
| `@node_export` AST flag | `ast.zig` `Modifiers.node_export` | `Ast.zbr` `Modifiers.is_node_export` |
| Recognize the directive | `AstBuilder.zig` (`processTopDecl` + `collectMemberDecls`) | `Parser.zbr` (`PMethod`, both directive sites) + `AstBuilder.zbr` |
| N-API preamble | embedded from `selfhost/napi_preamble.zig` via `build.zig` | read at runtime via `File.read("selfhost/napi_preamble.zig")` |
| Glue + `.d.ts` emit | `CodeGen.zig` `generateNodeAddonGlue` / `emitNapiWrapper` / `generateNodeDts` | `CodeGen.zbr` `generateNodeAddon` / `napiWrapperStr` / `napiGlueStr` / `generateNodeDts` |
| CLI + build driver | `main.zig` `node_addon` Mode + `compileNodeAddon` | `main.zbr` `--target node-addon` + `MultiCompiler.node_addon` + `resolveNodeApi` |

Output ordering in the generated `.zig`: stdlib preamble → napi preamble
(`@cImport node_api.h`, `_napi_throw`, `_napi_undefined`) → module body → glue
wrappers + `napi_register_module_v1`. No `main` thunk is emitted (a `.node` has
no entry point).

## Allocator lifetime (Phase 7)

Each wrapper that marshals a string wraps its body in a per-call child
`ArenaAllocator` (the same create → swap `_allocator` → `defer deinit+restore`
idiom as `arena {}` scope blocks). String-argument buffers and any string the
callee builds are reclaimed when the wrapper returns. This is correct because
`napi_create_string_utf8` **copies** the result into V8 before the `defer`
fires. Numeric/bool wrappers allocate nothing and skip the arena.

Consequence (documented limitation): a module-level mutable value populated
*during* a call does not persist across calls — its allocation is reclaimed.
Addons are synchronous, stateless exports for 1.0.

## Tests

`tools/node_addon_test.sh` builds each `test/node_addon/*.zbr` fixture to a
`.node`, runs its `*.check.js` Node assertions, and asserts the negative fixture
(`bad.zbr`, a `List` parameter) is rejected. It passes with both `zebra.exe` and
`zebra-bootstrap.exe`. It is a standalone script — **not** part of `zig build
test` — because it needs Node + the node-gyp headers, which are not present in
every environment. Generated `.node`/`.d.ts`/`.js` are gitignored; the
`.check.js` assertion files are tracked.

## Isolation tactics

- **Mode-gated.** `emit_node_addon` / `node_addon` defaults false; all new
  codegen is behind it. `@node_export` is read only by the node-addon path.
- **Separate preamble file.** `selfhost/napi_preamble.zig` keeps the
  `node_api.h` `@cImport` out of normal builds — it is embedded as a string and
  only ever compiled into a generated addon (where the Node headers are present).
- **node-gyp cache, not vendoring.** No third-party headers in the tree; the
  `ZEBRA_NODE_*` env vars are the override/escape hatch.
- **Standalone test script.** Keeps Node + node-gyp out of the `zig build` graph.

## Known limitations / follow-ups

- **`@node_export static def` (inline) does not parse.** Put the export inside a
  `static` block instead (the directive goes on the `def` within the block), or
  use a top-level `def`. This is a parser ordering quirk (after the member
  `@`-directive loop, a `static` modifier is not re-checked), not specific to
  node-addon. Tracked in NEXT_STEPS.
- **Cross-platform (Phase 10) unverified.** Only Windows is tested. Linux is
  expected to work as-is (shared libs resolve undefined N-API symbols at
  `dlopen`); macOS will need `-Wl,-undefined,dynamic_lookup` added to the link,
  which is not yet wired in.
- **Explicit `: void` parser divergence.** It parses to `TypeRef.named{"void"}`
  in the bootstrap but `.void_` in the selfhost. The node-addon path treats both
  as void, so the feature is correct, but the two ASTs should be reconciled.
- **Out of scope for 1.0:** async/Promise, JS→Zebra callbacks, class-instance
  handles (`napi_wrap`), and collection (`List`/class) marshaling.
