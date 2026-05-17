#!/usr/bin/env bash
# selfhost_smoke.sh — quick sanity check for the selfhost compiler pipeline.
#
# Runs zebra.exe (the selfhost primary binary) through --emit-zig on a small
# set of representative fixtures.  Each test passes if the emit exits 0 (full
# lex→parse→resolve→TC→codegen pipeline succeeded).  No Zig compilation is
# performed so this runs fast (~0.5–2 s per test, shared Zig cache).
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

TMPDIR_OUT="/tmp/selfhost-smoke"
rm -rf "$TMPDIR_OUT"
mkdir -p "$TMPDIR_OUT"
trap 'rm -rf "$TMPDIR_OUT"' EXIT

PASS=0
FAIL=0

smoke() {
    local zbr="$1"
    local label
    label="$(basename "$zbr" .zbr)"
    if "$ZEBRA" --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>/tmp/smoke-err; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label" >&2
        grep -v "^wrote \|^compiling:\|^ *parsing\|^ *parsed\|^ *resolved" /tmp/smoke-err >&2 || true
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
    if "$ZEBRA" --turbo --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>/tmp/smoke-err; then
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
        grep -v "^wrote \|^compiling:\|^ *parsing\|^ *parsed\|^ *resolved" /tmp/smoke-err >&2 || true
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}

# Run `zebra test` and check all tests pass (exit 0, no FAIL lines in output).
smoke_test() {
    local zbr="$1"
    local label
    label="$(basename "$zbr" .zbr)_test"
    if "$ZEBRA" test "$zbr" >/tmp/smoke-test-out 2>&1; then
        if grep -qF "FAIL:" /tmp/smoke-test-out; then
            echo "  FAIL: $label (some tests failed)" >&2
            cat /tmp/smoke-test-out >&2
            FAIL=$((FAIL + 1))
        else
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        fi
    else
        echo "  FAIL: $label (exit non-zero)" >&2
        grep -v "^compiling:\|^ *parsing\|^ *parsed\|^ *resolved\|^wrote " /tmp/smoke-test-out >&2 || true
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TMPDIR_OUT"/*.zig
}

# Run a fixture expected to FAIL TC with a specific diagnostic substring in stderr.
smoke_tc_fail() {
    local zbr="$1"
    local expected_msg="$2"
    local label
    label="$(basename "$zbr" .zbr)"
    if "$ZEBRA" --emit-zig "$zbr" --output-dir "$TMPDIR_OUT" >/dev/null 2>/tmp/smoke-err; then
        echo "  FAIL: $label (expected TC failure, got exit 0)" >&2
        FAIL=$((FAIL + 1))
    else
        if grep -qF "$expected_msg" /tmp/smoke-err; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (wrong/missing diagnostic)" >&2
            echo "    expected substring: $expected_msg" >&2
            grep -v "^compiling:\|^ *parsing\|^ *parsed\|^ *resolved" /tmp/smoke-err >&2 || true
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
smoke test/char_tostring_test.zbr
smoke test/interp_tostring_test.zbr
smoke test/string_format_test.zbr

# Cross-module dep graph walk
smoke test/crossmod_arith_test.zbr
smoke test/crossmod_types_test.zbr
smoke test/crossmod_struct_pat_test.zbr
smoke test/crossmod_hatopt_test.zbr

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
# Profile stdlib: start/stop/report/dump_folded/reset (stack-based instrumentation).
smoke test/profile_test.zbr

# Stdlib additions: Math, Base64, String methods, Hash, File, misc (sys/Random/Path).
smoke test/stdlib_math_test.zbr
smoke test/stdlib_base64_test.zbr
smoke test/stdlib_str_test.zbr
smoke test/stdlib_hash_test.zbr
smoke test/stdlib_file_test.zbr
smoke test/stdlib_misc_test.zbr
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
        if echo "$got" | grep -qF "$expected"; then
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

smoke_run_bootstrap() {
    local zbr="$1"
    local expected="$2"
    local label
    label="$(basename "$zbr" .zbr)_run"
    local got
    if got=$("$BOOTSTRAP" "$zbr" 2>&1); then
        if echo "$got" | grep -qF "$expected"; then
            echo "  PASS: $label"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $label (expected '$expected' in output)" >&2
            echo "    got: $got" >&2
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: $label (non-zero exit)" >&2
        cat /tmp/smoke-err >&2 || true
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

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "selfhost smoke: $PASS/$((PASS + FAIL)) passed"
else
    echo "selfhost smoke: $PASS passed, $FAIL FAILED" >&2
    exit 1
fi
