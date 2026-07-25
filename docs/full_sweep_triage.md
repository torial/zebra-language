# Full-corpus sweep triage (2026-07-24)

The independent witness (`compile_check.sh`) only checks the ~210 smoke-registered
tests. This sweep (`tools/full_sweep.sh`) emits + `zig build-exe -fno-emit-bin`
**every** `test/*.zbr` (403 files) to see the whole corpus through Zig's eyes.

## Result

| bucket | count | meaning |
|---|---:|---|
| **PASS** | 325 → **328** | emitted + compiled clean (328 after the 3 stale-test fixes below) |
| **CFAIL** | 23 | emitted, but the emitted Zig fails to compile |
| **EMITFAIL** | 32 | `--emit-zig` returned non-zero (compiler-side; includes negative tests) |
| **NOMAIN** | 23 | library module, no `pub fn main` (expected — not run standalone) |

**No new bugs; zero regressions.** Every registered-positive test PASSes (the
existing gate is sound), and every CFAIL/EMITFAIL is accounted for:

## Disposition of the 55 failures

- **Negative tests (expected to fail)** — type-mismatch, exhaustiveness, visibility,
  removed-syntax and "expects compile error" fixtures: `arg_anchor_test`,
  `arg_type_nested_test`, `tc_mismatch_*`, `tc_iface_*_mismatch_test`, `diag_*`,
  `*_rejected_test`, `branch_missing_test`, `branch_infer_miss_test`,
  `bug078_double_box_test`, `bug10{5,6,8}_*`, `print_stmt_removed_test`,
  `to_bang_removed_test`, `visibility_tc_fail`, `in_scope_tc_fail_test`,
  `multi_parse_error_test`, `member_call_diag_test`, `bug199_recovery_hang_test`,
  `bug200_deep_nesting_test`, `tc_merge_fixture` (merge-tool fixture).
- **Library modules (NOMAIN)** — `*_lib` and other deps with no `main`; correct.
- **Interop / GUI (need external libs to link)** — `c_interop_test`,
  `zig_interop_test`, `gui_test`, `test_gui_simple`, `zebra_ide`.
- **Multi-module cross-mod** — emit produces separate dep files the single-file
  witness can't link standalone: `crossmod_expose_test`, `expose_dotted_test`,
  `tc_check_test`/`tc_infer_test`/`tc_types_test`/`typechecker_test` (import the
  compiler's own modules).
- **Known codegen triage-backlog** — the open items already mapped in
  `docs/emit_compile_triage.md` (generics `T`/`*T`, enum/union→int coercion, some
  stdlib API gaps: `csv_test`, `json_parse_typed_test`, `progress_test`,
  `raise_details_test`, `generic_pair_test`, …). Not regressions; pre-existing.

## Fixed by this sweep

Three **stale tests** used syntax removed during §28 and so died at parse — they
were silently not testing what they claimed. Refreshed to current forms and now
smoke-gated:
- `branch_inline_return_test`, `branch_exhaustive_test` — `print "x"` → `print("x")`.
- `tuple_test` — `def f(...) as (T,T)` / `var q as (T,T)` → `: (T,T)`.

## The gate

`tools/full_sweep.sh --gate` compares the current PASS set to
`tools/full_sweep_baseline.txt` (328). It fails on **regression** (a
baseline-passing test that now fails); new passes are informational. The baseline
is the allow-list, so no hand-maintained skip-list is needed — re-baseline with
`--update-baseline` when the pass set intentionally grows (e.g. after clearing a
`docs/emit_compile_triage.md` item). Heavy (~25 min, JOBS=2); per-session /
pre-release, like `compile_check.sh`.
