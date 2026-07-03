#!/usr/bin/env bash
# §28b enforcement gate (steps 2-3 landed the sweep; this removes the
# silent-regression trap). Fails if ANY throws call in the corpus relies on
# the compiler's legacy auto-`try` instead of an explicit `?`. The corpus was
# fully swept 2026-07-02 (441 sites); this keeps it that way — new code that
# omits `?` breaks the gate instead of silently compiling.
#
# INCREMENTAL by default (fast): only re-checks .zbr files modified since the
# last clean run (mtime vs a stamp in zig-out/, gitignored). The gate's
# verdict depends on BOTH the .zbr source AND the compiler's auto-`try` logic,
# so a full re-scan is forced whenever the compiler binary is newer than the
# stamp (a rebuild can flip a previously-clean file). `--full` forces a
# complete scan (use for pre-release / CI certainty).
#
# Residual gap (accepted): a .zbr whose content changed WITHOUT its mtime
# advancing (mtime manipulation, some archive extractions) would be skipped
# until the next full scan. Normal edit/build/git workflows advance mtimes,
# so this is close to fully reliable in practice; `--full` closes it entirely.
#
# The language-level flip (implicit-try → compile error for EXTERNAL code too,
# via a driver-level diagnostic — NOT @compileError-into-emit, because 4 of
# the 5 auto-try sites are expression-position) is the remaining piece; see
# NEXT_STEPS §28b step 5. Until it lands, this gate protects the repo.
#
# Usage: bash tools/check_explicit_try.sh [--full]   (run from repo root)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BOOT="zig-out/bin/zebra-bootstrap.exe"
STAMP="zig-out/.explicit_try_stamp"
[[ -x "$BOOT" ]] || { echo "check_explicit_try: $BOOT not built (run 'zig build')" >&2; exit 2; }

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

# A stamp with mtime = scan start, promoted to $STAMP only on success, so a
# file modified DURING the scan is still 'newer' next run (no missed edits).
NEWSTAMP="$(mktemp)"
WARN="$(mktemp)"
trap 'rm -f "$NEWSTAMP" "$WARN"' EXIT

# Decide scan set. Full when: forced, first run (no stamp), or the compiler
# changed since the last clean run (binary newer than stamp).
if [[ $FULL -eq 1 || ! -f "$STAMP" || "$BOOT" -nt "$STAMP" ]]; then
    mode="full"
    mapfile -t FILES < <(find selfhost test examples -maxdepth 1 -name '*.zbr' 2>/dev/null)
else
    mode="incremental"
    mapfile -t FILES < <(find selfhost test examples -maxdepth 1 -name '*.zbr' -newer "$STAMP" 2>/dev/null)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    mv -f "$NEWSTAMP" "$STAMP"   # nothing changed — advance stamp, stay fast
    echo "explicit-try gate: nothing changed since last clean run ($mode)"
    exit 0
fi

for f in "${FILES[@]}"; do
    [[ -e "$f" ]] || continue
    "$BOOT" --warn-implicit-try --emit-zig "$f" >/dev/null 2>>"$WARN" || true
done

N="$(grep -c '^IMPLICIT_TRY' "$WARN" || true)"
if [[ "$N" -ne 0 ]]; then
    # Do NOT advance the stamp: every changed file stays in scope until clean.
    echo "FAIL: $N implicit-try site(s) — every throws call needs an explicit '?' (§28b):" >&2
    grep '^IMPLICIT_TRY' "$WARN" | sed 's/^IMPLICIT_TRY: /  /' >&2
    exit 1
fi

mv -f "$NEWSTAMP" "$STAMP"
echo "explicit-try gate: 0 implicit-try sites ($mode, ${#FILES[@]} file(s) checked)"
