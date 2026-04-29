#!/usr/bin/env bash
# escape_hatches_check.sh — guard against new page_allocator uses creeping
# into Zebra source / codegen / preamble.
#
# Why this matters:
#   Zebra programs use a single program-wide ArenaAllocator (`_allocator`)
#   reclaimed at program exit.  `std.heap.page_allocator` is the documented
#   *escape hatch* for state that must survive `arena_scope` rewinds — the
#   string intern pool, JSON parse output, HTTP response buffers, etc.
#
#   Each escape-hatch use is intentional and reviewed.  This script ensures
#   no NEW page_allocator use sneaks in without an explicit baseline bump
#   here, which forces a reviewer to understand why the new escape exists.
#
# How to update (only when the change is reviewed and intentional):
#   1. Verify the new page_allocator use has a comment explaining why
#      it must outlive the program arena.
#   2. Bump the relevant EXPECTED_* counter below.
#   3. Add a one-line note in the matching cluster comment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

# ── Baselines ─────────────────────────────────────────────────────────────
#
# selfhost/stdlib_preamble.zig — the runtime preamble embedded by both
# backends.  Clusters (as of 2026-04-28):
#   - 1× _arena root allocator (program arena lives on page_allocator)
#   - 3× _str_pool / _intern (interned strings survive arena rewinds)
#   - ~12× JSON parse/stringify/object/array/put-* (JsonValue outlives arenas)
#   - ~6× HTTP fetch + headers (response data outlives request arena)
#   - ~5× http_serve / Net misc helpers
#   - ~16× misc utilities (Hash, Compress, etc.) where Zig stdlib APIs
#          require an allocator and the result is meant to live forever
EXPECTED_PREAMBLE=43

# src/ — the Zig-implemented compiler.  page_allocator should appear ONLY in:
#   - 1× docstring comment (AstBuilder.zig)
#   - 4× CodeGen.zig (2× emitted Zig string literals for `_arena` and
#         `_str_pool` initializers; 2× in surrounding comments)
EXPECTED_SRC=5

# ── Count ─────────────────────────────────────────────────────────────────

count_in() {
    local pattern="$1"
    local files="$2"
    # shellcheck disable=SC2086
    grep -c "$pattern" $files 2>/dev/null \
        | awk -F: '{ sum += $NF } END { print (sum == "" ? 0 : sum) }'
}

ACTUAL_PREAMBLE="$(count_in 'page_allocator\b' selfhost/stdlib_preamble.zig)"
ACTUAL_SRC="$(count_in 'page_allocator\b' 'src/*.zig')"

FAIL=0

if [[ "$ACTUAL_PREAMBLE" -ne "$EXPECTED_PREAMBLE" ]]; then
    echo "escape_hatches_check: stdlib_preamble.zig count drift" >&2
    echo "  expected: $EXPECTED_PREAMBLE  actual: $ACTUAL_PREAMBLE" >&2
    echo "  file:     selfhost/stdlib_preamble.zig" >&2
    FAIL=1
fi

if [[ "$ACTUAL_SRC" -ne "$EXPECTED_SRC" ]]; then
    echo "escape_hatches_check: src/ page_allocator count drift" >&2
    echo "  expected: $EXPECTED_SRC  actual: $ACTUAL_SRC" >&2
    echo "  file(s):  src/*.zig" >&2
    grep -n "page_allocator\b" src/*.zig >&2 || true
    FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo >&2
    echo "If the new page_allocator use is intentional and reviewed:" >&2
    echo "  1. Verify it has a comment explaining why it must outlive the" >&2
    echo "     program arena (typically: survives an arena_scope rewind)." >&2
    echo "  2. Bump the matching EXPECTED_* in tools/escape_hatches_check.sh." >&2
    echo "  3. Update the cluster comment summarising the new use." >&2
    exit 1
fi

echo "escape_hatches_check: OK"
echo "  selfhost/stdlib_preamble.zig: $ACTUAL_PREAMBLE page_allocator uses (baseline $EXPECTED_PREAMBLE)"
echo "  src/*.zig:                    $ACTUAL_SRC page_allocator uses (baseline $EXPECTED_SRC)"
