#!/usr/bin/env bash
# n1_runtime_check.sh -- does the N-1 anchor emit against ITS OWN runtime? (BUG-543)
#
# WHY: the compiler reads its runtime (stdlib_preamble.zig) from `selfhost/` relative to the
# CURRENT DIRECTORY first, and only then from beside its own exe. divergence_check ran the
# anchor from the repo root, so the anchor's emit was "N-1 codegen + TODAY's runtime": a
# runtime regression was invisible (both sides compiled against the same preamble), and
# deleting a runtime helper the anchor's codegen still calls would make every anchor-side
# file fail, score as an ADVANCE, and leave the REGRESSION count at 0 forever. Receipt,
# 2026-10-10: the same anchor binary printed the pre-switch answers for a container program
# from its cache dir and the post-switch answers from the repo root.
#
# WHAT IT ASSERTS, derived at run time rather than pinned to a known difference: lines that
# are ONLY in the anchor's preamble must appear in what the anchor emits, and lines that are
# ONLY in the tree's must not. Run the anchor exactly the way divergence_check now does --
# from its own directory -- on a hello-world.
#
#   bash tools/n1_runtime_check.sh <anchor zebra.exe>
#
# Exit 0: the anchor emitted its own runtime, or the two preambles are identical (said so).
# Exit 2: REFUSE -- the anchor's emit carried the tree's runtime, or the check could not run.
# Never prints a pass it did not measure.
set -u
ANCHOR="${1:?usage: n1_runtime_check.sh <anchor zebra.exe>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADIR="$(cd "$(dirname "$ANCHOR")" && pwd)"
APRE="$ADIR/stdlib_preamble.zig"
TPRE="$REPO/selfhost/stdlib_preamble.zig"
[ -f "$APRE" ] || { echo "n1_runtime_check: REFUSING -- no preamble beside the anchor ($APRE)" >&2; exit 2; }
[ -f "$TPRE" ] || { echo "n1_runtime_check: REFUSING -- no tree preamble ($TPRE)" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zbr-n1rt-$$"
rm -rf "$W"; mkdir -p "$W"
trap 'rm -rf "$W"' EXIT

# Candidate lines: trimmed, not comments, long enough not to occur by accident inside some
# other line (the check is a substring test, because emitting pub-marks declarations).
cands() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -vE '^(//|$)' | awk 'length($0) >= 30' | LC_ALL=C sort -u; }
cands "$APRE" > "$W/a.txt"
cands "$TPRE" > "$W/t.txt"
LC_ALL=C comm -23 "$W/a.txt" "$W/t.txt" | head -20 > "$W/a_only.txt"
LC_ALL=C comm -13 "$W/a.txt" "$W/t.txt" | head -20 > "$W/t_only.txt"
na=$(wc -l < "$W/a_only.txt" | tr -d ' ')
nt=$(wc -l < "$W/t_only.txt" | tr -d ' ')
if [ "$na" = 0 ] && [ "$nt" = 0 ]; then
    echo "n1_runtime_check: the anchor's preamble and the tree's are identical -- nothing to distinguish (not a failure)"
    exit 0
fi

printf 'def main()\n    print("n1rt")\n' > "$W/zz_n1rt.zbr"
( cd "$ADIR" && "$ANCHOR" --emit-zig "$W/zz_n1rt.zbr" --output-dir "$W/out" ) > "$W/emit.log" 2>&1
RT="$W/out/zebra_rt.zig"
if [ ! -s "$RT" ]; then
    echo "n1_runtime_check: REFUSING -- the anchor emitted no zebra_rt.zig; cannot tell which runtime it used" >&2
    tail -5 "$W/emit.log" >&2
    exit 2
fi
ahit=0; thit=0
while IFS= read -r l; do grep -qF -- "$l" "$RT" && ahit=$((ahit + 1)); done < "$W/a_only.txt"
while IFS= read -r l; do grep -qF -- "$l" "$RT" && thit=$((thit + 1)); done < "$W/t_only.txt"
if [ "$na" -gt 0 ] && [ "$ahit" = 0 ]; then
    echo "n1_runtime_check: REFUSING -- none of $na anchor-only preamble lines reached the anchor's emit (tree-only lines present: $thit of $nt); it is not emitting against its own runtime" >&2
    exit 2
fi
if [ "$thit" -gt 0 ]; then
    echo "n1_runtime_check: REFUSING -- $thit of $nt TREE-only preamble lines reached the anchor's emit; it is reading the current tree's runtime" >&2
    exit 2
fi
echo "n1_runtime_check: anchor emits its OWN runtime -- anchor-only lines present $ahit/$na, tree-only lines present $thit/$nt"
exit 0
