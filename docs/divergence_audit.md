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
single-module: 288 agree-pass · 46 agree-fail · 18 library(no-main)   (2026-07-20 re-run)
multi-module (selfhost-only, bootstrap N/A): 30
SELFHOST GAPS: 19  (→ 3 remain: 16 fixed; see below)
BOOTSTRAP GAPS: 14  (unchanged)
```

Update 2026-07-20: closed 8 more (nil_tracking, forgot_parens, string_methods,
selfhost_probe6, file_io, method_chain_throws, fuzzy_selfhost, extend) — 16 of 19
fixed, **3 selfhost gaps remain** (expressiveness, json, throws_autoprop). Full
re-run: 288 agree-pass, 14 bootstrap gaps unchanged (bootstrap binary untouched).

The headline is reassuring: **286 files agree**, and the divergences are a short,
enumerated, classified list — not a fog.

## ▶ SELFHOST GAPS (bootstrap OK, selfhost fails) — the priority

Every one has a known-good bootstrap emit to diff against; these are *convergence*
targets, not open design questions.

**FIXED 2026-07-18 (this session):**
- `build_declarative_test`, `build_smoke_test` — two layers: (1) resolver `isBuiltin`
  lacked `Build` → "undefined name" (the bootstrap knew it); (2) `build_ctx`/
  `build_target` handles were over-marked `var` → "never mutated" (added them to
  `isByValueHandleType`, extending BUG-191). Both now converge.

**FIXED this pass** (each verified 0-gap + gated):
- `dns_test` (`2f3d4bf`) — registered `Net.resolve → List(str)` so `results.len` →
  `.items.len`.
- `log_test` — `Log.setLevel("debug")`/`setOutput("stdout")` map the string level →
  the `u8`/`bool` the preamble fn takes (was passing the string through). Two layers.
- `math_test` — added `atan2`/`log`/`isNaN`/`isInf` handlers (fell through to a 3-arg
  `std.math.log` and mis-cased `std.math.isNaN`). **Also closes BUG-194** (`Math.log`).
- `reflect_test` + `escape_field_test` (shared root, `1d02980`) — a class with no
  `cue init` gets a synthetic `self.* = .{}`, but non-defaulted fields lacked `= undefined`
  → "missing struct field". `genFieldDecl` now emits `= undefined` (matches bootstrap).
- `derive_test` (`1d02980`) — `p1 == p2` on a @derive(Eq) struct emitted raw `==` because
  `Point.init(…)` inferred unresolved. `inferExpr` now types `ClassName.init(…)` →
  named(ClassName), so `isDeriveEqExpr` fires and routes to `.eql()`.

**PARTIAL:**
- `json_test` — `getObj` now infers `json_value` (was grouped with `getStr`→str, so the
  result got a bad `[]const u8` annotation) — FIXED. But a next layer remains:
  `getList` returns a `[]Value` *slice*, yet the selfhost types it `list_` so for-in
  emits `.items` (bootstrap types it as a slice, iterates directly). Needs a slice-of-T
  type or for-in handling — deferred.

**FIXED 2026-07-20 (this session):**
- `nil_tracking_test` (`0bd2a63`) — `print(name)` inside `if name != nil` emitted
  `name.?.?`: the BUG-187 codegen narrowing already rewrites the ident to `name.?`, and
  print's own needs_unwrap added a second `.?`. Skip needs_unwrap for a nil-narrowed
  print-arg ident.
- `forgot_parens_test` (`efe8888`) — a bare top-level fn name used as a statement (`greet`)
  emitted `greet;` (invalid Zig); bootstrap emits `_ = greet;`. inferExpr types the bare fn
  ref as unknown_, so it slipped past the discard checks. Added an isTopLevelMethod check in
  the Stmt.expr codegen. (It IS a positive test — should compile with a warning.)
- `string_methods_test` (`6012c25`) — `", ".join(words)` (string-literal separator receiver)
  fell through the Type_.string_ arm (no join handler) to the generic list.join(sep) handler,
  emitting swapped args. Added a sep.join(list) handler to the string_ arm.
- `selfhost_probe6` (`9bddb28`) — `{s}` format for a non-string union payload bound in a
  branch arm (`on U.list_lit as n`, n:int → `list[${n}]`). Two roots: (1) arm payload type
  never bound into infer_ctx; (2) str_params aliases across arms (indented() `except`-copy
  shares the StrSet) so a reused name `n` lingered as a string. Bind payload type for all
  arms + removeOne for non-string payloads.
- `file_io_test` (`416add2`) — `File.copy(src, dst)` fell through to the
  `@compileError("selfhost: unknown File.copy")` fallback (whose divert also surfaced as a
  misleading "unreachable code"). Added the File.copy handler (read src, create dst, stream)
  matching src/CodeGen.zig.
- `method_chain_throws_test` (`e20a17e`, D4) — `f().throwsMethod()?` emitted `try f().name()`,
  calling a `self: *Widget` method on a `*const` temporary. genMemberCall's user-method
  early-exit emitted `receiver.method()` directly, bypassing the BUG-027 materialization.
  Skip the early-exit for a call-temporary receiver → falls through to the `var _mc_N` hoist.

- `fuzzy_selfhost` (`b68ad4d`) — `var m = List(HashMap(str,int))()` then `m.len` emitted
  `m.len` (ArrayList has no `.len`). The List-ctor inference only recognised a bare-name
  element; a nested-generic element (`HashMap(str,int)`, a call expr) fell through to
  `unresolved` so the local was never typed `list_`. Added standalone `typeArgToType(Expr)`
  (bare name / nested List/HashMap/Chan → Type_), used for the List element in inferExpr.

- `extend_test` (`ccf0c44`) — three layers: (1) call `s.shout()` wasn't rewritten to the
  emitted free function `_ext_String_shout(s)` (added ext_method_keys registry + genCall
  rewrite); (2) inside the `extend` body `this.upper().concat("!")` emitted `_mc.concat(…)`
  because `this` wasn't typed str (added InferCtx.self_type_override, seeded in genExtMethod);
  (3) `print(s.shout())` used `{any}` (byte output) not `{s}` (added ext_method_ret registry +
  printFmtSpec ext-call path). Surfaced BUG-198 (union→optional-field boxing drops the type arg).

**REMAINING (3) — diagnosed roots** (deeper than the return-type/handler class above; each
still has a known-good bootstrap emit to diff):
- `throws_autoprop_test` — a non-throws `run()` calling a `throws` `outer()` emits a bare
  `self.outer();` (error union ignored); bootstrap wraps `self.outer() catch |_e| {…}`.
  §28b throws-propagation interaction.
- `expressiveness_test` — `g.greet("Alice")` → "expected 2 args, found 1"; a defaulted
  param isn't filled (§27b default-arg).
- `json_test` (PARTIAL) — getObj→json_value FIXED; getList returns a `[]Value` slice yet
  the selfhost types it `list_` so for-in emits `.items` (bootstrap iterates the slice
  directly). Needs a slice-of-T type or for-in handling.

All 3 remaining gaps are now diagnosed (roots above); none is a shared root.

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
