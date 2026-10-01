#!/usr/bin/env bash
# BUG-501 measure (docs/design/container_reference_semantics.md §5) -- NOT a gate.
#
# Counts, per kind, every site where a container (List / HashMap / Set / StringBuilder) is
# copied out of a live location: the sites whose MEANING changes when containers become
# references. Drives `zebra --warn-container-copy --emit-zig` over .zbr files.
#
# Kinds: bind_alias / bind_field / bind_call (var or `=` from an ident / member / call),
# return_alias / return_field / return_call, store (a container argument to set/add/put/
# append/insert), ctor_arg (a container argument to a struct constructor), struct_copy (a
# struct holding a container, copied), except (an `except` on such a struct).
# OVER-REPORTS `*_call` (a call building a fresh container is counted with one handing out
# a field); does not see a store nested inside a larger expression.
#
# POSITIVE CONTROL FIRST: tools/fixtures/container_copy_control.zbr contains each kind
# exactly once. If any kind does not fire there, this REFUSES (exit 2) rather than report
# a count -- a measure that stopped seeing would otherwise print a reassuring zero.
#
# Usage: bash tools/measure_container_copy.sh [DIR_OR_FILE ...]
#        (default: selfhost test examples). Run from the repo root.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ZEB="zig-out/bin/zebra.exe"; [[ -x "$ZEB" ]] || ZEB="zig-out/bin/zebra"
[[ -x "$ZEB" ]] || { echo "measure_container_copy: $ZEB not built" >&2; exit 2; }
KINDS="bind_alias bind_field bind_call return_alias return_field return_call store ctor_arg struct_copy except"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- the control ----
"$ZEB" --warn-container-copy --emit-zig --output-dir "$TMP/ctl" tools/fixtures/container_copy_control.zbr \
    >/dev/null 2>"$TMP/ctl.err"
for k in $KINDS; do
    n=$(grep -c "^CONTAINER_COPY: $k:" "$TMP/ctl.err")
    if [[ "$n" != "1" ]]; then
        echo "measure_container_copy: REFUSING -- control kind '$k' fired $n time(s), expected 1" >&2
        grep -v "parsed OK\|resolved OK\|parsing\|compiling" "$TMP/ctl.err" | head -20 >&2
        exit 2
    fi
done
echo "control: all 10 kinds fired once" >&2

# ---- the measure ----
TARGETS=("$@")
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(selfhost test examples)
mapfile -t FILES < <(for t in "${TARGETS[@]}"; do
    if [[ -d "$t" ]]; then find "$t" -maxdepth 1 -name '*.zbr'; else echo "$t"; fi
done | sort -u)
echo "measuring ${#FILES[@]} file(s) ..." >&2
: > "$TMP/all"
: > "$TMP/refused"
i=0
for f in "${FILES[@]}"; do
    timeout 120 "$ZEB" --warn-container-copy --allow-inference-guess --emit-zig --output-dir "$TMP/o" "$f" \
        >/dev/null 2>"$TMP/one.err"
    rc=$?
    grep "^CONTAINER_COPY:" "$TMP/one.err" >> "$TMP/all"
    # A file the front end refuses reports nothing -- count it, so a refusal never reads as zero.
    [[ $rc -ne 0 ]] && ! grep -q "^CONTAINER_COPY:" "$TMP/one.err" && echo "$f (rc=$rc)" >> "$TMP/refused"
    i=$((i+1)); (( i % 100 == 0 )) && echo "  ...$i/${#FILES[@]}" >&2
done
sort -u "$TMP/all" > "$TMP/uniq"

echo "=================== CONTAINER COPY SITES ==================="
for k in $KINDS; do printf '  %-13s %s\n' "$k" "$(grep -c "^CONTAINER_COPY: $k:" "$TMP/uniq")"; done
printf '  %-13s %s\n' "TOTAL" "$(wc -l < "$TMP/uniq" | tr -d ' ')"
echo "--- by file (top 25) ---"
sed -E 's/^CONTAINER_COPY: [a-z_]+: (.*):[0-9]+:[0-9]+$/\1/' "$TMP/uniq" | sort | uniq -c | sort -rn | head -25
echo "--- files with no report because the compile failed: $(wc -l < "$TMP/refused" | tr -d ' ') ---"
head -20 "$TMP/refused"
echo "--- full site list ---"
cat "$TMP/uniq"
