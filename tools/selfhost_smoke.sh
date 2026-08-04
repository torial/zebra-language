#!/usr/bin/env bash
# selfhost_smoke.sh — quick sanity check for the selfhost compiler pipeline.
#
# Runs zebra.exe (the selfhost primary binary) through --emit-zig on a small
# set of representative fixtures.  Each test passes if the emit exits 0 (full
# lex→parse→resolve→TC→codegen pipeline succeeded).  No Zig compilation is
# performed so this runs fast (~0.5–2 s per test, shared Zig cache).
#
# BLIND SPOT: because it only --emit-zig's, it CANNOT catch emitted Zig that fails
# to compile (stale stdlib APIs, codegen bugs). To check that the emitted Zig actually
# compiles, run the independent witness: JOBS=3 bash tools/compile_check.sh
# (See CLAUDE.md "Verification gates".)
#
# Called by: `zig build test` (via the selfhost_smoke build step).
# Also safe to run manually: bash tools/selfhost_smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

ZEBRA="$REPO/zig-out/bin/zebra.exe"
if [[ ! -x "$ZEBRA" ]]; then
    echo "selfhost_smoke: $ZEBRA missing. Run 'zig build' first." >&2
    exit 1
fi
BOOTSTRAP="$REPO/zig-out/bin/zebra-bootstrap.exe"

# Per-process scratch dir. Two concurrent runs used to share "/tmp/selfhost-smoke",
# which each one rm -rf's at startup and clears between tests — so running smoke
# twice at once made tests fail for no reason and looked exactly like a real
# regression. $$ keeps concurrent invocations independent.
TMPDIR_OUT="/tmp/selfhost-smoke-$$"
rm -rf "$TMPDIR_OUT"
mkdir -p "$TMPDIR_OUT"
trap 'rm -rf "$TMPDIR_OUT"' EXIT

PASS=0
FAIL=0

