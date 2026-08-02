#!/usr/bin/env bash
# corpus_ls.sh — list the corpus files a gate should measure: the TRACKED ones.
#
# WHY THIS EXISTS
# ---------------
# Every heavy gate used to enumerate its corpus with a filesystem glob:
#
#     ls "$REPO"/test/*.zbr
#
# which means a gate's result depends on whatever untracked files happen to be sitting in
# the directory. Observed 2026-08-01: `examples/zz_red_main.zbr`, someone's scratch probe,
# untracked, in a directory `full_sweep --examples --gate` sweeps. Nobody reading the
# commit could see it, and nobody re-running the gate elsewhere would reproduce the
# result.
#
# The worst instance is not a sweep, though. `bug_fixture_check.py` counts `test/bug*.zbr`
# to decide whether a reported bug has a regression fixture — so an untracked file could
# make that gate **PASS**, by appearing to supply a fixture that does not exist for anyone
# else. A gate that a stray local file can turn green is the exact failure this repo spent
# 2026-07/08 learning to distrust (docs/testing_strategy.md 3b).
#
# Tracked, not committed: `git ls-files` reads the INDEX, so a `git add`ed file counts.
# That is the right line — staging is the point at which a file stops being scratch and
# starts being something you are asking others to have.
#
#   bash tools/corpus_ls.sh test              # tracked test/*.zbr        (one level)
#   bash tools/corpus_ls.sh test examples     # both, in order
#   bash tools/corpus_ls.sh --abs test        # absolute paths
#   bash tools/corpus_ls.sh --ext zig test    # a different extension
#
# Paths are repo-relative and sorted. Exit 2 if this is not a git worktree -- a gate must
# NOT silently fall back to globbing, because that reintroduces the bug it was given this
# tool to avoid.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

ABS=0
EXT="zbr"
DIRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --abs) ABS=1 ;;
        --ext) EXT="$2"; shift ;;
        -*) echo "corpus_ls: unknown option '$1'" >&2; exit 2 ;;
        *) DIRS+=("$1") ;;
    esac
    shift
done
[[ ${#DIRS[@]} -eq 0 ]] && { echo "usage: corpus_ls.sh [--abs] [--ext EXT] DIR..." >&2; exit 2; }

if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "corpus_ls: $REPO is not a git worktree, so 'tracked' has no meaning here." >&2
    echo "  Refusing to fall back to a filesystem glob: that is the behaviour this tool" >&2
    echo "  exists to remove, and a gate silently reverting to it would be invisible." >&2
    exit 2
fi

for d in "${DIRS[@]}"; do
    d="${d%/}"
    # `git ls-files -- test/*.zbr` would ALSO match test/boundary/*.zbr, because git
    # pathspec globs across '/' by default. Filter explicitly for one level instead of
    # relying on a pathspec subtlety that a reader has to know.
    git -C "$REPO" ls-files -- "$d" \
      | grep -E "^${d}/[^/]+\.${EXT}$" \
      | while read -r p; do
            # A tracked-but-deleted file is still listed; a gate cannot measure it.
            [[ -f "$REPO/$p" ]] || continue
            if [[ $ABS -eq 1 ]]; then echo "$REPO/$p"; else echo "$p"; fi
        done
done | sort -u
