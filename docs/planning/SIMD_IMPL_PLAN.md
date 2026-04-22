# SIMD Implementation Plan

**Status:** Not started. Scheduled post-1.0 (after Phase 22 cutover).  
**Reconnaissance completed:** 2026-04-21  
**Wiki concept:** `C:\Users\Sean\wiki\pages\concepts\concept_zebra-simd-design.md`

---

## Language surface (decided)

Naming: `{elementType}x{lanes}` — `f32x8`, `i16x16`, `u8x32`.  
No lexer changes needed — these are plain identifiers.

```zebra
var acc = f32x8.splat(0.0)
var w   = f32x8.load(weights[i..i+8])
acc = acc + w * f32x8.load(inputs[i..i+8])
var s = acc.sum()
```

Full surface spec and LLM dot-product example: see wiki concept page.

---

## Codegen mapping

| Zebra | Zig |
|-------|-----|
| `f32x8` type | `@Vector(8, f32)` |
| `f32x8(a,b,...)` | `.{ a, b, ... }` |
| `f32x8.splat(v)` | `@splat(v)` |
| `f32x8.load(s)` | `@as(@Vector(8, f32), s[0..8].*)` + bounds check |
| `f32x8.load_unchecked(s)` | `@as(@Vector(8, f32), s[0..8].*)` (no check) |
| `acc.sum()` | `@reduce(.Add, acc)` |
| `a.dot(b)` | `@reduce(.Add, a * b)` |
| `a.max_element()` | `@reduce(.Max, a)` |
| `a + b`, `a * b` etc. | direct (Zig vector ops are free) |

---

## Insertion points (Zig compiler — `src/`)

### `src/Builtins.zig`
- NAMES set (~line 110): add SIMD type names
- `scalarKind()` (~line 246): recognise `f32xN`/`i8xN` pattern

### `src/TypeChecker.zig`
- `builtinType()` (~line 3038): return `.simd { elem, lanes }` for SIMD names
- `inferCall()` (~line 2229): handle `f32x8(...)`, `.splat()`, `.load()`, `.sum()`, `.dot()`

### `src/CodeGen.zig`
- `genType()` (~line 10271): emit `@Vector(N, T)`
- `genCall()` ctor path (~line 9259): emit `.{ a, b, ... }` for `f32x8(...)` 
- `genCall()` method path (~line 9510): dispatch to `genSimdCall()`
- New `genSimdCall()` (after `genMathCall` ~line 5305): central SIMD intrinsic emitter

---

## Implementation order

1. `Builtins.zig` NAMES + `scalarKind()`
2. `TypeChecker.zig` `builtinType()`
3. `TypeChecker.zig` `inferCall()`
4. `CodeGen.zig` `genType()`
5. `CodeGen.zig` `genSimdCall()` + hookup
6. Tests: `test/simd_test.zbr`

After Zig side green: mirror to `selfhost/typechecker.zbr` + `selfhost/codegen.zbr`.

---

## Scope boundaries

**In scope (v1):** splat, load, load_unchecked, element-wise `+`/`*`/`-`/`/`, sum, dot, max_element, indexed access `v[i]`.

**Deferred:** shuffles/permutes, fused multiply-add (`madd`), auto-fallback to scalar, `bf16x8`.

---

## Pre-conditions for starting

- [ ] Phase 22 cutover committed and green
- [ ] Clean working tree
- [ ] `zig build test` green baseline
