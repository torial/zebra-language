# Emit compile-check triage — full-corpus independent-witness sweep (2026-07-16)

**What this is.** A one-time broad sweep compiled EVERY `test/*.zbr` + `examples/*.zbr`
(399 files) with the selfhost (`zebra.exe --emit-zig` → `zig build-exe -fno-emit-bin`),
not just the ~201 smoke-registered files that `tools/compile_check.sh` normally covers.
Goal: surface latent emit miscompiles (the BUG-182 class) hiding in un-gated files.

**Headline: 293 PASS / 52 FAIL / 54 SKIP.** The 52 FAILs triage below. This was found
while hunting the generalized BUG-182 (dedicated-`Type_`-variant) class; BUG-182 was the
visible tip of a much larger un-gated emit surface.

**Honest caveats (do not over-read the "52"):**
- It is NOT "52 bugs." ~11 are expected-fail (negative tests) or harness limits.
- Of the ~41 remaining, buckets are error SIGNATURES, spot-checked as real on current
  APIs (`Http`, `CsvWriter`, `Math` all verified current), but NOT every file was
  individually confirmed real-vs-stale. Some may be stale tests using evolved APIs.
- Many files share a ROOT CAUSE (e.g. 5 GUI files, one `param shadows 'init'` bug), so the
  real work is ~15–20 root causes, not 40 fixes.

**Status legend:** `NEG` expected-fail test · `HARNESS` external dep/platform ·
`REAL?` real-looking, unverified · `REAL✓` confirmed · `FIXED` ·

---

## A. Negative / error-detection tests (expected to fail) — ~8, not bugs
(Some emit broken Zig instead of a clean TC error — a minor quality gap, not a miscompile.)

| File | Error | Status |
|---|---|---|
| field_not_found_test | no field 'y' in P | NEG (registered smoke-negative) |
| method_not_found_test | no method 'shout' in []const u8 | NEG (registered) |
| forgot_parens_test | value of type 'fn() void' ignored | NEG (compile_check SKIP) |
| bug108_this_outside_class_test | undeclared 'self' | NEG (`this` outside class) |
| bug106_heterogeneous_list_test | expected i64, found *const [3:0]u8 | NEG? (heterogeneous list) |
| bug105_enum_member_test | expected i64, found Color | NEG? (verify) |
| bug105_union_variant_test | expected i64, found union tag | NEG? (verify) |
| bug099_unresolved_test | undeclared 'Math' | NEG? (unresolved-detection; Math IS current) |

## B. Harness limits (external deps / platform) — 3, not bugs
| File | Error | Status |
|---|---|---|
| c_interop_test | unable to load 'CUtils.zig' (FileNotFound) | HARNESS (external C) |
| zig_interop_test | unable to load 'ZigMath.zig' (FileNotFound) | HARNESS (external Zig) |
| plugin_host | unsupported platform (dynamic_library) | HARNESS (platform) |

## C. Preamble `reduce` param shadows top-level `init` — **FIXED (BUG-184)** — cleared 3 files
The preamble helper `_zebra_list_reduce` had a parameter `init` that shadowed a user top-level
`pub fn init` (MVU model ctor). Renamed → `init_val`. **Cleared: `counter · hbox_smoke ·
file_dialog_smoke`.** The other 3 were failing on `init` FIRST; now reclassified to their next bug:
- `panel_smoke` → **new**: `function parameter 'g' shadows function parameter from outer scope`
  (nested closure param `g` shadowing the outer `g` — a distinct shadowing bug).
- `widget_smoke` → **D4** (`^T`-box `*T` vs `*const T`).
- `test_gui_simple` → `local constant shadows declaration of 'frame'` (const-shadow, akin to C but
  a local `frame` — likely a `with`/capture-block re-binding).

## D. Genuine codegen / type miscompiles on CURRENT constructs — ~30, clustered

### D1 — undeclared type not emitted (stdlib type used but not materialized) — partly FIXED
| File | Undeclared | Status |
|---|---|---|
| http_test | `Http` | **FIXED (BUG-186)** — `.get` heuristic shadowed the Http namespace. Now surfaces BUG-187 (nil-narrowing). |
| https_test | `Http` | **FIXED (BUG-186)**; now BUG-187 (nil-narrowing). |
| csv_test | `CsvWriter` | OPEN — CsvWriter is current (QUICKSTART, Resolver) → real emit gap |
| zebra_ide | `List` | OPEN — `List` undeclared, investigate |

