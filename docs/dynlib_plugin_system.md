# DynLib Plugin System

**Status:** Complete (2026-05-16). Both the bootstrap Zig compiler and the selfhost Zebra compiler emit correct code. Integration test `dynlib_iface_test` passes via `zig build test`.

## What changed

Four components were added together to make the plugin system work:

1. **Interface vtable construction** — Both `src/CodeGen.zig` and `selfhost/codegen.zbr` now emit C-compatible vtable structs and shim functions when a class declares `implements IFaceName`. This was the enabling primitive; DynLib is just one consumer.

2. **Interface coercion at assignment and return** — The codegens detect when a class-constructor expression is being assigned to an interface-typed variable (or returned from an interface-pointer-returning method) and emit the fat-pointer initialization instead of the normal struct init.

3. **DynLib stdlib** — `_DynLib` struct, `_dynlib_open`, and `_dynlib_close` helpers in `selfhost/stdlib_preamble.zig`; `DynLib` registered in `src/Builtins.zig`; `DynLib.open` / `.lookup` / `.close` dispatch in both codegens.

4. **Demo + test** — `examples/hello_plugin.zbr`, `examples/plugin_host.zbr`, and `test/dynlib_iface_test.zbr`.

## Design decisions

### Duck-type vtable matching

Plugin and host independently declare identical `interface` definitions. Their vtable layouts match because both compile from the same interface declaration — no shared header file or IDL. The factory function (`export def plugin_create(): ^IGreeter`) is the only required export.

This was chosen over an IDL/registry approach because Zebra's `interface` keyword already provides the contract language, and duck-type vtable matching is how C++ shared-library ABIs work under the covers.

### Shim functions

Each `implements` declaration causes the codegen to emit a private shim function per interface method:

```zig
fn _shim_HelloGreeter_IGreeter_greet(ptr: *anyopaque, name: []const u8) []const u8 {
    return HelloGreeter.greet(@alignCast(@ptrCast(ptr)), name);
}
```

The shim bridges the vtable's `fn(ptr: *anyopaque, ...)` signature (required for type-erasure) to the concrete class's `fn(self: *ClassName, ...)` method. `@alignCast(@ptrCast(ptr))` recovers the concrete pointer from `*anyopaque`.

### `dynlib_vars` tracking (no TypeChecker changes)

`DynLib.open(...)` returns `*_DynLib` at the Zig level. The TypeChecker doesn't know about `DynLib` — tracking which local variables hold DynLib handles is done in codegen via a `dynlib_vars: StrSet` (selfhost) / `*std.StringHashMap(void)` (bootstrap) that is populated when a `var x = DynLib.open(...)` statement is compiled. This lets instance method dispatch (`lib.lookup(...)`, `lib.close()`) be recognized without threading DynLib type info through the TC.

The tradeoff: the heuristic breaks if `DynLib.open` is called in a non-trivial expression (e.g., returned from a helper and assigned to a var). For the current use case this is fine; a proper fix would add `DynLib` as a known type in `src/TypeChecker.zig`.

### `lookup` codegen

`lib.lookup(IFace, "factory_fn")` compiles to a labeled block that calls the factory:

```zig
blk_N: {
    const _fn = lib.lib.lookup(*const fn () *IFace, "factory_fn") orelse break :blk_N null;
    break :blk_N _fn();
}
```

The interface name is extracted directly from the first argument (must be a bare identifier). This yields `*IFace?` at the call site, matching the expected `^IFace?` Zebra type.

## What a maintainer needs to know

**Extending vtable shims to handle `throws` methods:** The shim template has a `throws_` branch that prefixes the return type with `anyerror!` and prefixes the inner call with `try`. Verify this still holds if the interface method uses `anyerror!T` with a non-void return type.

**^IFace? coercion:** If a class constructor is called in a position other than a direct `var x: ^IFace = ClassName()` assignment or a `return ClassName()` inside an `^IFace`-returning method, the interface coercion won't fire — the normal (non-fat-pointer) codepath runs and the Zig compiler will catch the type mismatch. The fix is to add more coercion sites in codegen.

**Full DLL round-trip testing:** The integration test (`dynlib_iface_test.zbr`) exercises vtable dispatch without loading a DLL (host and plugin in the same compilation). A true round-trip requires:
1. `zig build run -- examples/hello_plugin.zbr --emit-zig --shared` (emit + compile as shared lib)
2. `zig build run -- examples/plugin_host.zbr` with the DLL on the library path

This isn't in CI because it requires platform-specific shared-library build flags that aren't yet wired into the `Build` stdlib or `build.zig`.

**Print inference gap:** When printing the return value of an interface method directly (e.g., `print g.greet("X")`), the selfhost compiler emits `{any}` instead of `{s}` because it can't infer the return type of virtual dispatch. Workaround: capture to a typed var first (`var msg: str = g.greet("X")`). The test and demos both use this workaround.

## Files changed

| File | Change |
|------|--------|
| `src/CodeGen.zig` | Vtable shim emission; interface coercion (var + return); DynLib dispatch; `dynlib_vars` tracking; `module` field on Generator |
| `src/Builtins.zig` | `DynLib` registered as known stdlib name |
| `selfhost/codegen.zbr` | Mirrors all src/CodeGen.zig changes |
| `selfhost/stdlib_preamble.zig` | `_DynLib` struct + `_dynlib_open` + `_dynlib_close` helpers |
| `selfhost/Resolver.zbr` | `DynLib` added to `isBuiltin()` |
| `test/dynlib_iface_test.zbr` | Integration test: vtable dispatch without DLL loading |
| `examples/hello_plugin.zbr` | Demo plugin: `HelloGreeter implements IGreeter` + `export def plugin_create()` |
| `examples/plugin_host.zbr` | Demo host: `DynLib.open` + `lookup` + vtable call |
| `tools/selfhost_smoke.sh` | `smoke_run` helper + `dynlib_iface_test` entry |
| `NEXT_STEPS.md` | §10 marked complete |
