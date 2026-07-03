#!/usr/bin/env bash
# §28b enforcement gate (steps 2-3 landed the sweep; this removes the
# silent-regression trap). Fails if ANY throws call in the corpus relies on
# the compiler's legacy auto-`try` instead of an explicit `?`. The corpus was
# fully swept 2026-07-02 (441 sites); this keeps it that way — new code that
# omits `?` breaks the gate instead of silently compiling.
#
# This is the durable half of the migration. The language-level flip (making
# implicit-try a compile error for EXTERNAL code too, via a driver-level
# diagnostic — NOT @compileError-into-emit, because 4 of the 5 auto-try sites
# are expression-position) is the remaining piece; see NEXT_STEPS §28b step 5.
# Until it lands, this gate protects the zebra-language repo.
#
# Usage: bash tools/check_explicit_try.sh   (run from repo root)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BOOT="zig-out/bin/zebra-bootstrap.exe"
[[ -x "$BOOT" ]] || { echo "check_explicit_try: $BOOT not built (run 'zig build')" >&2; exit 2; }

WARN="$(mktemp)"
trap 'rm -f "$WARN"' EXIT
for f in selfhost/*.zbr test/*.zbr examples/*.zbr; do
    [[ -e "$f" ]] || continue
    "$BOOT" --warn-implicit-try --emit-zig "$f" >/dev/null 2>>"$WARN" || true
done

N="$(grep -c '^IMPLICIT_TRY' "$WARN" || true)"
if [[ "$N" -ne 0 ]]; then
    echo "FAIL: $N implicit-try site(s) — every throws call needs an explicit '?' (§28b):" >&2
    grep '^IMPLICIT_TRY' "$WARN" | sed 's/^IMPLICIT_TRY: /  /' >&2
    exit 1
fi
echo "explicit-try gate: 0 implicit-try sites (corpus fully explicit-'?')"
