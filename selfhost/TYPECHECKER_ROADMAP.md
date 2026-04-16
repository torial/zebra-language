# Selfhost TypeChecker Port — Roadmap

The selfhost compiler currently relies on name-based heuristics in
`codegen.zbr` (`isKnownStrSetField`, `isAstStructWithPtrParams`,
`isUnboxedCtorArg`, `shouldBoxCtorArg`, `isStringExpr`) as a stand-in for
real type information. The Zig compiler's type oracle lives in
`src/TypeChecker.zig` (3,243 lines, ~40 `Type` variants, 11 unit tests).

This document defines the path from heuristics → **full feature parity**
with `src/TypeChecker.zig`. Parity is the commitment: self-hosting is not
declared complete until all four gate criteria in §Gate hold.

## Phases

| Phase | Scope | Heuristics at end |
|---|---|---|
| 16a | `typechecker.zbr` skeleton: `Type` enum, `ModuleTypes`, `typeOfIdent` | all kept |
| 16b | `inferExpr` covering what heuristics already cover | all kept (advisory) |
| 16c | Retire `isKnownStrSetField`, `isAstStructWithPtrParams`, `isUnboxedCtorArg`/`shouldBoxCtorArg` one-at-a-time | `isStringExpr` + small fallbacks |
| 17 | Full `typeCheckPass3` expression walker; all `Expr`/`Stmt` variants; branch binding; comprehensions; aspects | none (functional) |
| 18 | `Type.eql`, `Type.isAssignable`, `generic_named`, `cross_module` symmetry | — |
| 19 | All ~25 stdlib type variants (http, csv, regex, json, …); port `Builtins.zig` | — |
| 20 | `Diagnostic`/`DiagKind` emission | — |
| 21 | Port every `test "typecheck: …"` block in `src/TypeChecker.zig` to `.zbr` | — |
| 22 | Delete every `is*`/`should*` typing helper in `codegen.zbr` | **zero** |

Each phase begins with a marker commit (see `/.claude` preferences).
Bootstrap (`zig build bootstrap`) must stay green at every phase boundary.

## Equivalence-rule risk map

| Phase | Risk | Mitigation |
|---|---|---|
| 16a–c | Selfhost weaker than Zig on programs exercising unported variants | Heuristics remain as fallback; parity not yet claimed |
| 17 | Subtle behavior drift in expr walker | Each ported block gets a `.zbr` test mirroring its Zig counterpart; parity-diff harness introduced |
| 18 | Generics / cross-module are where Zig's logic is densest | Diff `Type.name()` output between selfhost and Zig across the test corpus |
| 19 | Easy to miss a stdlib variant | Enumerate against `Builtins.zig` symbol list before declaring done |
| 21 | "Tests pass" ≠ "no user-visible drift" | Bootstrap harness also compares selfhost-emitted vs zig-emitted `.zig` for the fuzzy-match corpus |

## Gate — parity declaration criteria

All four must hold simultaneously:

1. All 11 `test "typecheck: …"` blocks in `src/TypeChecker.zig` ported to
   `.zbr` and green in the selfhost test suite.
2. `zig build bootstrap` clean.
3. Zero `is*` / `should*` typing heuristics remain in `selfhost/codegen.zbr`.
4. For every variant in `Type` (as defined in `src/TypeChecker.zig`),
   a selfhost test exercises both inference and a mismatch-error case.

If at phase 22 any of these fail, self-hosting is not complete —
consistent with the selfhost equivalence rule.