### D9 — nil-narrowing: `if x != nil` then `x.field` — **BUG-187 (FIXED — implemented auto-narrowing)**
Inside `if x != nil`, a plain non-reassigned local is now auto-narrowed to non-optional (`x.?`).
Cleared `http_test`, `https_test`. `tcp_advanced_test` now narrows `?TcpConn` → `TcpConn` but hits
a SEPARATE bug: `TcpConn.write` isn't dispatched on a proven `TcpConn` receiver (→ D5, the
BUG-182/sqlite receiver-dispatch family). Deferred narrowing cases (`and`-chains, `==nil` else,
non-local receivers) fall back to explicit `x!` (QUICKSTART §11).

### D2 — SYNTAX errors in emitted Zig (malformed emit) — REAL✓ (Zig can't even parse it)
| File | Error | Status |
|---|---|---|
| json_test | expected ';' after statement | **root cause FIXED (BUG-183)** — single-quoted string with embedded `"` emitted unescaped. json_test still fails on a *separate* D7 bug (never-mutated). |
| expose_dotted_test | expected ';' after declaration | OPEN — likely a *different* malformed emit (verify; not the string-escape cause) |
| selfhost_probe6 | expected ',' after initializer | OPEN — likely a different malformed emit (verify) |

**BUG-183 (FIXED 2026-07-16):** single-quoted string literals with an embedded literal `"`
emitted unescaped Zig (`'{"a":1}'` → `"{"a":1}"` → syntax error). Selfhost-only (bootstrap was
correct). Fixed via idempotent escaping in `escapePlainStr` (`selfhost/CodeGen.zbr`). This is a
*class* fix — any single-quoted string with embedded quotes (JSON/HTML/etc.) across the corpus.

### D3 — `.len`/`.member` on ArrayList / str-vs-list confusion (StrSet/BUG-182 family) — REAL?
| File | Error |
|---|---|
| dns_test | no field 'len' in ArrayList([]const u8) |
| tc_types_test | struct 'TcTypes' has no member 'len' |
| string_methods_test | expected []const u8, found ArrayList([]const u8) |
| crossmod_expose_test | ArrayList(Tag) is not indexable |

### D4 — `^T`-box pointer mismatch — **splits into 3 signatures; the `^T`-field-value sub-cluster FIXED (BUG-192)**
| File | Error | Status |
|---|---|---|
| selfhost_probe5 | expected '*Expr', found 'Expr' | **FIXED (BUG-192)** — `^T` union field from a value ctor param now auto-boxes; compiles end-to-end. |
| tc_infer_test | expected '*TcExpr', found 'TcExpr' | `^T`-box **FIXED (BUG-192)**; now fails on unrelated D3 `.len`-on-struct (`TcTypes has no member len`). |
| tc_check_test | expected '*tc_infer.TcExpr', found 'tc_infer.TcExpr' | CROSS-MODULE union — deferred (BUG-192 follow-up; needs `dep_types.hasUnion` arm). Also has other errors. |
| generic_pair_test | expected 'T', found '*T' | OPEN — **different signature** (generic `T` value-vs-pointer, not `^T` field-box). |
| method_chain_throws_test | expected '*T', found '*const T' | OPEN — **different signature** (const-ness `*T` vs `*const T`, generic). |

**BUG-192 (FIXED same-module 2026-07-17):** a `^T` (struct OR union) field assigned a value inside
`cue init` wasn't auto-boxed — the ref-box path missed bare-ident field targets (`left = l`) and
didn't box unions. Fixed both; guarded with `rhsIsAlreadyRef` so an already-pointer RHS (`^T?`
param) isn't double-boxed (caught a `val_test` regression on the gate). The remaining D4 files are
two genuinely-separate generic-`T` pointer/const signatures.

