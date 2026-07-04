#!/usr/bin/env bash
# §28a enforcement gate (step 3). Fails if ANY type-dispatch site in the corpus
# falls through to a GUESS because the TypeChecker couldn't supply the operand /
# receiver type — the F7/BUG-162/BUG-168 class. The measure-first sweep
# (2026-07-03) found only 10 such sites, all TC under-inference (not genuine
# ambiguity), and closed every one; the corpus is now at 0. This keeps it that
# way: new code that dispatches on an un-inferred type breaks the gate instead
# of silently emitting a guess Zig may reject (or, worse, accept wrongly).
#
# Guess sites instrumented by --warn-inference-guess (see src/CodeGen.zig):
#   add          numeric `+` emitted without proving both operands numeric
#   len_count    unknown receiver → `.items.len` ArrayList fallback
#   list_dispatch unknown receiver + List-shaped method name → assume List
#
# INCREMENTAL by default (fast): only re-checks .zbr files modified since the
# last clean run (mtime vs a stamp in zig-out/, gitignored). The verdict depends
# on BOTH the .zbr source AND the compiler's inference, so a full re-scan is
# forced whenever the compiler binary is newer than the stamp (a rebuild can
# flip a previously-clean file). `--full` forces a complete scan (pre-release/CI).
#
# The language-level flip (a guess becomes a Zebra-level "cannot infer type of
# X; annotate" compile error, in BOTH compilers) is the remaining piece; see
# NEXT_STEPS §28a. Until it lands, this gate protects the repo.
#
# Usage: bash tools/check_inference_guess.sh [--full]   (run from repo root)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BOOT="zig-out/bin/zebra-bootstrap.exe"
STAMP="zig-out/.inference_guess_stamp"
[[ -x "$BOOT" ]] || { echo "check_inference_guess: $BOOT not built (run 'zig build')" >&2; exit 2; }

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
    echo "inference-guess gate: nothing changed since last clean run ($mode)"
    exit 0
fi

for f in "${FILES[@]}"; do
    [[ -e "$f" ]] || continue
    "$BOOT" --warn-inference-guess --emit-zig "$f" >/dev/null 2>>"$WARN" || true
done

N="$(grep -c '^INFER_GUESS' "$WARN" || true)"
if [[ "$N" -ne 0 ]]; then
    # Do NOT advance the stamp: every changed file stays in scope until clean.
    echo "FAIL: $N inference-guess site(s) — a typed dispatch guessed on an un-inferred type (§28a):" >&2
    grep '^INFER_GUESS' "$WARN" | sed 's/^INFER_GUESS: /  /' >&2
    exit 1
fi

mv -f "$NEWSTAMP" "$STAMP"
echo "inference-guess gate: 0 guess sites ($mode, ${#FILES[@]} file(s) checked)"
