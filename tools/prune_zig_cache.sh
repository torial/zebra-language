#!/usr/bin/env bash
# prune_zig_cache.sh -- delete Zig cache entries not modified for N days.
#
# WHY: Zig never evicts anything from a project cache. Every gate run compiles hundreds
# of freshly EMITTED .zig files (a compiler change moves most of them), and each leaves its
# ZIR (`z/`) and build products (`o/`) behind for good. On 2026-10-09 this repo's
# .zig-cache was 48 GB (`z/` alone 49,968 entries) and the GameEngine's 67 GB, with the
# disk at 60 GB free -- about 200 GB lost in a few weeks.
#
# SAFE BECAUSE IT IS A CACHE: a deleted entry is a miss, and a miss rebuilds. The only
# cost of pruning too much is a slower next build. Age is the MODIFICATION time (Windows
# access times are not reliable), so an entry created long ago and reused daily can be
# pruned and rebuilt once -- that is the price of not tracking use, and it is small.
#
# ONLY ZIG'S OWN ENTRIES (o/ z/ h/ tmp/). The gate caches beside them (zbr-verdicts/,
# zbr-outputs/, ...) have their own keys and are left alone.
#
#   bash tools/prune_zig_cache.sh <cache-dir> [--days N] [--dry-run]
#
# The directory is REQUIRED -- never taken from where the command is run -- and it must
# look like a Zig cache, or nothing happens. Prints what it removed and how much, zero
# included. Exit 2 on a refusal, 0 otherwise.
set -u

DIR=""
DAYS=7
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --days)    DAYS="${2:?--days needs a number}"; shift ;;
        --days=*)  DAYS="${1#--days=}" ;;
        --dry-run) DRY=1 ;;
        -*)        echo "prune_zig_cache: unknown argument '$1'" >&2; exit 2 ;;
        *)         DIR="$1" ;;
    esac
    shift
done
if [ -z "$DIR" ]; then
    echo "prune_zig_cache: name the cache directory (e.g. .zig-cache); it is never assumed" >&2
    exit 2
fi
case "$DAYS" in ''|*[!0-9]*) echo "prune_zig_cache: --days must be a whole number, got '$DAYS'" >&2; exit 2 ;; esac
if [ ! -d "$DIR" ]; then
    echo "prune_zig_cache: '$DIR' is not a directory" >&2
    exit 2
fi
if [ ! -d "$DIR/o" ] && [ ! -d "$DIR/z" ] && [ ! -d "$DIR/h" ]; then
    echo "prune_zig_cache: '$DIR' has none of o/ z/ h/ -- it does not look like a Zig cache; refusing" >&2
    exit 2
fi

before_kb=$(du -sk "$DIR" 2>/dev/null | cut -f1)
removed=0
for sub in o z h tmp; do
    [ -d "$DIR/$sub" ] || continue
    # Top-level entries only: an o/<hash>/ directory is one build product.
    while IFS= read -r -d '' entry; do
        if [ $DRY -eq 1 ]; then
            echo "  would remove $entry"
        else
            rm -rf -- "$entry"
        fi
        removed=$((removed + 1))
    done < <(find "$DIR/$sub" -mindepth 1 -maxdepth 1 -mtime +"$DAYS" -print0 2>/dev/null)
done
after_kb=$(du -sk "$DIR" 2>/dev/null | cut -f1)
freed_mb=$(( (before_kb - after_kb) / 1024 ))
if [ $DRY -eq 1 ]; then
    echo "prune_zig_cache: $DIR -- $removed entr(y/ies) older than $DAYS days WOULD be removed (dry run; nothing changed)"
else
    echo "prune_zig_cache: $DIR -- removed $removed entr(y/ies) older than $DAYS days, freed ${freed_mb} MB ($((after_kb / 1024)) MB left)"
fi
