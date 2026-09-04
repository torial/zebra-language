#!/usr/bin/env bash
# debug_map_check.sh — THE DEBUG SOURCE-MAP GATE (`debug-map`).
#
# `zebra debug` is a DAP relay: it sits between an IDE and lldb-dap and rewrites
# every source coordinate that crosses it, because the debugger knows only the
# GENERATED .zig while the user is looking at their .zbr. The translation is
# driven by the `// zbr:<file>:<line>` provenance comments codegen stamps into
# the emitted Zig.
#
# WHAT MAKES THIS GATE NECESSARY: a relay that forwards bytes UNCHANGED still
# attaches, still initializes, still reports a live session. The only symptom of
# a broken map is breakpoints landing on the wrong lines — so "we connected and
# got `initialized`" passes just as well against the transform deleted entirely.
# Connectivity is not the property; the MAPPING is.
#
# It needs NO lldb-dap and NO debug session. `zebra debug --dump-map` reports the
# map computed by the SHIPPING lookups, so the property is checkable directly.
#
# THE ROUND-TRIP LEG ALONE WOULD NOT BE ENOUGH, and that is why leg 2 exists: two
# lookups broken in compensating ways agree with each other perfectly. Leg 2's
# oracle comes from OUTSIDE the map — the fixture's own print statements name the
# line they sit on, so the expected line numbers are derived from the source text
# rather than from anything the compiler said.
#
# Legs 3-5 feed HANDWRITTEN .zig to the parser, so they test it with no compiler
# in the loop at all, and each one can fail: a Windows drive path must not split
# at the drive colon, a malformed marker must be SKIPPED rather than defaulted to
# a line number (a fabricated coordinate sends a debugger somewhere confidently
# wrong), and a file with no markers must report zero — which proves the count is
# a measurement and not a constant.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
FIXTURE="test/bug329_print_sourcemap_test.zbr"
W="$(mktemp -d "${TMPDIR:-/tmp}/zbr_dbgmap.XXXXXX")"
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
die()  { printf 'debug-map: REFUSING to report — %s\n' "$1"; exit 2; }

[ -x "$ZEBRA" ] || die "zebra.exe not built"
[ -f "$FIXTURE" ] || die "fixture missing: $FIXTURE"

# ── leg 0: positive control ────────────────────────────────────────────────────
# Every absence assertion below is worthless if the dump produced nothing, so the
# denominator is established first and the gate REFUSES rather than reporting 0/0.
timeout 180 "$ZEBRA" debug --dump-map "$FIXTURE" > "$W/map.txt" 2>"$W/map.err"
rc=$?
[ $rc -eq 0 ] || { sed 's/^/    /' "$W/map.err" | head -8; die "--dump-map exited $rc on the fixture"; }

fx_key="test/bug329_print_sourcemap_test.zbr"
rows=$(grep -c '^M' "$W/map.txt" || true)
fx_rows=$(awk -F'\t' -v k="$fx_key" '$1=="M" && $3 ~ k' "$W/map.txt" | wc -l | tr -d ' ')
[ "$rows"    -ge 8 ] || die "only $rows markers in the whole dump — the parser collapsed"
[ "$fx_rows" -ge 6 ] || die "only $fx_rows markers for $fx_key — the fixture was not mapped"
ok "positive control: $rows markers, $fx_rows for the fixture"

# ── leg 1: the round trip ──────────────────────────────────────────────────────
# zbrToZig then zigToZbr must return the pair it started from, for every marker.
rt_bad=$(awk -F'\t' '$1=="M" && ($6 != $3 || $7 != $4)' "$W/map.txt")
if [ -z "$rt_bad" ]; then
  ok "round trip: all $rows markers map back to themselves"
else
  bad "round trip broken for $(printf '%s\n' "$rt_bad" | wc -l | tr -d ' ') marker(s)"
  printf '%s\n' "$rt_bad" | head -4 | sed 's/^/       /'
fi

# ── leg 2: the independent oracle ──────────────────────────────────────────────
# The fixture's prints name their own line. Derived from the SOURCE, so it cannot
# be satisfied by a map that merely agrees with itself.
awk -F'\t' -v k="$fx_key" '$1=="M" && $3 ~ k {print $4}' "$W/map.txt" | sort -u > "$W/mapped.txt"
missing=""; expected=0
while IFS=: read -r ln _; do
  expected=$((expected+1))
  grep -qx "$ln" "$W/mapped.txt" || missing="$missing $ln"
done < <(grep -n '"L[0-9]*"' "$FIXTURE" | cut -d: -f1)
[ "$expected" -ge 5 ] || die "oracle found only $expected labelled lines — the fixture lost its labels"
if [ -z "$missing" ]; then
  ok "source oracle: all $expected labelled lines appear in the map"
else
  bad "source oracle: labelled line(s) absent from the map:$missing"
  echo "       (if you inserted a line in the fixture, its L<N> labels are now wrong — fix those)"
fi

# ── leg 3: the last-colon split (a Windows path carries its own colons) ────────
printf 'const x = 1;\n    // zbr:C:/proj/a.zbr:42\nconst y = 2;\n' > "$W/win.zig"
timeout 60 "$ZEBRA" debug --dump-map "$W/win.zig" > "$W/win.txt" 2>&1
if awk -F'\t' '$1=="M" && $3=="C:/proj/a.zbr" && $4=="42"' "$W/win.txt" | grep -q .; then
  ok "drive-letter path splits at the LAST colon (C:/proj/a.zbr : 42)"
else
  bad "drive-letter path mis-split"
  grep '^M' "$W/win.txt" | head -3 | sed 's/^/       /'
fi

# ── leg 4: a malformed marker is skipped, never defaulted ──────────────────────
printf '// zbr:noline\n// zbr::5\n// zbr:ok.zbr:7\n// zbr:bad.zbr:xx\n' > "$W/mal.zig"
timeout 60 "$ZEBRA" debug --dump-map "$W/mal.zig" > "$W/mal.txt" 2>&1
mal_rows=$(grep -c '^M' "$W/mal.txt" || true)
if [ "$mal_rows" = "1" ] && awk -F'\t' '$1=="M" && $3=="ok.zbr" && $4=="7"' "$W/mal.txt" | grep -q .; then
  ok "malformed markers skipped (1 of 4 kept, and it is the well-formed one)"
else
  bad "malformed marker handling: kept $mal_rows rows, expected exactly 1"
  grep '^M' "$W/mal.txt" | head -4 | sed 's/^/       /'
fi

# ── leg 5: discrimination — the count is measured, not constant ────────────────
printf 'const x = 1;\n// not a marker\n' > "$W/none.zig"
timeout 60 "$ZEBRA" debug --dump-map "$W/none.zig" > "$W/none.txt" 2>&1
none_rows=$(grep -c '^M' "$W/none.txt" || true)
if [ "$none_rows" = "0" ] && grep -q '^zbr-map: 0 markers' "$W/none.txt"; then
  ok "a file with no markers reports 0 (the count can say zero)"
else
  bad "no-marker file reported $none_rows rows — the count is not measuring"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "debug-map: $pass/$pass passed"
  exit 0
fi
echo "debug-map: $fail FAILED, $pass passed"
exit 1
