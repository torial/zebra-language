#!/usr/bin/env bash
# §28a step-1/2 (selfhost measure). Runs the SELFHOST compiler (zig-out/bin/zebra.exe,
# built with the --warn-inference-guess instrumentation) over the corpus and counts
# INFER_GUESS sites by bucket. The selfhost counterpart to tools/check_inference_guess.sh
# (which drives the BOOTSTRAP and is an enforcing gate at 0). This is a MEASURE tool,
# not a gate — the selfhost's local inferExpr-based proven-checks are weaker than the
# bootstrap's global TC expr-type map, so a nonzero count here is under-inference to
# close (step 2), NOT a regression to block on. Drive the count toward 0 as inference
# is strengthened; flip only once it reaches ~0. See NEXT_STEPS §28a.
#
# Three instrumented sites (selfhost/CodeGen.zbr), each mirroring a bootstrap guess:
#   add           numeric `+` emitted without proving both operands prim
#   len_count     `.len` fallback on a receiver not proven str/list/hashmap
#   list_dispatch unknown receiver + List-shaped method name → name-based List routing
#
# NOTE: the count OVER-reports — it also flags user-class field/method access on an
# un-inferred receiver (e.g. `StrSet.len` field read, `args.contains()` on Arg). Those
# emit correctly; distinguishing them from genuine ambiguity requires the step-2
# inference fixes, which is the point of the measure.
#
# Per-file timeout: selfhost/main.zbr and pipeline_test.zbr currently do NOT self-compile
# (pre-existing; see BUG-181) — the timeout skips them rather than hanging the sweep.
#
# Usage: bash tools/measure_selfhost_guess.sh [--per-file-timeout SECONDS]  (from repo root)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ZEB="zig-out/bin/zebra.exe"
TIMEOUT=60
[[ "${1:-}" == "--per-file-timeout" ]] && TIMEOUT="${2:-60}"
[[ -x "$ZEB" ]] || { echo "measure: $ZEB not built (run 'zig build')" >&2; exit 2; }

TMP="$(mktemp -d)"
WARN="$(mktemp)"
SKIPPED="$(mktemp)"
trap 'rm -rf "$TMP" "$WARN" "$SKIPPED"' EXIT

mapfile -t FILES < <(find selfhost test examples -maxdepth 1 -name '*.zbr' 2>/dev/null | sort)
echo "measuring ${#FILES[@]} corpus files (per-file timeout ${TIMEOUT}s) ..." >&2

i=0
for f in "${FILES[@]}"; do
    [[ -e "$f" ]] || continue
    timeout "$TIMEOUT" "$ZEB" --warn-inference-guess --output-dir "$TMP" "$f" >/dev/null 2>>"$WARN"
    [[ $? -eq 124 ]] && echo "$f" >> "$SKIPPED"
    i=$((i+1))
    (( i % 50 == 0 )) && echo "  ...$i/${#FILES[@]}" >&2
done

echo "=================== RESULTS ==================="
echo "total INFER_GUESS lines (inflated by dep re-compiles): $(grep -c '^INFER_GUESS' "$WARN" || true)"
echo "--- unique sites per bucket ---"
for b in add len_count list_dispatch; do
    printf '  %-14s %s\n' "$b" "$(grep "^INFER_GUESS: $b:" "$WARN" | sort -u | wc -l)"
done
echo "  -------------- --"
printf '  %-14s %s\n' "TOTAL unique" "$(grep '^INFER_GUESS' "$WARN" | sort -u | wc -l)"
echo "--- unique sites by file ---"
grep '^INFER_GUESS' "$WARN" | sed -E 's/^INFER_GUESS: [a-z_]+: ([^:]+):.*/\1/' | sort | uniq -c | sort -rn
if [[ -s "$SKIPPED" ]]; then
    echo "--- SKIPPED (timeout ${TIMEOUT}s — did not self-compile; see BUG-181) ---"
    sed 's/^/  /' "$SKIPPED"
fi
echo "--- full unique site list ---"
grep '^INFER_GUESS' "$WARN" | sort -u
