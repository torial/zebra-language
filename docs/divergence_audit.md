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
SELFHOST GAPS: 19  (→ 16 after the Build + dns fixes below)
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

- `dns_test` — **FIXED** (`2f3d4bf`): `Net.resolve` return type unregistered →
  `results.len` emitted raw on an ArrayList. Registered `Net.resolve → List(str)`.

**REMAINING (16) — diagnosed roots** (each has a known-good bootstrap emit to diff
against — a `diff bootstrap vs selfhost emit → converge` workflow):

*Diagnosed this pass:*
- `string_methods_test` — `", ".join(words)` (string-LITERAL receiver) emits swapped
  args: `join(_allocator, words, ", ".items)` instead of `join(_allocator, ", ", words.items)`.
  Likely string-temp materialization interacting with the sep.join(list) handler
  (CodeGen ~14719). Not a return-type fix.
- `json_test` — `_json_get_obj(nd, "user")` returns a json `Value` but is assigned to
  `[]const u8`. Json-accessor return-type / genJsonCall mismatch.
- `selfhost_probe6` — a `{s}` format emitted for an `i64` (string-interp `${n}` where
  `n` is an int union payload → wrong format char picked). Print-format inference.
- `log_test` — "expected u8, found *const [5:0]u8": a `Log.*` preamble signature takes
  a `u8` where a string level is passed. Preamble signature mismatch.

*Not yet diagnosed (signature only):*
- `derive_test` (`operator == not allowed for Point` — @derive(Eq) gap) ·
  `escape_field_test`/`reflect_test` (`missing struct field` — reflect/@derive) ·
  `extend_test` (extension method dispatch) · `expressiveness_test` (member fn arg
  count / default args) · `file_io_test` (`unreachable code`) · `math_test`
  (`atan2 not implemented for comptime_float` — coerce to runtime) ·
  `method_chain_throws_test` (D4 `*T`-vs-`*const T`) · `nil_tracking_test`
  (`expected optional, found []const u8` — nil-narrowing) · `throws_autoprop_test`
  (`error union is ignored`) · `fuzzy_selfhost` (`.len` on List(HashMap)) ·
  `forgot_parens_test` (NEGATIVE test — verify it should even A/B).

Pace note: these are NOT one shared root — each is its own careful, gated fix (return-
type registrations like dns are the cheapest; join/format/preamble/D4 are deeper). Burn
down a few per session rather than in one rushed batch.

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
