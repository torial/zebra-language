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

echo "── Selfhost smoke tests (emit-zig pipeline)"

# Pure arithmetic / branching
smoke test/branch_edge_test.zbr
smoke test/branch_range_test.zbr

# Language features
smoke test/arena_scope_test.zbr
smoke test/char_tostring_test.zbr
smoke test/string_format_test.zbr

# Cross-module dep graph walk
smoke test/crossmod_arith_test.zbr
smoke test/crossmod_types_test.zbr

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

# Class-level (shared/static) var fields: pub var in Zig, read/write by class name.
smoke test/shared_var_test.zbr

# --turbo: require/ensure/invariant must be absent from generated Zig.
smoke_turbo test/turbo_test.zbr

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "selfhost smoke: $PASS/$((PASS + FAIL)) passed"
else
    echo "selfhost smoke: $PASS passed, $FAIL FAILED" >&2
    exit 1
fi
