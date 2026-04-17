#!/usr/bin/env bash
# corpus_snapshot.sh — emit-zig every .zbr in the corpus and record a diff-able result.
#
# Usage:
#   tools/corpus_snapshot.sh [out.tsv]            # snapshot via zig-backend (zebra.exe)
#   tools/corpus_snapshot.sh --selfhost [out.tsv] # snapshot via zebra-selfhost.exe
#   tools/corpus_snapshot.sh --both out.tsv       # both backends side-by-side
#
# Output (TSV, sorted by file):
#   file<TAB>backend<TAB>exit<TAB>content_sha<TAB>stderr_sha
#
# - `exit`         — 0 if --emit-zig succeeded; non-zero otherwise (stderr sha pinpoints failure class)
# - `content_sha`  — sha256 of emitted Zig stdout (first 12 hex chars). "-" if exit != 0.
# - `stderr_sha`   — sha256 of stderr (first 12 hex chars). Lets you cluster failures.
#
# Compare two runs with `diff pre.tsv post.tsv`: any line that changes is a file whose
# backend behaviour shifted. New pass, new fail, or silently altered emit — all caught.
#
# Intentional non-goals:
#   - Does NOT compile the emitted Zig (use bootstrap_check.sh for round-trip).
#   - Does NOT diff per-file emitted content — just hashes. If you need the content,
#     re-emit the file of interest by hand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

BACKEND="zig"
OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --selfhost) BACKEND="selfhost"; shift ;;
        --both)     BACKEND="both"; shift ;;
        --zig)      BACKEND="zig"; shift ;;
        -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
        *)          OUT="$1"; shift ;;
    esac
done

if [[ -z "$OUT" ]]; then
    OUT="/tmp/corpus-$(date +%Y%m%d-%H%M%S).tsv"
fi

ZEBRA="$REPO/zig-out/bin/zebra.exe"
SELFHOST="$REPO/zig-out/bin/zebra-selfhost.exe"

run_backend() {
    local bin="$1" label="$2" file="$3"
    local out_tmp err_tmp rc out_sha err_sha
    out_tmp=$(mktemp) ; err_tmp=$(mktemp)
    set +e
    "$bin" --emit-zig "$file" >"$out_tmp" 2>"$err_tmp"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        out_sha=$(sha256sum "$out_tmp" | cut -c1-12)
    else
        out_sha="-"
    fi
    err_sha=$(sha256sum "$err_tmp" | cut -c1-12)
    printf '%s\t%s\t%d\t%s\t%s\n' "$file" "$label" "$rc" "$out_sha" "$err_sha"
    rm -f "$out_tmp" "$err_tmp"
}

# Corpus = test/*.zbr (top-level only; subdirs are excluded intentionally so a
# wave-scoped sweep keeps runtime bounded).
mapfile -t FILES < <(find test -maxdepth 1 -name '*.zbr' | sort)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "corpus_snapshot: no .zbr files under test/" >&2
    exit 1
fi

echo "# corpus_snapshot backend=$BACKEND files=${#FILES[@]} ts=$(date -Iseconds)" > "$OUT"
echo -e "file\tbackend\texit\tcontent_sha\tstderr_sha" >> "$OUT"

count=0
for f in "${FILES[@]}"; do
    count=$((count+1))
    if [[ "$BACKEND" == "zig" || "$BACKEND" == "both" ]]; then
        run_backend "$ZEBRA" "zig" "$f" >> "$OUT"
    fi
    if [[ "$BACKEND" == "selfhost" || "$BACKEND" == "both" ]]; then
        run_backend "$SELFHOST" "selfhost" "$f" >> "$OUT"
    fi
    # Progress every 25 files.
    if (( count % 25 == 0 )); then
        echo "  ... $count/${#FILES[@]}" >&2
    fi
done

echo "wrote $OUT (${#FILES[@]} files, backend=$BACKEND)" >&2
echo "$OUT"
