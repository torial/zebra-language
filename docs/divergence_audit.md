# Selfhost ↔ bootstrap divergence audit (2026-07-18)

**Tool:** `tools/divergence_check.sh` — the independent witness for *drift* between
the two compilers. The other gates (round-trip, smoke, compile_check) all EMIT with
one compiler, so a case where the self-hosted `zebra.exe` DISAGREES with the reference
`zebra-bootstrap.exe` is structurally invisible to them (round-trip only proves
self-*consistency*). This harness emits every corpus file with BOTH compilers,
compile-checks each output, and classifies the disagreements.

Why it matters now: the roadmap sunsets the bootstrap (endgame = Zig only in
special-case files). While it is still the trusted reference, every selfhost gap has a
known-good target; once the bootstrap is gone, a selfhost gap is just a permanent wart.

## First full run (test/ + examples/, JOBS=3)

```
single-module: 272 agree-pass · 46 agree-fail · 18 library(no-main)
multi-module (selfhost-only, bootstrap N/A): 30
SELFHOST GAPS: 19  (→ 17 after the Build fix below)
BOOTSTRAP GAPS: 14
```

The headline is reassuring: **272 files agree**, and the divergences are a short,
enumerated, classified list — not a fog.

## ▶ SELFHOST GAPS (bootstrap OK, selfhost fails) — the priority

Every one has a known-good bootstrap emit to diff against; these are *convergence*
targets, not open design questions.

**FIXED 2026-07-18 (this session):**
- `build_declarative_test`, `build_smoke_test` — two layers: (1) resolver `isBuiltin`
  lacked `Build` → "undefined name" (the bootstrap knew it); (2) `build_ctx`/
  `build_target` handles were over-marked `var` → "never mutated" (added them to
  `isByValueHandleType`, extending BUG-191). Both now converge.

**REMAINING (17) — mostly the emit-compile campaign's D-clusters, now confirmed
bootstrap-correct** (see `docs/emit_compile_triage.md`):
`derive_test · dns_test · escape_field_test · extend_test · expressiveness_test ·
file_io_test · forgot_parens_test · fuzzy_selfhost · json_test · log_test · math_test ·
method_chain_throws_test · nil_tracking_test · reflect_test · selfhost_probe6 ·
string_methods_test · throws_autoprop_test`
- The audit's contribution: each is now a **diff bootstrap-emit vs selfhost-emit →
  find the exact divergence → converge** workflow, far more tractable than the
  original blind triage. `method_chain_throws_test` is a D4 `*T`-vs-`*const T` repro;
  `dns_test`/`fuzzy_selfhost` are `.len`-on-container (D3); etc.

## ▶ BOOTSTRAP GAPS (selfhost OK, bootstrap fails) — the selfhost LEADS

Areas where the self-hosted compiler has surpassed the bootstrap. **Low priority** —
the bootstrap sunsets, so these need no fix; they document where the selfhost is ahead.
`lambda_calc · lisp · pratt_calc · bug177_178_index_tostring_test · features ·
generic_fn_test · greet · hashmap_init_patterns_test · list_iter · selfhost_probe5 ·
simd_test · sort_test · sqlite_test · with_test`
(SIMD, generics, and several functional/stdlib features the bootstrap never learned.)

## · agree-fail (both fail) — mostly a GOOD signal

46 files, and the majority are **negative tests** both compilers correctly reject —
`bug099/105/106/108`, `field_not_found`, `method_not_found`, the `diag_*`, `tc_mismatch_*`,
`tc_iface_*`, `branch_missing`, `visibility_tc_fail`, etc. Agreement on error detection
is exactly what you want. A handful are genuinely-broken/stale (csv_test, gui_test,
generic_pair_test, zebra_ide, progress_test) — real bugs, but both compilers share them.

## · multi-module selfhost failures (bootstrap N/A)

`c_interop_test`/`zig_interop_test` (external files — harness limit) and the compiler's
own modules used as tests (`tc_check_test`, `tc_infer_test`, `typechecker_test`,
`tc_types_test`, `crossmod_expose_test`, `expose_dotted_test`) — the BUG-181 self-compile
class. Not A/B-checkable because the bootstrap emits to stdout (single root only).

## Root cause worth preventing

The `Build` gap's root: `Resolver.isBuiltin` and `CodeGen.isStdlibNamespace` are **two
hand-maintained copies of the same set** and drift apart. A shared source of truth
(one list both consult) would prevent this whole sub-class. Filed as a follow-up.

## Status of the harness itself

Diagnostic/monitoring, not yet a hard gate — like `compile_check` before its corpus was
clean, it can't pass/fail-gate while 17 selfhost gaps remain. **It becomes gate-able
once the selfhost gaps close** (then it guarantees the two compilers never silently
diverge again). Track the SELFHOST-GAP count as the burn-down metric.
