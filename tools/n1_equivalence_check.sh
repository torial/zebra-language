#!/usr/bin/env bash
# EXIT CRITERION 1 FOR THE BOOTSTRAP SUNSET: can the SELFHOST replace the BOOTSTRAP as the
# regeneration authority?
#
#   bash tools/n1_equivalence_check.sh
#
# THE QUESTION. `selfhost/*.zig` are generated from `selfhost/*.zbr` by zebra-bootstrap.exe,
# which is the only remaining job that keeps a second compiler implementation alive. Moving
# to N-1 bootstrapping (stage-0 = a compiler we did not just build, the way GCC/Rust/Go do
# it) means having zebra.exe do that emission instead. This asks whether it CAN: does the
# selfhost emit its own modules byte-identically to what the bootstrap emits?
#
# A clean run does not by itself authorise the switch -- it retires the first of four exit
# criteria in NEXT_STEPS. The GUI backends still delegate to the bootstrap, which is the
# harder blocker.
#
# WHY BYTE-IDENTICAL AND NOT "BOTH COMPILE". Two emissions can each be valid Zig and differ
# in what they mean -- that is BUG-226's whole class, invisible to every compile-only gate.
# A byte comparison has no such blind spot for this question, because the artifact under
# test IS the file that gets committed.
#
# CONTROLS, because "0 differences" is exactly what a broken harness prints:
#   - a POSITIVE control: the two compilers must actually have been RUN and produced output
#     of plausible size, or a pair of empty directories compares equal.
#   - a NEGATIVE control: one file is deliberately perturbed and must be REPORTED, so a
#     comparison that has stopped comparing cannot pass.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$REPO/zig-out/bin/zebra.exe"
BOOT="$REPO/zig-out/bin/zebra-bootstrap.exe"
OUT="${TMPDIR:-/tmp}/n1eq"
MIN_BYTES=2000

for exe in "$SELF" "$BOOT"; do
    [ -x "$exe" ] || { echo "n1-equivalence: REFUSING -- not built: $exe" >&2; exit 2; }
done

rm -rf "$OUT"; mkdir -p "$OUT/self" "$OUT/boot" "$OUT/src"

mods=$(cd "$REPO" && ls selfhost/*.zbr 2>/dev/null)
n=$(echo "$mods" | grep -c .)
if [ "$n" -lt 15 ]; then
    echo "n1-equivalence: REFUSING -- found only $n module(s); the glob has stopped matching" >&2
    exit 2
fi

echo "── N-1 equivalence: $n selfhost module(s), selfhost emit vs bootstrap emit ──"

emitted=0
# THE TWO COMPILERS DO NOT TAKE THE SAME FLAGS, and assuming they did made the first run
# of this script useless in a way that ALMOST read as success. `--output-dir` is
# selfhost-only; the bootstrap answers `unknown flag '--output-dir'` and emits nothing, so
# the comparison scored "0 differing" -- which is what a PASS looks like -- with 22 missing
# files carrying the entire truth. The `missing` leg is the only reason it failed. CLAUDE.md
# already records this ("it takes --emit-zig, not --output-dir"); it was not read closely
# enough.
#
# So the bootstrap gets --emit-zig, which writes BESIDE THE SOURCE. That would pollute
# selfhost/ with files git already tracks, so its input is a COPY in scratch and the emit is
# collected from there. A run that wrote into selfhost/ would look like a successful
# regeneration and leave the tree modified.
cp "$REPO"/selfhost/*.zbr "$OUT/src/" 2>/dev/null

for m in $mods; do
    base="$(basename "$m" .zbr)"
    "$SELF" --output-dir "$OUT/self/$base" "$REPO/$m" > "$OUT/self/$base.log" 2>&1
    ( cd "$OUT/src" && "$BOOT" --emit-zig "$base.zbr" ) > "$OUT/boot/$base.log" 2>&1
    mkdir -p "$OUT/boot/$base"
    [ -f "$OUT/src/$base.zig" ] && mv "$OUT/src/$base.zig" "$OUT/boot/$base/$base.zig"
    [ -f "$OUT/self/$base/$base.zig" ] && emitted=$((emitted + 1))
done

# POSITIVE CONTROL: emissions must exist and be of plausible size. Two empty trees compare
# equal, and that is the reassuring-wrong answer this check must not be able to give.
total=$(find "$OUT/self" -name '*.zig' -type f 2>/dev/null | wc -l | tr -d ' ')
bytes=$(find "$OUT/self" -name '*.zig' -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
if [ "$total" -lt 10 ] || [ "$bytes" -lt "$MIN_BYTES" ]; then
    echo "n1-equivalence: REFUSING -- the selfhost produced $total file(s) / $bytes byte(s)."
    echo "  Nothing was emitted, so a clean comparison would mean nothing." >&2
    exit 2
fi
echo "  emitted: $total file(s) from the selfhost, $bytes bytes"

same=0; diff_n=0; missing=0
DIFFS=""
for m in $mods; do
    base="$(basename "$m" .zbr)"
    a="$OUT/self/$base/$base.zig"
    b="$OUT/boot/$base/$base.zig"
    if [ ! -f "$a" ] || [ ! -f "$b" ]; then
        missing=$((missing + 1))
        DIFFS="$DIFFS\n  MISSING  $base  (self=$([ -f "$a" ] && echo y || echo n) boot=$([ -f "$b" ] && echo y || echo n))"
        continue
    fi
    if cmp -s "$a" "$b"; then
        same=$((same + 1))
    else
        diff_n=$((diff_n + 1))
        nl=$(diff "$a" "$b" 2>/dev/null | grep -c '^[<>]')
        DIFFS="$DIFFS\n  DIFFERS  $base  ($nl changed line(s))"
    fi
done

# NEGATIVE CONTROL: perturb one file and require the comparison to notice.
probe="$(echo "$mods" | head -1 | xargs basename | sed 's/\.zbr$//')"
if [ -f "$OUT/self/$probe/$probe.zig" ]; then
    echo "// n1 negative control" >> "$OUT/self/$probe/$probe.zig"
    if cmp -s "$OUT/self/$probe/$probe.zig" "$OUT/boot/$probe/$probe.zig"; then
        echo "n1-equivalence: REFUSING -- the negative control did NOT fire: a deliberately"
        echo "  perturbed file still compared equal, so this comparison is not comparing." >&2
        exit 2
    fi
    echo "  negative control fired (a perturbed file is detected)"
fi

echo "  identical: $same    differing: $diff_n    missing: $missing"
[ -n "$DIFFS" ] && printf '%b\n' "$DIFFS"

if [ "$diff_n" -eq 0 ] && [ "$missing" -eq 0 ]; then
    echo "n1-equivalence: PASS -- the selfhost emits its own modules byte-identically to the"
    echo "  bootstrap. Exit criterion 1 of 4 is met; the GUI delegation is the harder one."
    exit 0
fi
echo "n1-equivalence: $diff_n differing, $missing missing -- each is a real divergence to"
echo "  resolve before the regen authority can move. Emissions kept in $OUT for diffing."
exit 1
