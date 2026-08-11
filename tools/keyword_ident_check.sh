#!/usr/bin/env bash
# keyword_ident_check.sh — THE ESCAPED-IDENTIFIER GATE (BUG-280).
#
# Zebra lets you name things with words that are keywords in ZIG but not in Zebra:
# align, volatile, opaque, packed, noalias, anyframe, threadlocal, linksection,
# addrspace, allowzero, callconv, comptime, nosuspend, suspend, resume, await,
# async, usingnamespace. Codegen must escape those on the way out as @"name".
#
# `emitName` has always done that correctly. The FIELD paths never called it — so a
# class with `var align: int` emitted `align: i64 = 0,` and the generated Zig did not
# parse. Nine distinct emit sites were involved (declaration in three class-emit paths,
# static declaration, the synthesised constructor parameter, the struct-literal
# designator, the `except` temp-copy assignment, member access, qualified access), and
# a reading of the source found four of them. The other five came from emitting a probe
# and grepping the output, which is what this gate automates.
#
# HOW IT DECIDES. It emits the fixture and looks for the keyword appearing BARE in the
# generated Zig. String contents are stripped first, which does two jobs at once:
#
#   @"align"                  -> @""            escaped, correctly ignored
#   &.{"align"}               -> &.{""}         a REFLECTION string, must stay bare —
#                                               it is data, not an identifier, and
#                                               escaping it would silently corrupt
#                                               field lookup. Correctly ignored.
#   align: i64 = 0,           -> unchanged      THE BUG. Flagged.
#
# So the rule is "a keyword outside a string literal is an unescaped identifier", and
# it needs no allow-list of legitimate exceptions — which is the point, because an
# allow-list here would be the same hand-maintained oracle that caused the bug.
#
# CANNOT SEE: a keyword emitted into a position this fixture does not exercise. The
# fixture is the coverage, so extend it when a new emit path appears.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

FIXTURE="tools/fixtures/bug280_keyword_idents.zbr"
OUT="$(mktemp -d -t kwident-XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

COMPILER="${1:-./zig-out/bin/zebra.exe}"
[[ -x "$COMPILER" ]] || { echo "keyword-ident: REFUSING — no compiler at $COMPILER" >&2; exit 2; }

# The words the fixture actually uses. Kept in step with the fixture, not with Zig.
WORDS=(align volatile opaque packed noalias anyframe)

emit() {
    "$COMPILER" --output-dir "$OUT" "$FIXTURE" >"$OUT/emit.log" 2>&1
}

# The Zig build is EXPECTED to fail while the bug is live — bare keywords are why.
# So emit first and diagnose the .zig regardless; the build result is reported at the
# end as a separate fact. A gate that stopped at "does not compile" would hide which
# sites caused it, which is the only information anyone actually needs here.
emit; BUILD_RC=$?

ZIG="$OUT/$(basename "${FIXTURE%.zbr}").zig"
if [[ ! -f "$ZIG" ]]; then
    echo "keyword-ident: REFUSING — the compiler produced no .zig at all, so this gate" >&2
    echo "               has nothing to inspect. That is a front-end failure, not an" >&2
    echo "               escaping failure:" >&2
    grep -oE "error: .*" "$OUT/emit.log" | head -3 | sed 's/^/                 /' >&2
    exit 2
fi

# Strip string-literal CONTENTS, then look for the keyword as a whole word.
STRIPPED="$OUT/stripped.zig"
sed 's/"[^"]*"/""/g' "$ZIG" > "$STRIPPED"

# Positive control: the fixture must actually contain these names somewhere, or the
# scan is looking at the wrong file and would report clean for the wrong reason.
if ! grep -q 'align' "$ZIG"; then
    echo "keyword-ident: REFUSING — 'align' does not appear in the emitted Zig at all;" >&2
    echo "               the fixture or the output path is wrong, not the compiler." >&2
    exit 2
fi
# Negative control: a word that is a keyword in neither language must never be flagged.
if grep -qwE 'definitelynotakeyword' "$STRIPPED"; then
    echo "keyword-ident: REFUSING — negative control matched." >&2
    exit 2
fi

bad=0
for w in "${WORDS[@]}"; do
    hits=$(grep -nwE "$w" "$STRIPPED" || true)
    if [[ -n "$hits" ]]; then
        [[ $bad -eq 0 ]] && echo "keyword-ident: FAIL — Zig keywords emitted as bare identifiers:"
        echo "$hits" | sed "s/^/    [$w] /" | head -6
        bad=$((bad + 1))
    fi
done

if [[ $bad -gt 0 ]]; then
    echo "    (a bare keyword outside a string literal is an unescaped identifier;"
    echo "     route that emit site through emitName / zigSafeName)"
    exit 1
fi

# Clean escaping but a failed build is a DIFFERENT defect, and must not be reported as
# a pass — the fixture is supposed to run.
if [[ $BUILD_RC -ne 0 ]]; then
    echo "keyword-ident: FAIL — every keyword is escaped, but the fixture still does not"
    echo "               build. That is a separate defect, not an escaping one:"
    grep -oE "error: .*" "$OUT/emit.log" | head -3 | sed 's/^/                 /'
    exit 1
fi

echo "              NOT checked: emit paths the fixture does not exercise, and whether"
echo "              the reflection strings are otherwise correct — only that they stay bare."
echo "keyword-ident: ${#WORDS[@]}/${#WORDS[@]} keywords escaped in every position the fixture reaches"
