#!/usr/bin/env bash
# THE N-1 REFERENCE — resolve (and cache) a compiler built from the anchor tag.
#
#   bash tools/n1_reference.sh            # print the reference compiler's path
#   bash tools/n1_reference.sh --info     # print sha / tag / distance, for a gate's header
#   bash tools/n1_reference.sh --refresh  # discard the cached build and rebuild
#
# WHY. Before criterion 4, `divergence_check` compared the selfhost against the BOOTSTRAP:
# an implementation-vs-implementation question that only made sense while two
# implementations existed. The bootstrap is now frozen, so "can the frozen thing do
# something the advancing thing cannot?" trends permanently to zero -- a gate whose
# assertion becomes vacuous BY DESIGN, which is worse than no gate because the green keeps
# being reported.
#
# Pointing it at the PREVIOUS RELEASE of itself asks a question that stays useful forever:
# does this compiler still handle everything the last anchor handled? A gap is then a
# REGRESSION rather than a lag.
#
# THE CACHE IS KEYED ON THE COMMIT SHA, NEVER THE TAG NAME. A tag can be moved; a stale
# binary served under a moved tag is exactly the config-vs-artifact seam this repo keeps
# finding. Keyed on sha, a moved tag simply misses the cache and rebuilds.
#
# EVERYTHING LIVES OUTSIDE THE REPO. tools/kill_orphans.sh kills compiler processes by
# executable path under $REPO, and doctor --fix clears scratch; a reference build inside
# the repo would be caught by both. It is a sibling directory, like zebra-mutants.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_ROOT="$(cd "$REPO/.." && pwd)/zebra-n1-cache"
WORK_ROOT="$(cd "$REPO/.." && pwd)/zebra-n1-build"
TAG_GLOB='n1-anchor-*'

# TEST HOOK. N1_REF_OVERRIDE names a compiler to use as the reference instead of the
# anchor build. It exists so the gate can be FALSIFIED -- pointing the reference and the
# subject at deliberately different compilers is the only way to watch a "0 regressions"
# gate go red. Not used by any tier.
if [ -n "${N1_REF_OVERRIDE:-}" ]; then
    [ -x "$N1_REF_OVERRIDE" ] || { echo "n1-reference: override is not executable" >&2; exit 2; }
    [ "${1:-}" = "--info" ] && echo "tag=OVERRIDE sha=OVERRIDE distance=? degenerate=no" \
                           || echo "$N1_REF_OVERRIDE"
    exit 0
fi

MODE=path
case "${1:-}" in
    --info)    MODE=info ;;
    --refresh) MODE=refresh ;;
    "")        ;;
    *) echo "n1-reference: unknown argument '$1'" >&2; exit 2 ;;
esac

cd "$REPO" || exit 2

# newest anchor tag by creation date
TAG=$(git tag -l "$TAG_GLOB" --sort=-creatordate | head -1)
if [ -z "$TAG" ]; then
    echo "n1-reference: REFUSING -- no $TAG_GLOB tag exists." >&2
    echo "  Create one:  git tag -a n1-anchor-\$(date +%F) <commit>" >&2
    exit 2
fi

SHA=$(git rev-list -n1 "$TAG" 2>/dev/null)
[ -n "$SHA" ] || { echo "n1-reference: REFUSING -- $TAG does not resolve to a commit" >&2; exit 2; }
SHORT=${SHA:0:12}
HEAD_SHA=$(git rev-parse HEAD)
DIST=$(git rev-list --count "$SHA..HEAD" 2>/dev/null || echo '?')

if [ "$MODE" = info ]; then
    printf 'tag=%s sha=%s distance=%s degenerate=%s\n' \
        "$TAG" "$SHORT" "$DIST" "$([ "$SHA" = "$HEAD_SHA" ] && echo yes || echo no)"
    exit 0
fi

DEST="$CACHE_ROOT/$SHORT"
EXE="$DEST/zebra.exe"

[ "$MODE" = refresh ] && rm -rf "$DEST"

if [ -x "$EXE" ]; then
    echo "$EXE"
    exit 0
fi

# ---- cache miss: build it -------------------------------------------------------------
echo "n1-reference: building the reference compiler from $TAG ($SHORT) -- this is a one-off" >&2
WT="$WORK_ROOT/$SHORT"
rm -rf "$WT"; mkdir -p "$(dirname "$WT")"
# -c core.autocrlf=false: the anchor is materialised with ITS OWN .gitattributes, which
# predate the LF pins (2026-09-12/14), so on a Windows runner (autocrlf=true) its .zig
# files came out CRLF and its build.zig panicked on the preamble markers -- the anchor
# "did not build" for a reason that was never in the anchor. Bytes as committed, always.
if ! git -c core.autocrlf=false worktree add --detach "$WT" "$SHA" >/dev/null 2>&1; then
    echo "n1-reference: REFUSING -- could not create a worktree at $SHORT" >&2
    exit 2
fi

if ! ( cd "$WT" && zig build ) >"$WORK_ROOT/$SHORT.build.log" 2>&1; then
    echo "n1-reference: REFUSING -- the anchor commit does not build:" >&2
    # The CAUSE is above the stack trace; a 12-line tail showed only the trace (2026-09-14).
    grep -m 6 -E 'panic|error:' "$WORK_ROOT/$SHORT.build.log" >&2
    echo "  ..." >&2
    tail -6 "$WORK_ROOT/$SHORT.build.log" >&2
    git worktree remove --force "$WT" >/dev/null 2>&1
    exit 2
fi

# The compiler needs its whole bin/ directory (preamble, gui sections, compiler_rt, vendor),
# not just the .exe -- caching the binary alone produces a reference that cannot emit.
mkdir -p "$DEST"
cp -r "$WT/zig-out/bin/." "$DEST/" 2>/dev/null

git worktree remove --force "$WT" >/dev/null 2>&1
rm -rf "$WT"

if [ ! -x "$EXE" ]; then
    echo "n1-reference: REFUSING -- built, but no zebra.exe landed in the cache" >&2
    exit 2
fi

# PROVE IT RUNS before handing it to a gate. A reference that cannot compile a hello-world
# would make every corpus file look like a regression -- the loudest possible false alarm.
probe="$DEST/.probe.zbr"; printf 'def main()\n    print("n1 ok")\n' > "$probe"
rm -rf "$DEST/.probe"
if ! "$EXE" --output-dir "$DEST/.probe" "$probe" >/dev/null 2>&1 \
   || ! find "$DEST/.probe" -name '*.exe' 2>/dev/null | head -1 | grep -q .; then
    echo "n1-reference: REFUSING -- the reference compiler cannot build a hello-world" >&2
    rm -rf "$DEST"
    exit 2
fi
rm -rf "$DEST/.probe" "$probe"

echo "$EXE"