### D5 — method on a mis-typed receiver (BUG-182 class) — partly FIXED
| File | Error | Status |
|---|---|---|
| fuzzy_match | no method 'concat' in []u8 | **FIXED (BUG-185)** — chained string method materialization |
| fuzzy_selfhost | no method 'concat' in []u8 | concat FIXED (BUG-185); now surfaces a **D3** HashMap `.len` |
| datetime_test | no method 'toEpoch' in _DateTime | **FULLY FIXED (BUG-189 + BUG-190)** — dispatch batch + toIso8601/format + D7 never-mutated (before/after/equals → isReadOnlyMethod) + DateTime-chain materialization. Compiles AND runs correctly. |
| tcp_advanced_test | no method 'write' in **?**TcpConn (optional not unwrapped) | **FULLY FIXED (BUG-188 + BUG-191)** — dispatch unwraps optional/^T (188); the follow-on D7 `never mutated` on the `tcp_conn` handle is fixed by 191 (handle types are by-value → `const`). Compiles end-to-end. |
| extend_test | no method 'shout' in []const u8 (extension method) | OPEN — `extend` feature |
| json_parse_typed_test | no method 'getString' in json.dynamic.Value | OPEN |

**Note:** the two `concat` files were a *different* root cause than the rest of D5 (method-chain
materialization on a string temp, BUG-185, not receiver-type inference). The remaining 4 are the
true "receiver type not inferred → wrong dispatch" family (BUG-182 shape).

### D6 — argument-count mismatch — REAL?
| File | Error |
|---|---|
| expressiveness_test | member function expected 2 arg(s), found 1 |
| progress_test | expected 2 argument(s), found 1 |

### D7 — emitted Zig trips Zig strictness (const/var, unused, unreachable) — **`never mutated` FIXED (BUG-191)**
| File | Error | Status |
|---|---|---|
| unicode_test | local variable is never mutated | **FULLY FIXED (BUG-191)** — compiles end-to-end. |
| string_methods_test | never mutated (`str.reverse()`) | `never mutated` **FIXED (BUG-191 rd2)** — str is fully immutable; 1 separate D3 error remains (`.split()` → ArrayList vs `[]const u8`). |
| json_test | local variable is never mutated | `never mutated` **FIXED (BUG-191)**; 1 separate error remains (next layer). |
| file_io_test | local variable is never mutated / unreachable code | `never mutated` **FIXED (BUG-191)**; `unreachable code` remains (separate). |
| gui_test | local variable is never mutated | **NOT a struct case** — `frame` is a **closure** passed by value to `Gui.run`; `var` comes from closure lowering, not scanMutations. Separate closure-codegen follow-up (NEXT_STEPS); also fails on unrelated `GuiContext has no member 'run'`. |
| typechecker_test | unused function parameter | `never mutated` cleared (BUG-191); `unused parameter` + D4 `*TcExpr` remain. |

**BUG-191 (FIXED 2026-07-17, two rounds):** the `var`/`const` mutation scan guessed from the
method NAME (`isReadOnlyMethod` allow-list). Replaced with type-driven analysis:
`isImmutableValueType` (primitives/char/str/str_slice → never `var`) + `isByValueHandleType`
(json/tcp/ws/udp/sqlite/regex → `const` unless an explicit in-place mutator), with
optional/`^T` unwrap (`unwrapForMutation`). Kills the whole `never mutated` class at the root
corpus-wide instead of adding names to the list. Only residual: `gui_test`'s **closure** local
(separate subsystem). No named-struct-getter case exists → the per-method struct map is not needed.

### D8 — misc singletons — REAL?
| File | Error |
|---|---|
| derive_test | operator == not allowed for type 'Point' (@derive == gap?) |
| reflect_test | missing struct field: name |
| escape_field_test | missing struct field: items |
| log_test | expected 'u8', found '*const [5:0]u8' (char vs string) |
| math_test | atan2 not implemented for comptime_float (emit should coerce to runtime) |
| raise_details_test | error union is ignored |
| throws_autoprop_test | error union is ignored (same signature) |

---

## Recommended campaign (for 1.0)

1. **Verify each D-cluster real-vs-stale** (spot-checks say real; confirm the rest). Sean's
   context on which tests are live vs abandoned will sharpen this fast.
2. **Fix by root cause, not by file** — C is 1 fix for ~6 files; D4/D5 share mechanisms
   (`^T` boxing, mis-typed-receiver dispatch — the BUG-182 family). Est. ~15–20 root causes.
3. **Gate `compile_check` over the triaged-clean corpus** (see CLAUDE.md "Verification gates";
   currently manual) so this surface cannot silently regrow.
4. Prune genuinely-stale tests (quarantine, don't delete — note why).

Raw per-file error capture:
`scratchpad/errors.txt` (session artifact) — regenerate via the broad sweep in
`tools/compile_check.sh` extended to the full corpus.