smoke() {
    local zbr="$1"
    local label
    label="$(basename "$zbr" .zbr)"
    if "$ZEBRA" --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>"$TMPDIR_OUT/smoke-err"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label" >&2
        grep -v "^wrote \|^compiling:\|^ *parsing\|^ *parsed\|^ *resolved" "$TMPDIR_OUT/smoke-err" >&2 || true
        FAIL=$((FAIL + 1))
    fi
    # Clear between tests so dep files don't bleed across
    rm -f "$TMPDIR_OUT"/*.zig
}

# Emit with --turbo and verify no contract strings appear in the generated Zig.
smoke_turbo() {
    local zbr="$1"
    local label
    label="$(basename "$zbr" .zbr)_turbo"
    if "$ZEBRA" --turbo --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>"$TMPDIR_OUT/smoke-err"; then
        local zig_out="$TMPDIR_OUT/$(basename "$zbr" .zbr).zig"
        if grep -qE "_check_invariant|require failed|ensure failed" "$zig_out" 2>/dev/null; then
            echo "  FAIL: $label (contract strings found in turbo output)" >&2
            grep -E "_check_invariant|require failed|ensure failed" "$zig_out" >&2 || true
            FAIL=$((FAIL + 1))
        else
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        fi
    else
        echo "  FAIL: $label (emit failed)" >&2
        grep -v "^wrote \|^compiling:\|^ *parsing\|^ *parsed\|^ *resolved" "$TMPDIR_OUT/smoke-err" >&2 || true
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}


# Emit with a GUI backend and assert a substring in the generated Zig. Exists for
# BUG-229: the tui scaffold declares `_tui_env` and must ASSIGN it, and that is a static
# fact about emitted text — no build, no terminal, no human. The GUI paths are otherwise
# ungated, so the cheap half is worth taking.
smoke_gui_emit_contains() {
    local zbr="$1"; local backend="$2"; local expected="$3"
    local label; label="$(basename "$zbr" .zbr)_${backend}emit"
    local zig_out="$TMPDIR_OUT/$(basename "$zbr" .zbr).zig"
    if "$ZEBRA" --emit-zig --gui-backend="$backend" "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>&1; then
        if grep -qF -- "$expected" "$zig_out" 2>/dev/null; then
            echo "  PASS: $label"; PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (emitted Zig lacks '$expected')" >&2; FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: $label (emit failed)" >&2; FAIL=$((FAIL + 1))
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}

# Run `zebra test` and check all tests pass (exit 0, no FAIL lines in output).
smoke_test() {
    local zbr="$1"
    local label
    label="$(basename "$zbr" .zbr)_test"
    if "$ZEBRA" test "$zbr" >"$TMPDIR_OUT/smoke-test-out" 2>&1; then
        if grep -qF "FAIL:" "$TMPDIR_OUT/smoke-test-out"; then
            echo "  FAIL: $label (some tests failed)" >&2
            cat "$TMPDIR_OUT/smoke-test-out" >&2
            FAIL=$((FAIL + 1))
        else
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        fi
    else
        echo "  FAIL: $label (exit non-zero)" >&2
        grep -v "^compiling:\|^ *parsing\|^ *parsed\|^ *resolved\|^wrote " "$TMPDIR_OUT/smoke-test-out" >&2 || true
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}

# Emit-only fixture that must emit successfully but whose emitted Zig must CONTAIN
# a given substring. Used for codegen guards that are lowered to `@compileError`
# rather than rejected by the Zebra front end (e.g. BUG-215 indexOf arity, and the
# `<<-` / `<-` mixup in genCopyOut) — the front end has no stdlib arity table, so
# the guard fires when Zig compiles the emitted program.
smoke_emit_contains() {
    local zbr="$1"
    local expected="$2"
    local label
    label="$(basename "$zbr" .zbr)_emit"
    local zig_out="$TMPDIR_OUT/$(basename "$zbr" .zbr).zig"
    if "$ZEBRA" --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>&1; then
        if grep -qF -- "$expected" "$zig_out"; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (expected '$expected' in emitted Zig)" >&2
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: $label (emit failed)" >&2
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}

# Run a fixture expected to COMPILE (exit 0) but emit a specific warning substring
# on stderr. Used for non-fatal diagnostics (e.g. BUG-142 arg-count warnings).
smoke_warn() {
    local zbr="$1"
    local expected_msg="$2"
    local label
    label="$(basename "$zbr" .zbr)_warn"
    if "$ZEBRA" --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>"$TMPDIR_OUT/smoke-err"; then
        if grep -qF -- "$expected_msg" "$TMPDIR_OUT/smoke-err"; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (compiled but warning missing: $expected_msg)" >&2
            grep -v "^compiling:\|^ *parsing\|^ *parsed\|^ *resolved" "$TMPDIR_OUT/smoke-err" >&2 || true
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: $label (expected compile success, got non-zero exit)" >&2
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}

# Run a fixture expected to fail at build/run, asserting a Zebra-term message in
# stderr AND that no generated-`.zig:` path leaks (audit #4 humanization).
smoke_run_fail() {
    local zbr="$1"
    local expected_msg="$2"
    local label
    label="$(basename "$zbr" .zbr)_runfail"
    local got
    if got=$("$ZEBRA" "$zbr" 2>&1); then
        echo "  FAIL: $label (expected failure, got exit 0)" >&2
        FAIL=$((FAIL + 1))
    else
        if echo "$got" | grep -qF -- "$expected_msg" && ! echo "$got" | grep -q "\.zig:"; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (message missing or .zig leaked)" >&2
            echo "$got" | grep -v "^compiling:\|^ *parsing\|^ *parsed\|^ *resolved\|^wrote " | tail -6 >&2
            FAIL=$((FAIL + 1))
        fi
    fi
}

# Run a fixture expected to FAIL TC with a specific diagnostic substring in stderr.
smoke_tc_fail() {
    local zbr="$1"
    local expected_msg="$2"
    local label
    label="$(basename "$zbr" .zbr)"
    if "$ZEBRA" --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>"$TMPDIR_OUT/smoke-err"; then
        echo "  FAIL: $label (expected TC failure, got exit 0)" >&2
        FAIL=$((FAIL + 1))
    else
        if grep -qF -- "$expected_msg" "$TMPDIR_OUT/smoke-err"; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (wrong/missing diagnostic)" >&2
            echo "    expected substring: $expected_msg" >&2
            grep -v "^compiling:\|^ *parsing\|^ *parsed\|^ *resolved" "$TMPDIR_OUT/smoke-err" >&2 || true
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}

# Verify that a file with multiple parse errors reports ALL of them (not just the first).
# Takes two expected error substrings; both must appear in the compiler's stderr.
smoke_multi_parse_fail() {
    local zbr="$1"
    local expected1="$2"
    local expected2="$3"
    local label
    label="$(basename "$zbr" .zbr)"
    if "$ZEBRA" --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>"$TMPDIR_OUT/smoke-err"; then
        echo "  FAIL: $label (expected parse failures, got exit 0)" >&2
        FAIL=$((FAIL + 1))
    else
        local ok=1
        if ! grep -qF -- "$expected1" "$TMPDIR_OUT/smoke-err"; then
            echo "  FAIL: $label (first parse error missing: $expected1)" >&2
            ok=0
        fi
        if ! grep -qF -- "$expected2" "$TMPDIR_OUT/smoke-err"; then
            echo "  FAIL: $label (second parse error missing: $expected2)" >&2
            ok=0
        fi
        if [[ $ok -eq 1 ]]; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            grep -v "^compiling:\|^ *parsing\|^ *parsed\|^ *resolved" "$TMPDIR_OUT/smoke-err" >&2 || true
            FAIL=$((FAIL + 1))
        fi
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}

echo "── Selfhost smoke tests (emit-zig pipeline)"

# Pure arithmetic / branching
smoke test/branch_edge_test.zbr
smoke test/branch_range_test.zbr

# Language features
smoke test/arena_scope_test.zbr
smoke test/allocate_slice4_test.zbr
smoke test/allocate_slice5_test.zbr
smoke test/char_tostring_test.zbr
smoke test/interp_tostring_test.zbr
smoke test/string_format_test.zbr

# Cross-module dep graph walk
smoke test/crossmod_arith_test.zbr
smoke test/crossmod_types_test.zbr
smoke test/crossmod_struct_pat_test.zbr
smoke test/crossmod_hatopt_test.zbr
smoke test/crossmod_optret_test.zbr
# BUG-158: exposed cross-module module vars (scalar + class-instance singleton).
smoke test/crossmod_modvar_test.zbr

# Struct + union features
smoke test/ctor_arg_ref_test.zbr
smoke test/dispatch_diag.zbr

# Lambda capture
smoke test/any_all_test.zbr

# Contracts
smoke test/contract_require.zbr
smoke test/contract_invariant.zbr
# Generic class + invariant — Zig-backend fix: genGenericClass now threads owner_invariants.
# Selfhost emits-zig exits 0 (pipeline succeeds); full binary is verified via bootstrap path.
smoke test/generic_invariant_test.zbr

# Type-directed HashMap.set() → .put() rewrite; user-defined .set() must pass through unchanged.
smoke test/hashmap_set_test.zbr

# BUG-029: this.field = HashMap() with non-int value type must use field type as hint.
smoke test/hashmap_this_field_test.zbr
# BUG-030: param.field.contains(key) on HashMap must emit .contains(), not List idiom.
smoke test/hashmap_param_field_test.zbr
# HashMap.remove() and HashMap.count() without type annotation (infer from init expr).
smoke test/hashmap_remove_test.zbr
# BUG-094: for k, v in HashMap — all 4 used/unused permutations must emit valid Zig.
smoke test/bug094_hashmap_kv_test.zbr

# BUG-002: guard/try error propagation — verified via try/catch round-trip.
smoke test/guard_test.zbr
smoke test/try_postfix_test.zbr

# BUG-079: method chaining on struct temporaries (auto-hoist in genLocalVar).
smoke test/method_chain_test.zbr

# for-else: Python-style else block runs when no break occurred.
smoke test/for_else_test.zbr

# Named/default parameters: named args + reordering + default insertion.
smoke test/named_default_test.zbr

# Optional-unwrap: `if x as n` and `if x is C as n` binding forms.
smoke test/if_unwrap_test.zbr

# Interface vtable struct: fat-pointer + VTable + check() conformance verifier.
smoke test/interface_test.zbr

# BUG-083 fix: genGenericClass now emits comptime { IFoo.check(@This()); }.
smoke test/generic_iface_test.zbr

# Generic toString() dispatch: user-defined toString() on Box(T)/Pair(A,B) should
# call the method directly, not fall back to std.fmt.allocPrint("{}", .{obj}).
smoke test/generic_tostring_test.zbr

# @[...] array literal in expression + `in @[...]` membership test.
smoke test/array_in_test.zbr

# Float suffix literals: 1.5_f32, 2.5_f64, 0.5f32, 3.0f64 → @as(fNN, val).
smoke test/float_suffix_test.zbr

# ensure without old: defer block checks post-state condition.
smoke test/contract_ensure_test.zbr
# ensure + old: snapshot pre-call value, check post-state with _old_N.
smoke test/contract_old_test.zbr
# ensure + old nested in compound expr (array_lit): regression for collectAndEmitOldSnapshots.
smoke test/contract_old_compound_test.zbr
# ensure + result: post-condition references the function's return value.
smoke test/contract_result_test.zbr
# ensure + result on throws function: BUG-087 — defer must not fire on error path.
smoke test/contract_result_throws_test.zbr
# ensure on void function with implicit fall-off return: defer must still fire.
smoke test/contract_ensure_falloff_test.zbr
# ensure with `result` member access: TC must infer result's return type
# so result.len, result.startsWith, etc. emit correct codegen.
smoke test/contract_result_member_test.zbr
# result/old as plain identifiers outside ensure (context-sensitive keyword test).
smoke test/contract_ident_test.zbr

# Class-level (shared/static) var fields: pub var in Zig, read/write by class name.
smoke test/shared_var_test.zbr

# Postfix catch: expr catch fallback (no binding form).
smoke test/catch_inline_test.zbr

# Top-level def main() without class/static wrapper.
smoke test/toplevel_main_test.zbr

# --turbo: require/ensure/invariant must be absent from generated Zig.
smoke_turbo test/turbo_test.zbr

# Struct field pattern matching in branch: `on Point(x: 0, y: 0)`.
smoke test/branch_struct_test.zbr

# Json.parseStrict + @reflectable: type-safe JSON deserialization with hard-error
# gates for non-@reflectable / non-primitive fields.
smoke test/json_parse_strict_test.zbr
# Probes parseStrict in TC-sensitive shapes (typed assignment, typed param,
# direct-to-if-binding) — selfhost has no Json TC arm, so this guards against
# a future codegen change making TC inference necessary.
smoke test/json_parse_strict_tc_test.zbr

# Dir.walk: recursive file-tree enumeration.
smoke test/dir_walk_test.zbr

# BUG-088: def-level try/catch in non-void return function must not implicitly fall off.
smoke test/bug088_try_return_test.zbr

# @profile method attribute: wraps body with _profile_start/defer _profile_end.
smoke test/profile_attr_test.zbr

# g.lowLevel sub-API: DrawList drawing + position queries + layout helpers.
smoke test/lowlevel_smoke_test.zbr

# BUG-116: char method dispatch (isAlpha/isDigit/isWhitespace/isUpper/isLower/toUpper/toLower).
smoke test/bug116_char_methods_test.zbr
# BUG-117: List.join(sep) — swap inverted args to std.mem.join (separator first, list.items second).
smoke test/bug117_list_join_test.zbr
# BUG-118: plain struct construction → struct literal (no cue init means no .init() method).
smoke test/bug118_struct_ctor_test.zbr
# BUG-091: List/HashMap params mutated inside body emit *ArrayList and call site takes &.
smoke test/bug091_list_param_test.zbr
smoke test/bug091_dispatch_test.zbr
# BUG-092: typed `var lines: List(str) = s.split(sep)` auto-collects SplitIterator.
smoke test/bug092_split_to_list_test.zbr
# BUG-097: *ArrayList chain calls — Case 1 (ptr→ptr, no &) and Case 2 (ptr→value, .* deref).
smoke test/bug097_ptr_param_chain_test.zbr
# BUG-090: for n in Reflect.fieldNames(obj) — loop var element type is now str (not unknown).
smoke test/bug090_reflect_fieldnames_test.zbr
# BUG-089: mixin method return type inferred correctly; count() guard avoids .items.len heuristic.
smoke test/bug089_mixin_method_test.zbr
# BUG-096: List(SomeClass)() constructor — genTypeFromExpr must emit *ClassName for class type args.
smoke test/bug096_list_class_ctor_test.zbr
# BUG-093: s.len emits @as(i64,@intCast()) — matches QUICKSTART int contract.
smoke test/bug093_strlen_test.zbr

# Tuple/multi-return: (int,int) return type + var (x,y) = f() destructure + .0/.1 index.
smoke test/tuple_smoke_test.zbr

# For-loop tuple destructuring: `for a, b in List((T1, T2))` + where clause + HashMap regression.
smoke test/for_tuple_test.zbr

# Guarded for-in (`for x in list if cond`) and List.find(pred).
smoke test/for_in_guard_test.zbr

# Chained comparisons: a < b < c desugars to labeled-block and-chain.
smoke test/chained_cmp_test.zbr
# unless/until: parser-level desugar to if-not / while-not.
smoke test/unless_until_test.zbr
# A2: File.modtime → int? (nil on missing, not -1 sentinel).
smoke test/modtime_optional_test.zbr
# Profile stdlib: start/stop/report/dump_folded/reset (stack-based instrumentation).
smoke test/profile_test.zbr

# Stdlib additions: Math, Base64, String methods, Hash, File, misc (sys/Random/Path).
smoke test/stdlib_math_test.zbr
smoke test/stdlib_base64_test.zbr
smoke test/stdlib_str_test.zbr
smoke test/stdlib_hash_test.zbr
smoke test/stdlib_file_test.zbr
smoke test/stdlib_misc_test.zbr
smoke test/stdlib_path_test.zbr
smoke test/datetime_inzone_test.zbr
# Combined integration test: all stdlib additions together.
smoke test/stdlib_additions_test.zbr

# Scripting tools: first Zebra port of an escape-hatch guard script.
smoke tools/escape_hatches_check.zbr
# Scripting tool #1: strip invisible glyphs (U+FEFF / U+FE0F) from book .md files.
smoke tools/book_strip_invisibles.zbr
# Scripting tool #2: class Main → top-level def sweep.
smoke tools/sweep_class_main.zbr
# Scripting tool #3: migrate `as T` type-annotation syntax to `: T`.
smoke tools/migrate_colon_syntax.zbr
# Scripting tool #4: convert single-arm branch-on-as+else-pass to if-is-as form.
smoke tools/branch_to_if_is.zbr
# SIMD vector types: f32x8, i32x4, etc.
smoke test/simd_test.zbr

# Design c: `^ClassName` is rejected — a class is already a reference.
smoke_tc_fail test/bug078_double_box_test.zbr "a class is already a reference"

# Phase 2 TC diagnostics: bidirectional inference error fixtures.
# These must FAIL compilation with a "type mismatch" substring in stderr.
smoke_tc_fail test/tc_mismatch_var_test.zbr "type mismatch"
smoke_tc_fail test/tc_mismatch_return_test.zbr "type mismatch"
# with/guard/arena_scope body coverage (checkStmts recursion extension).
smoke_tc_fail test/tc_mismatch_with_test.zbr "type mismatch"
smoke_tc_fail test/tc_mismatch_guard_test.zbr "type mismatch"

# Phase 3 TC diagnostics: call-arg type checking.
# Positive: correct primitive arg types must compile clean.
smoke test/tc_call_match_test.zbr
# Negative: wrong primitive arg type must fail with "type mismatch".
smoke_tc_fail test/tc_mismatch_call_test.zbr "type mismatch"

# Phase 3C TC diagnostics: named-type / interface conformance checking.
# Positive: class implementing interface assigned to interface-typed var must compile clean.
smoke test/tc_iface_match_test.zbr
# Negative: class not implementing interface must fail with "type mismatch".
smoke_tc_fail test/tc_iface_mismatch_test.zbr "type mismatch"
# i→i: interface assigned to a parent interface it extends.
smoke test/tc_iface_i2i_match_test.zbr
# i→i mismatch: interface assigned to unrelated interface must fail.
smoke_tc_fail test/tc_iface_i2i_mismatch_test.zbr "type mismatch"
# Transitive: class → IFoo → IBase, assigned to IBase.
smoke test/tc_iface_transitive_match_test.zbr
# Transitive mismatch: chain does not reach target interface.
smoke_tc_fail test/tc_iface_transitive_mismatch_test.zbr "type mismatch"
# Generic class instance assigned to interface-typed var.
smoke test/tc_iface_generic_match_test.zbr
# Generic class that does not implement the interface must fail.
smoke_tc_fail test/tc_iface_generic_mismatch_test.zbr "type mismatch"

# `zebra test` subcommand: assert_eq/ne/true/false + test runner.
smoke_test test/test_module_test.zbr

# Random instance form (A3, #216): Random.new(seed) → independent PRNG stream;
# verifies determinism + range bounds via the `zebra test` runner.
smoke_test test/random_instance_test.zbr

# `expr to!` removed (#218): force-unwrap is `expr!`. `to!` must no longer parse.
smoke_tc_fail test/to_bang_removed_test.zbr "'to'"
# §28b step 5: implicit error propagation (a throws call without `?`) is now rejected.
smoke_tc_fail test/fail_fixtures/implicit_try_rejected_test.zbr "throws call needs"

# `print X` statement form removed (#220): print is a function `print(X)`.
smoke_tc_fail test/print_stmt_removed_test.zbr "expected '('"

# BUG-199: a leading non-`static` modifier on a bad top-level decl used to hang the
# selfhost parser (error-recovery no-progress loop). Must reject fast, not hang.
smoke_tc_fail test/bug199_recovery_hang_test.zbr "unexpected top-level token"

# G2 FU1: only struct/class may be body-less (marker types). interface/mixin/extend/enum
# require a body; a zero-variant enum is degenerate. See grammar.txt MemberBlockOpt.
smoke_tc_fail test/empty_interface_rejected_test.zbr "must have a body"
smoke_tc_fail test/empty_enum_rejected_test.zbr "must have at least one variant"

# BUG-200: a deeply-nested expression must raise a clean diagnostic, not segfault the
# recursive-descent parser (parseExpr depth guard). Also a hang/crash guard for smoke.
smoke_tc_fail test/bug200_deep_nesting_test.zbr "nested too deeply"

# Size unified on `.len` (#219): List.len, HashMap.len, maintained `len` field on
# a user class; `str.count(sub)` substring method preserved.
smoke_test test/len_size_test.zbr

# BUG-144: a List param forwarded by bare ident to a mutating callee must emit as
# `*ArrayList` (transitive addr-of). Regression for the cursor/accumulator pattern.
smoke_test test/transitive_list_param_test.zbr

# BUG-145: `for x in f()?` — for-in over a `?`-propagated throws-call must
# parenthesize the try-expr before `.items`: `(try f()).items`.
smoke_test test/forin_throws_test.zbr

# BUG-146: str.tryInt()/tryFloat() return nil (not 0) on parse failure.
smoke_test test/try_parse_test.zbr

# BUG-148: member chained on a HashMap fetch (m.fetch(k).at(i)) compiles via `.?`.
smoke_test test/hashmap_fetch_chain_test.zbr

# Multi-error parse recovery: two parse errors must both appear in the output.
smoke_multi_parse_fail test/multi_parse_error_test.zbr ":3:9:" ":7:9:"

# Run a fixture via the bootstrap compiler (not selfhost) and check its stdout
# contains the expected substring.  Used for runtime API smoke tests where
# the selfhost TC/codegen parity for that feature is not yet ported.
smoke_run() {
    local zbr="$1"
    local expected="$2"
    local label
    label="$(basename "$zbr" .zbr)_run"
    local got
    if got=$("$ZEBRA" "$zbr" 2>&1); then
        if echo "$got" | grep -qF -- "$expected"; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (expected '$expected' in output)" >&2
            echo "    got: $got" >&2
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: $label (non-zero exit)" >&2
        echo "$got" >&2
        FAIL=$((FAIL + 1))
    fi
}

# smoke_run_bounded <zbr> <expected> [secs] — smoke_run with a HARD wall-clock ceiling.
#
# WHY THIS EXISTS: no other helper here has a timeout, so a fixture that fails to
# terminate hangs the entire tier rather than failing it. That is not hypothetical --
# `ws_smoke_test.zbr` calls `Ws.serve` and never returns (SIGTERM at 45 s), and
# `output_sweep` auto-excludes three server fixtures for the same reason. Any fixture
# that binds a socket, spawns a thread, or waits on I/O belongs here rather than in
# `smoke_run`.
#
# TIMEOUT IS REPORTED AS ITS OWN VERDICT, and that distinction is the point. `timeout`
# exits 124; without special-casing it, a hang would print "FAIL (expected '...' in
# output)" -- which reads as a behaviour regression and sends the next session hunting a
# codegen bug that does not exist. A hang and a wrong answer are different findings.
smoke_run_bounded() {
    local zbr="$1"
    local expected="$2"
    local secs="${3:-30}"
    local label
    label="$(basename "$zbr" .zbr)_run"
    local got rc
    got=$(timeout "$secs" "$ZEBRA" "$zbr" 2>&1); rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "  FAIL: $label (TIMEOUT after ${secs}s — did not terminate)" >&2
        echo "    NOTE: this is a HANG, not a wrong answer. Do not read it as a" >&2
        echo "          behaviour regression until you have ruled out a blocked" >&2
        echo "          accept()/recv() or a server thread outliving main." >&2
        echo "$got" >&2
        FAIL=$((FAIL + 1))
    elif [[ $rc -ne 0 ]]; then
        echo "  FAIL: $label (non-zero exit $rc)" >&2
        echo "$got" >&2
        FAIL=$((FAIL + 1))
    elif echo "$got" | grep -qF -- "$expected"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected '$expected' in output)" >&2
        echo "    got: $got" >&2
        FAIL=$((FAIL + 1))
    fi
}

smoke_run_bootstrap() {
    local zbr="$1"
    local expected="$2"
    local label
    label="$(basename "$zbr" .zbr)_run"
    local got
    if got=$("$BOOTSTRAP" "$zbr" 2>&1); then
        if echo "$got" | grep -qF -- "$expected"; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (expected '$expected' in output)" >&2
            echo "    got: $got" >&2
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: $label (non-zero exit)" >&2
        cat "$TMPDIR_OUT/smoke-err" >&2 || true
        FAIL=$((FAIL + 1))
    fi
}

# Build stdlib module: Build.new / b.exe / b.lib / target.linkLib / platform / option / dependency.
# Uses bootstrap compiler — selfhost TC/codegen parity for Build is pending.
smoke_run_bootstrap test/build_smoke_test.zbr "build api: ok"
# Declarative style: same API surface but no b.run() call (auto-run injected by `zebra build`).
smoke_run_bootstrap test/build_declarative_test.zbr "build declarative: ok"

# List(^T).add(val) auto-boxing: struct values heap-boxed when stored in List(^T).
smoke test/list_ref_autobox_test.zbr

# Visibility: private/public/internal/protected modifier enforcement.
# Positive: private field read/written inside same class compiles and runs.
smoke test/visibility_test.zbr
# Negative: private field accessed from outside owning class must fail TC.
smoke_tc_fail test/visibility_tc_fail.zbr "is private"

# Diagnostics: nested `def` gives a clear message (not "unexpected expression
# token: 'def'"). Verifies the friendlier parse-error wording + that it fires.
smoke_tc_fail test/diag_nested_def_test.zbr "can't appear in expression position"
smoke_tc_fail test/diag_toplevel_stmt_test.zbr "can't appear at the top level"
smoke_tc_fail test/diag_undefined_name_test.zbr "undefined name:"
# BUG-142: calling a function with too few args emits a (non-fatal) warning
# instead of silently padding with `undefined`. Warning, not error, because the
# Luau translator pervasively produces too-few-arg calls (nil-default pattern).
# BUG-142 CLOSED 2026-07-31: too few/too many arguments are ERRORS now, not warnings
# (Sean's call). This moved smoke_warn -> smoke_tc_fail in the same commit as the
# promotion, because a fixture asserting the old severity would fail the moment it landed.
smoke_tc_fail test/arg_count_test.zbr "too few arguments"

# BUG-239: an empty list literal `[]` in expression position (argument, struct field,
# return value). Registered as a RUNNING guard because the failure was a Zig-level
# "local variable is never mutated" on the emitted labeled block — emit-only would
# still catch it, but running also pins that the callee actually receives an empty list.
smoke_run test/bug239_empty_list_literal_test.zbr "bug239_empty_list_literal_test: ok"

# BUG-238: `except` in an enum-dotted branch arm, reached through `use`. Reported as a
# regression that did not reproduce; registered as a RUNNING guard (smoke_run, not
# smoke) because the failure was a parse error in the DEP, which only a real import
# exercises. Prints 8 then 9.
smoke_run test/bug238_import_except_test.zbr "8"

# BUG-235: the `use` contract, both directions. The NEGATIVE one is the guard that
# matters — a bare `use` must not bind the dep's names. A period when it silently DID
# is what took the Luau corpus from 1482 compiling to 849 for five weeks, and only this
# direction can catch a return to that leniency.
smoke_run test/bug235_exposing_test.zbr "7"

# BUG-229: the tui emit must ASSIGN _tui_env, not merely declare it.
smoke_gui_emit_contains test/bug229_tui_env_assigned_test.zbr tui "_tui_env = "
smoke_tc_fail test/bug235_bare_use_test.zbr "undefined name: 'Widget'"
smoke_run test/arg_count_ok_test.zbr "Hello, World"

# ── stdlib run-and-compare coverage (B1 survivor follow-up, 2026-08-01) ──────────
# Four of the twelve B1 mutation survivors were in stdlib emitters, and
# tools/stdlib_run_coverage.py then found that 19 of 30 namespaces had NO fixture whose
# OUTPUT is checked. The tests below ALREADY EXISTED and were simply never registered with
# a helper that reads what they printed -- the gap was not missing tests and not missing
# gates, it was tests and gates never introduced to each other.
#
# Every expected string below was taken from a real run, not guessed.
#
# THE ONE THAT MATTERS MOST is terminal_test: "hello world" appears on ONE line because
# Terminal.write does not add a newline and Terminal.writeln does. Mutation survivor
# CodeGen.zbr:15635 flips `var is_println = mname == "writeln"`, swapping the two -- the
# output becomes "hello\n world" and this assertion is what notices. Do not "simplify"
# it to a marker line; the substring IS the test.
smoke_run test/terminal_test.zbr "hello world"
smoke_run test/arg_test.zbr "All arg tests passed."
smoke_run test/compress_test.zbr "All compress tests passed."
smoke_run test/hash_test.zbr "All hash tests passed."
smoke_run test/mime_test.zbr "All MIME tests passed."
smoke_run test/timer_test.zbr "All timer tests passed."
smoke_run test/uri_test.zbr "All URI tests passed."
smoke_run test/json_test.zbr "json_test: all assertions passed"
smoke_run test/stdlib_additions_test.zbr "stdlib_additions OK"
smoke_run test/profile_test.zbr "profile OK"
# Dir: the trailing "(N files found)" is machine-dependent, so the prefix is the assertion.
smoke_run test/dir_walk_test.zbr "dir_walk_test: ok"
smoke_run test/build_declarative_test.zbr "build declarative: ok"
smoke_run test/regex_test.zbr "abc NUM def NUM"
# Net: resolving the LOOPBACK literal needs no network and no DNS server, so this is
# deterministic on a disconnected machine. The test's other half (an invalid hostname
# returning 0 results) is deliberately NOT asserted -- an ISP with wildcard DNS hijacking
# returns a result for anything, and a fixture that fails on someone's home network is a
# fixture people learn to ignore.
smoke_run test/dns_test.zbr "-> 127.0.0.1"

# STILL UNCOVERED, with reasons -- see tools/stdlib_run_coverage.py:
#   Csv       BUG-242: csv_test.zbr references an undeclared CsvWriter (does not compile)
#   Progress  BUG-241: broken since the Zig 0.16 migration (std.Progress.start signature)
#   Ws        ws_smoke_test.zbr is a SERVER and does not terminate -- smoke_run would hang.
#             Needs a client+server fixture with a bounded wait, not a registration.
#   Shell     its only user is test/zebra_ide.zbr, an IDE harness rather than a unit
#             test. Needs a purpose-built test,
#             and one that does not depend on which shell utilities the host happens to have.
# Audit #2: a bare function name as a statement warns (forgotten call) instead of
# a cryptic Zig "value ignored" error.
smoke_warn test/forgot_parens_test.zbr "did you mean to call it"
# Audit #3: a type-mismatched argument in a NESTED call is now caught (the
# arg-type check reaches nested calls, not just direct ones).
smoke_tc_fail test/arg_type_nested_test.zbr "type mismatch: expected int"
# Precise spans: a method-call arg-type mismatch anchors at the method name.
smoke_tc_fail test/member_call_diag_test.zbr "type mismatch: expected int"
# Precise spans: an arg-type mismatch anchors at the argument (an identifier here).
smoke_tc_fail test/arg_anchor_test.zbr "type mismatch: expected int"
# Audit #4: method/field-not-found errors read in Zebra terms, no .zig leak.
smoke_run_fail test/method_not_found_test.zbr "in 'str'"
smoke_run_fail test/field_not_found_test.zbr "in struct 'P'"
# Caret-specific: asserts the rendered source line appears in the TypeChecker's
# type-mismatch diagnostic (only emitted when caretSuffix() works).
smoke_tc_fail test/diag_type_mismatch_test.zbr 'var count: int = "not a number"'

# Interface vtable construction: class implementing interface coerced to interface var.
# Full run (not just emit) to verify vtable dispatch produces correct output.
smoke_run test/dynlib_iface_test.zbr "Hello, World!"
# Throws interface: vtable shim must propagate anyerror! and `try` correctly.
smoke_run test/dynlib_iface_throws_test.zbr "dynlib_iface_throws: OK"
# Interface method return-type inference: print format spec + vtable dispatch for same-module interfaces.
smoke_run test/iface_print_test.zbr "iface_print: OK"
# Tuple type inference: element types inferred from tuple_lit + member access (.0/.1); destructuring binds correct types.
smoke_run test/tuple_smoke_test.zbr "done"
# Optional chaining: expr?.member and expr?.method(args) — nil base propagates nil; non-nil accesses member/calls method.
smoke_run test/opt_chain_test.zbr "opt_chain: OK"

# Dispatch collision guards: user class methods that share names with stdlib heuristics
# (List.add/count/at/remove/contains/join/sort, StringBuilder.append/build/len) must
# not be silently rerouted to the stdlib codegen path.
smoke_run test/dispatch_collision_test.zbr "dispatch_collision: OK"
# BUG-140: a List field and a HashMap field of the same name in different classes
# must dispatch by the CURRENT class's declared type (List.len→items.len, not
# HashMap.count()). Asserts the List-side length resolved correctly at runtime.
smoke_run test/hashmap_field_collision_test.zbr "list_size=1"
# BUG-141: indexing a List receiver (local or field) with [i] must emit .items[i].
smoke_run test/list_index_test.zbr "local=20"
# HashMap heuristic collision: user class with set/get/contains/remove/count/keys/values
# methods must not be routed through HashMap codegen.
smoke_run test/hashmap_dispatch_collision_test.zbr "hashmap_dispatch_collision: OK"

# for-in element types: loop variables must carry the correct type so method calls on them
# dispatch correctly (char predicates from .chars(), str methods from List(str), arithmetic
# from List(int)).
smoke_run test/for_in_elem_test.zbr "for_in_elem: OK"

# `in` operator disambiguation: substring test / List membership / array literal membership
# must each emit distinct Zig — wrong dispatch gives wrong boolean results silently.
smoke_run test/in_operator_test.zbr "in_operator: OK"

# str method chain: split→count/at/join, trim→len, upper/lower chains — all must correctly
# infer the str receiver type so the right method is emitted.
smoke_run test/str_method_chain_test.zbr "str_method_chain: OK"

# TC type propagation through method chains: List(str).at() → str, split→List(str)→at→str,
# user class method returns — downstream method calls must dispatch correctly.
smoke_run test/type_infer_chain_test.zbr "type_infer_chain: OK"

# `<-` deep copy-out: List(str), List(int), and recursive class instances must all
# survive arena deinit — plain assign was wrong before _zbr_deep_copy was added.
smoke_run test/allocate_copyout_deep_test.zbr "allocate_copyout_deep: OK"

# Chan(T): buffered channel API (send/recv/close) + `<-` sugar — single-threaded.
smoke_run test/chan_smoke_test.zbr "chan: OK"
# Chan(T) + sys.go(): producer/consumer via fire-and-forget thread spawn.
smoke_run test/chan_thread_test.zbr "chan_thread: OK"

# BUG-119: List fields accessed through function parameters now emit .items.len.
smoke_run test/bug119_list_field_param_test.zbr "bug119_list_field_param: OK"

# Type aliases: transparent alias + where-clause constraint check at variable declaration.
smoke_run test/type_alias_test.zbr "hello"
smoke_run test/refinement_type_test.zbr "85"

# BUG: for-loop iterator variable collision — two loops with the same var name in the same scope.
smoke_run test/iter_collision_test.zbr "abc xyz 2 1"

# Exhaustiveness checking: branch on enum/union covers all members without else.
smoke_run test/enum_branch_test.zbr "north"

# Tcp.serve(port, handler) — compile smoke (server blocks; don't run).
smoke_run test/tcp_serve_test.zbr "tcp_serve_test OK"

# Atomic(T) — lock-free counter/flag: load/store/add/sub/swap/cas.
smoke_run test/atomic_test.zbr "atomic_test OK"

# WebSocket API: Ws.connect/serve/WsConn.send/recv/close emit-zig smoke test.
smoke test/ws_smoke_test.zbr

# gzip compress + gunzip round-trip: unblocked by Zig 0.16 (flate.Compress.init).
smoke test/compress_test.zbr

# Generic functions: def identity(T)(x: T): T — comptime type params, multi-type-arg calls.
smoke_run test/generic_fn_test.zbr "generic functions: OK"

# Reflect.hostKind(x): comptime substrate category (dynamic-interop primitive).
smoke_run test/hostkind_test.zbr "hostKind: OK"

# `stop` is not a reserved keyword — `.stop()` works as a method name.
smoke_run test/stop_method_test.zbr "stop-method: OK"

# `is not` operator: x is not Union.variant — negated type/variant check.
smoke_run test/is_not_test.zbr "is_not: OK"

# `is not` on class type-tag: x is not ClassName — emits !(x._type_tag == _ttag_C).
smoke_run test/is_not_class_test.zbr "is_not_class: OK"

# `not x is not V` precedence: not binds looser than is not → not (x is not V).
smoke_run test/is_not_precedence_test.zbr "is_not_precedence: OK"

# MVU Gui.run: 6-arg form Gui.run(t,w,h,init,update,view) — emits _gui_mvu_run.
smoke examples/counter.zbr

# `using EXPR` scope-block: calls expr.begin(); defer expr.end(); executes body.
smoke_run test/in_scope_test.zbr "in_scope_test PASS"
# TC negative: class missing begin()/end() must fail with a diagnostic.
smoke_tc_fail test/in_scope_tc_fail_test.zbr "must define 'def begin()'"

# `x!` postfix force-unwrap: alias for `x to!`; enables x!.method() chaining.
smoke_run test/postfix_bang_test.zbr "postfix_bang_test PASS"

# BUG-122: opt_ptr_field_bindings seeded for local var declarations (not just parameters).
# opt_ptr_local_var_test: regression sentinel only — same-module class ^T? (Node.next)
#   passes trivially (class types are heap pointers; no .* needed).
# val_test: the real BUG-122 test — cross-module union ^Val? accessed via local var,
#   exercises the .?.* deref path that was missing before the fix.
smoke_run test/opt_ptr_local_var_test.zbr "opt_ptr_local_var: OK"
smoke_run test/val_test.zbr "val_test: OK"

# `with` desugars bare method calls: `text("x")` → `g.text("x")` inside a `with g` block.
smoke_run test/with_call_test.zbr "with_call_test PASS"

# Log.json (JSON-lines format) + Log.setFile (file sink).
smoke_run test/log_json_test.zbr "log_json_test OK"

# Crypto.encrypt/decrypt — AES-256-GCM with SHA-256 key derivation.
smoke_run test/crypto_test.zbr "crypto_test OK"

# ThreadPool(n) — bounded worker pool with Atomic counter (capturing lambda).
smoke_run test/thread_pool_test.zbr "thread_pool_test OK"
# BUG-152: ThreadPool.submit with a NON-capturing `def() fn()` lambda (fn-ptr path).
smoke_run test/threadpool_nocapture_test.zbr "threadpool_nocapture_test OK"

# BUG-151: `var _ = expr` discard idiom lowers to a bare `_ = expr;`.
smoke_run test/discard_var_test.zbr "discard_var_test OK"

# BUG-150: sys.sleep routes through std.Io.sleep on Zig 0.16 (run, not emit-only).
smoke_run test/sys_sleep_test.zbr "sys_sleep_test OK"

# UDP — Udp.bind(port) + Udp.socket() + send/recv/close round-trip.
smoke_run test/udp_test.zbr "udp_test OK"

# Http.serve(port, handler) — compile smoke (server blocks; don't run).
smoke_run test/http_serve_test.zbr "http_serve_test OK"

# SQLite — open/exec/query/close + transactions on :memory: database.
smoke_run test/sqlite_test.zbr "sqlite_test OK"

# GUI widgets: progressBar(label,f64) + combobox(label,List(str),int) + spinbox(label,int,int,int).
smoke examples/widget_smoke.zbr

# GUI file dialogs: openFile/saveFile/openFolder/?[]const u8 + msgBox/msgBoxError.
smoke examples/file_dialog_smoke.zbr

# IO + networking + threads showcase: TCP key-value store (Tcp.serve on a sys.go
# thread, client round-trips, File persistence).  Emit-only here (binds a port +
# has timing); see its header for how to run it.
smoke examples/kv_store.zbr

# Nested namespaces: dotted syntax (Outer.Inner) and nested syntax.
smoke_run test/nested_namespace_dotted_test.zbr "hi"
smoke_run test/nested_namespace_nested_test.zbr "hi"

# DynLib producer side: export def + @export class factory.
smoke_run test/dynlib_export_def_test.zbr "42"
smoke_run test/dynlib_export_class_test.zbr "dynlib_export_class OK"

# BUG-138: same-named field of different types across classes (`source: str`
# vs `source: List`) — `.len` must use each class's own field type.
smoke_run test/field_name_collision_test.zbr "text=5 list=3"

# Module-level var/const: file-scope mutable state + named constants, mutated
# across functions and read via interpolation / int-method dispatch.
smoke_run test/module_var_test.zbr "module_var_test: OK"

# BUG-153: module-global allocating containers (HashMap/Atomic) init via the
# generated _initModuleVars() (declared `= undefined` at container scope).
smoke_run test/module_global_container_test.zbr "module_global_container_test OK"
# BUG-157: module-global USER CLASS INSTANCE globals (`var g: Foo = Foo()`) defer
# their allocating init to _initModuleVars() too (in source order, so a global may
# be constructed from an earlier-declared one).
smoke_run test/module_global_class_instance_test.zbr "module_global_class_instance_test OK"
# BUG-159 (fuzzer F3): mutated local with a comptime-numeric binary-op init needs
# an explicit `: i64`/`: f64` annotation (was omitted by selfhost).
smoke_run test/fuzz_f3_comptime_local_test.zbr "fuzz_f3: OK"
# BUG-160 (fuzzer F4): interpolation of a non-string uses the type-appropriate spec
# ({d} for float, {any} for List/struct) — a hardcoded `{}` diverged from bootstrap.
smoke_run test/fuzz_f4_interp_fmt_test.zbr "fuzz_f4: OK"
# BUG-162 (fuzzer F1): identifiers shadowing Zig primitives escape to @"name".
smoke_run test/fuzz_f1_primitive_names_test.zbr "fuzz_f1: OK"
# BUG-161 (fuzzer F2): unused-local discard vs annotation / this / interp / orelse.
smoke_run test/fuzz_f2_unused_local_test.zbr "fuzz_f2: OK"
# BUG-164 + BUG-166 (fuzzer F6/F10): unused if-as/for-in captures discarded;
# else-branch self-use seen by the `_ = self;` suppression.
smoke_run test/fuzz_f6_unused_capture_test.zbr "fuzz_f6: OK"
# BUG-163 (fuzzer F7): orelse/catch/try/if-expr self-parenthesize.
smoke_run test/fuzz_f7_precedence_test.zbr "fuzz_f7: OK"
# BUG-167 (fuzzer F8): call-form ternary if(c,t,e) in both parsers; @as-typed arms.
smoke_run test/fuzz_f8_ternary_test.zbr "fuzz_f8: OK"
# BUG-165 (fuzzer F9): range for-in — `:`/`..`/`.to()` all lower to the i64 for_num.
smoke_run test/fuzz_f9_range_test.zbr "fuzz_f9: OK"
# BUG-169 (fuzzer F11): unused if-as/for-in/local discard when body holds a
# ternary or branch — mightUseName* now model those forms (both compilers).
smoke_run test/fuzz_f11_unused_capture_ternary_test.zbr "fuzz_f11: OK"
# §28f functional trio: List.map/filter/reduce with element-typed lambda params.
smoke_run test/list_functional_test.zbr "list_functional: OK"
# Audit B2: map/filter on a list-literal-initialized var (element type inferred).
smoke_run test/list_literal_map_test.zbr "list_literal_map: OK"
# §28f: HashMap.keys()/values() → List(K)/List(V), annotated + direct iteration.
smoke_run test/hashmap_kv_test.zbr "hashmap_kv: OK"
# §28f: List.sort with an optional comparator — sort() natural, sort(cmp) custom.
smoke_run test/list_sort_comparator_test.zbr "list_sort: OK"
# §28i: sys.memStats() → MemStats{ arenaBytes } — arena footprint grows on alloc.
smoke_run test/mem_stats_test.zbr "mem_stats: OK"
# §28h: ObjectPool(T) — take()/give()/inUse(), exhaustion nil, double-give guard.
smoke_run test/object_pool_test.zbr "object_pool: OK"
# File.rename parity: Zig-0.16 rename(old_dir, sub, new_dir, sub, io) on both compilers.
smoke_run test/file_rename_test.zbr "file_rename OK"
# §28b: HashMap.entries() → List((K,V)) — sortable map snapshot (sort by value).
smoke_run test/hashmap_entries_test.zbr "hashmap_entries: OK"
# §28f: generic Set(T) — add/contains/remove/len/count/items/clear (int + str).
smoke_run test/set_basic_test.zbr "set_basic: OK"
# §28f: Set(T) generic-machinery paths — field, param mutation, return, for-in,
# membership, nesting List(Set(int)).
smoke_run test/set_advanced_test.zbr "set_advanced: OK"
# §28f: set literal syntax {a, b, c} — int/str, typed, bare, for-in, membership.
smoke_run test/set_literal_test.zbr "set_literal: OK"
# §28f: dict literal syntax {k: v, ...} — str/int keys, typed, empty {}, for k,v.
smoke_run test/dict_literal_test.zbr "dict_literal: OK"
# BUG-203: explicit `.eql(value)` on a @derive(Eq) struct addresses the value arg.
smoke_run test/derive_eql_explicit_test.zbr "derive_eql_explicit: OK"
# Full-corpus sweep (2026-07-24): stale tests using removed syntax, refreshed to
# current forms (print("x") not print "x"; `: T` not `as T`) and now gated.
smoke_run test/branch_inline_return_test.zbr "branch inline return OK"
smoke_run test/branch_exhaustive_test.zbr "branch_exhaustive: OK"
smoke_run test/tuple_test.zbr "tuple_test: OK"
# Audit A3: exhaustive union branch + else must compile (else prong omitted).
smoke_run test/branch_exhaustive_else_test.zbr "branch_exhaustive_else: OK"
# Audit B1: indexed for-in `for i, v in list` (i = index, v = element).
smoke_run test/for_indexed_test.zbr "for_indexed: OK"
# Audit B9: `is Union.Variant as n` on an OPTIONAL union (unwrap then tag-check).
smoke_run test/optional_union_is_test.zbr "optional_union_is: OK"
# Audit B12: inline / comma `except` — `base except a = 5, b = 6` (+ assign-except).
smoke_run test/except_inline_test.zbr "except_inline: OK"
# Audit B11: `while var x = EXPR, GUARD` bind-and-guard loop (already implemented).
smoke_run test/while_var_test.zbr "while_var_test: all OK"
# Audit B10: backed enum `enum Status(int)` with explicit member values.
smoke_run test/backed_enum_test.zbr "backed_enum: OK"
# A user method named like a SIMD reduction (sum/dot/max_element/min_element)
# must dispatch to the user method, not @reduce (found while investigating B8).
smoke_run test/struct_simd_name_method_test.zbr "struct_simd_name_method: OK"
# Audit B4: a mutating `capture` closure (`count += 1`) — *@This() self + var binding.
smoke_run test/mutating_capture_test.zbr "mutating_capture: OK"
# Audit B3: params referenced inside a zig"…" literal are used (no `_ = p;` discard).
smoke_run test/ziglit_param_test.zbr "ziglit_param: OK"
# Design-a: `allocate Debug()` = scoped arena + allocation-stats reporter at block exit.
smoke_run test/allocate_debug_stats_test.zbr "allocate_debug_stats: OK"
# Audit B5 (option a): `obj is IFace` — compile-time interface conformance.
smoke_run test/interface_is_test.zbr "interface_is: OK"
# B5 (option b): runtime `is` on an interface-typed value (RTTI via _type_tag).
smoke_run test/interface_rtti_test.zbr "interface_rtti: OK"
# Class→interface coercion passes ctor args (non-default constructor).
smoke_run test/interface_coerce_ctor_test.zbr "interface_coerce_ctor: OK"
# Class→interface coercion at a call-argument position (positional + named).
smoke_run test/interface_coerce_arg_test.zbr "interface_coerce_arg: OK"
# BUG-171: bare `'Z'` char literals (selfhost lexer treated them as strings).
smoke_run test/char_literal_test.zbr "char_literal: OK"
# BUG-170: value struct assigned into a `^T` field is heap-boxed (selfhost genAssign).
smoke_run test/ref_struct_test.zbr "ref_struct_test OK"
# Statement-body lambda in `return` position (bootstrap grammar gap; selfhost ok).
smoke_run test/return_lambda_test.zbr "return_lambda: OK"
# Closure factories: `return <capture closure>` with the struct hoisted to a
# module-level named type so the fn can name it as its return type.
smoke_run test/closure_factory_test.zbr "closure_factory: OK"
# Inline function-pointer type annotation `def(P): R` (an anonymous `sig`).
smoke_run test/fn_type_annotation_test.zbr "fn_type_annotation: OK"
# Nested/higher-order fn-types (selfhost encoding nesting-safety regression guard).
smoke_run test/fn_type_nested_test.zbr "fn_type_nested: OK"
# fn-type call-result inference across plain-local / factory-result / capture-field
# binding scopes (float interpolation discriminates {d} from the {any} fallback).
smoke_run test/fn_type_infer_test.zbr "fn_type_infer: OK"
# Audit B6/B7: struct fields stay contiguous (static var / @once field / mixin
# method must not split instance fields) — genClass emits fields-first.
smoke_run test/field_order_test.zbr "field_order: OK"
# BUG-168: cross-module free fns returning PRIMITIVES typed at call sites
# (concat/arith dispatch); genBinary .add checks both operands.
smoke_run test/bug168_crossmod_prim_return_test.zbr "bug168: OK"

# BUG-172: char/uint (keyword primitives) as a generic type arg (`List(char)`) —
# was rejected as "undefined name" by the selfhost resolver (isBuiltin gap).
smoke_run test/bug172_list_char_test.zbr "bug172: OK"

# BUG-173: untyped local `var` from a string-typed NON-literal init (ternary /
# concat / call) was emitted without a `: []const u8` annotation, so Zig inferred
# a fixed-size `*const [N:0]u8` and a later differently-sized string assignment
# failed to unify. Fixed by mirroring the bootstrap's tcTypeAnnotation fallback.
smoke_run test/bug173_string_coerce_test.zbr "bug173: OK"

# BUG-176: inferred `var cols = s.split(sep)` / `s.lines()` now materializes into a
# List(str) so it is indexable (cols[i], cols.len, cols.at(i)); for-in stays lazy.
smoke_run test/bug176_split_list_test.zbr "bug176: OK"

# BUG-178: str.toString() is identity (not `{}` allocPrint). BUG-177: a List-returning
# call result indexed directly — `f()[i]` — emits `.items[i]` (converges selfhost).
smoke_run test/bug177_178_index_tostring_test.zbr "bug177_178: OK"

# BUG-196: container-method dispatch on a for-binding over List(List(T)) — .len/.at on
# the inner-List loop var must dispatch as a List (genForIn binds the loop var's element type).
smoke_run test/bug196_nested_list_test.zbr "bug196: 43"

# BUG-193: File.listDir ported to the selfhost (was @compileError); returns List(str).
smoke_run test/bug193_listdir_test.zbr "bug193: OK"

# BUG-195: .entries()/.keys()/.values() on a HashMap PARAMETER (a *HashMap) — preamble
# _MapKV derefs the pointer before reading .KV (worked on a local, failed on a param).
smoke_run test/bug195_map_param_test.zbr "bug195: 62"

# BUG-198 guard: non-optional union value -> optional union field (regression guard;
# the reported create()-drops-type bug no longer reproduces — see BUGS.md).
smoke_run test/bug198_union_optional_field_test.zbr "bug198: OK"

# §28j: concurrent allocation on the shared arena is safe (ThreadSafeAllocator wrapper).
# 8 workers each build a 500-element List; the sum must be exact and stable. (The unsafe
# allocate-scope-under-concurrency residual is demonstrated by the unregistered
# arena_concurrency_hazard_test — see docs/concurrency_allocation_design.md.)
smoke_run test/thread_alloc_stress_test.zbr "thread_alloc_stress: OK"

# Empty / marker structs+classes are legal (2026-07-23): body-less struct/class is a
# valid instantiable marker type. grammar.txt MemberBlockOpt; fuzz/FINDINGS.md G2.
smoke_run test/marker_struct_test.zbr "marker: OK"

# BUG-155 (List.set element setter) + BUG-156 (str method on a List.at() result).
smoke_run test/list_setter_parse_test.zbr "list_setter_parse_test OK"

# BUG-137: module var named like a preamble local/param (`total`, `count`) must
# compile (emitted as `_zbr_mv_*`); a shadowing local keeps its bare name.
smoke_run test/module_var_collision_test.zbr "module_var_collision_test: OK"

# BUG-137 residual: for-in / for-num / if-capture bindings also shadow a
# same-named module var (keep the bare name); module vars stay untouched.
smoke_run test/module_var_shadow_test.zbr "module_var_shadow_test: OK"

# BUG-214: `g.send(Msg.bump)` on a MIXED union(enum) Msg (>=1 payload variant).
# A bare no-payload variant is the 1-byte TAG in Zig, not the union, so the
# type-erased MVU send copied @sizeOf(Msg) bytes out of it and aborted.  Runs
# under the stub GUI backend (one frame, no display), so this is a real runtime
# gate: pre-fix it panicked with "incorrect alignment".
smoke_run test/mvu_mixed_union_test.zbr "update: set_label -> hello"

# BUG-215: two-argument `str.indexOf(sub, from)` silently dropped the offset —
# every search restarted at 0.  Found via the IDE crashing on Check / List Targets.
# Was a codegen @compileError (asserted with smoke_emit_contains); #5a moved it into
# the TYPE CHECKER, so it is now rejected before emit with a source location — the
# point of BUG-215, and it generalises from `indexOf` alone to the whole documented
# stdlib surface in both directions (BUG-222 = the too-few half).
smoke_tc_fail test/fail_fixtures/indexof_arity_rejected_test.zbr \
    "str.indexOf expects 1 argument, got 2"

# #5a positive side, and the one that matters more: every call shape the arity
# checker must ACCEPT. A signature table that is WRONG is worse than none — a bad
# row rejects valid code and the user cannot work around it — so the defaulted rows
# are exercised in BOTH forms (`padLeft(20)` and `padLeft(20, ".")`; `fill` really
# does default, confirmed by running it). Also covers a user class with a `count`
# method, to prove an unknown receiver gets NO opinion rather than a stdlib verdict.
smoke_run test/stdlib_arity_ok_test.zbr "stdlib_arity_ok_test: OK"

# BUG-224: `format()` emitted one `.{ x }` tuple PER argument, so allocPrint got N+2
# arguments and any 2+-arg call failed to compile. The 1-arg case worked by coincidence
# and is the only shape the corpus used, which is why no gate saw it. Keep the multi-arg
# lines — a regression is a compile failure, not a wrong value.
smoke_run test/bug224_format_multiarg_test.zbr "bug224_format_multiarg_test: OK"

# BUG-226: `tokenize` was absent from isStrListCallExpr, so a FOR-HEADER call did not
# type its element as str and print emitted `{any}` — rendering `{ 97 }` for `a`. Bound
# form worked, which hid it. The failure is a wrong RENDERING, not a compile error, so
# this must be a run-and-compare fixture; no compile-only gate can see it.
smoke_run test/bug226_tokenize_forheader_test.zbr "bug226_tokenize_forheader_test: OK"

# BUG-218: `str + <number>` in ARGUMENT position used to escape the type checker
# and surface as a Zig error about generated code (_str_concat, a line inside a
# 3,800-line emitted file). Now a Zebra error located in the user's own source.
# String-plus-number in a print is the canonical beginner slip.
smoke_tc_fail test/fail_fixtures/str_plus_number_rejected_test.zbr \
    "cannot concatenate 'str' and 'int'"

# BUG-220: a top-level `def` whose name matches a preamble parameter/local used to
# fail to compile (15 of 16 everyday names — count, data, total, buf, body, color).
# Top-level defs now emit under the reserved `_zbr_fn_` prefix, mirroring `_zbr_mv_`
# for module vars (BUG-137). Exercises declaration, direct call, and — the subtle one
# — a function passed BY VALUE rather than called.
smoke_run test/toplevel_name_collision_test.zbr "toplevel_name_collision_test: OK"

# #3: the TypeChecker narrows `x` inside `if x != nil` (codegen already did),
# so a mistake there gets the Zebra diagnostic instead of a raw Zig error. The
# fixture also proves the narrowing is SCOPED — cases 3-6 would produce false
# errors if the restore leaked.
smoke_run test/nil_narrow_tc_test.zbr "nil_narrow_tc_test: OK"

# BUG-241. This file had NO registration of any kind, so no gate ever touched it, and it
# had not compiled since the Zig 0.16 migration (`std.Progress.start` gained an `Io`
# parameter). A never-passing file cannot regress a baseline, so full_sweep could not see
# it either — it was indistinguishable from an intentionally-negative test.
# Asserts the deterministic PRINT, not the bar: std.Progress detects a non-tty and renders
# nothing under the gate runner, so an expectation written against bar output would never
# match.
smoke_run test/progress_test.zbr "done"

# BUG-242. Same shape as BUG-241 above: no registration, so nothing ever ran it, and it
# could not regress a baseline it had never been in. The whole Csv namespace was dead in
# the selfhost — the READER too, contrary to the original ticket ("Csv. reading appears to
# work"): the preamble's parser still reassigned `.{}` to unmanaged ArrayLists, a Zig 0.16
# migration missed because nothing could reach the code to find out.
# Exercises RFC 4180 round-tripping (write a comma-bearing field, re-parse, compare), so it
# is a behaviour check and not just a compile check.
smoke_run test/csv_test.zbr "csv_test: all assertions passed"

# Regression fixtures for the two above. progress_test/csv_test are the FEATURE tests;
# these pin the specific defects, which is what bug_fixture_check asks for — it found
# BUG-241 marked fixed with no fixture at all, within minutes of the fix landing.
smoke_run test/bug241_progress_io_test.zbr "bug241: OK"
smoke_run test/bug242_csv_roundtrip_test.zbr "bug242: OK"

# §1b — the last two stdlib namespaces with no run coverage. BOTH use the BOUNDED helper:
# shell_test spawns a child process and ws_echo_test binds a socket and spawns a thread, so
# each has a way to not come back that a plain smoke_run would turn into a hung tier rather
# than a failed test.
#
# ws_echo_test was verified 6/6 consecutive before registration, and both its assertions
# were shown to fire independently — a wrong payload and an unreachable port produce
# DIFFERENT messages, so a port collision cannot read as a broken echo. A flaky fixture in
# the QUICK tier is worse than an uncovered namespace: it teaches people to re-run gates
# until they pass, which costs the whole tier its meaning.
smoke_run_bounded test/shell_test.zbr    "shell_test: OK" 90
smoke_run_bounded test/ws_echo_test.zbr  "ws_test: OK"    90
smoke_run_bounded test/bug245_shell_process_run_test.zbr "bug245: OK" 90
# BUG-227. Verified to FAIL against the unfixed compiler before being registered — the
# separators are multi-character on purpose, since tokenizeSequence and tokenizeAny agree
# on a single-char `seps` and a fixture using "," would have passed under the bug.
smoke_run test/bug227_tokenize_any_test.zbr "bug227: OK"

# BUG-247. Uses smoke_run_fail, which additionally asserts no `.zig:` path leaks -- this
# must stay a ZEBRA diagnostic. The fixture's identifier is deliberately non-ASCII; the
# rejection was never the bug, the fictional character in the message was.
smoke_run_fail test/bug247_nonascii_diag_test.zbr "unexpected non-ASCII byte"

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "selfhost smoke: $PASS/$((PASS + FAIL)) passed"
else
    echo "selfhost smoke: $PASS passed, $FAIL FAILED" >&2
    exit 1
fi
