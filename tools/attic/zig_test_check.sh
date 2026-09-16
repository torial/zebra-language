#!/usr/bin/env bash
# THE ZIG-SIDE TEST GATE (BUG-279) — the unit and integration binaries, and nothing else.
#
# WHY IT EXISTS. `zig build test` is a SUPERSET: unit + integration + selfhost_smoke
# (~14 min) + escape_hatches + compile_check (~6 min). The two heavy legs are ALREADY
# in the tiers, so gating the command itself would buy ~4 seconds of new coverage for
# ~20 minutes of duplicated work. The two Zig test binaries are covered by NOTHING
# else, and they are the cheap part.
#
# THE GAP WAS NOT THEORETICAL. Three unrelated failures sat on committed code because
# these tests were in neither a tier nor CLAUDE.md's uncovered table — the one state
# that section exists to make impossible. And fixing the two compile errors revealed
# what they had been hiding: TWO STALE TESTS asserting syntax the language had REMOVED
# (bare `print "..."`, and the `to!` operator). Each would have failed the day its
# feature was dropped, if anything could have run them.
#
# NOT INCLUDED YET: escape_hatches_check, which is currently RED on a page_allocator
# count review owned by another author (BUG-279 leg 3). Add `escape_hatches_check.sh`
# to the tail of this script when that clears.
#
# pins: BUG-279 the unit binary is where the two inverted Parser tests live (bare
#   `print` and `to!` must now be REJECTED); nothing ran them before this gate.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

OUT="$(zig build test-zig --summary all 2>&1)"
RC=$?

# CONTROL, and it is the point of using --summary all rather than the exit code alone:
# a step that ran NOTHING also exits 0 and prints nothing. Zig reports the count it
# actually executed, so require a non-trivial number to have run. Without this, deleting
# the dependOn lines would leave a permanently green gate measuring silence.
COUNT="$(printf '%s' "$OUT" | grep -oE '[0-9]+/[0-9]+ tests passed' | head -1 | cut -d/ -f1)"
if [ -z "${COUNT:-}" ]; then
    echo "zig-test: REFUSING TO REPORT — no test count in the build summary." >&2
    printf '%s\n' "$OUT" | tail -20 >&2
    exit 2
fi
if [ "$COUNT" -lt 100 ]; then
    echo "zig-test: REFUSING TO REPORT — only $COUNT tests ran; expected >=100." >&2
    echo "  A collapsed test set is a harness failure, not a clean result." >&2
    exit 2
fi

if [ "$RC" -ne 0 ]; then
    echo "zig-test: FAIL — $(printf '%s' "$OUT" | grep -E 'tests passed' | head -1)" >&2
    printf '%s\n' "$OUT" | grep -vE '^\s*$' | tail -25 >&2
    exit 1
fi
echo "zig-test: $(printf '%s' "$OUT" | grep -oE '[0-9]+/[0-9]+ tests passed' | head -1) (unit + integration; NOT smoke/compile_check — those are their own gates)"
