#!/usr/bin/env bash
# pins: BUG-778 a refusal `-c` makes reaches `zebra diagnostics` (the LSP's view) and `--target v` too
#
# THE REFUSAL-PARITY GATE. Three consumers run the front end: `zebra -c` (and every build),
# `zebra diagnostics` -- the strict view the LSP shares -- and `--target v` (since BUG-777).
# A rule checked in CodeGen at Zig emit time reaches only the first: the editor shows no
# error on a file that will not build, and the V route writes a .v for a program the Zig
# route refuses (BUG-778, eight fixtures on the day it was filed). Nothing compared the
# three, because every gate asks ONE consumer.
#
# For every fixture the smoke suite declares must-reject (tools/must_reject_set.sh):
#   -c          must exit non-zero; each `<file>:L[:C]: error:` it prints on the fixture
#               itself is a position the other two must also report
#   diagnostics must list an error at each of those lines (and column, when -c gives one)
#   --target v  must exit non-zero and write no .v
# A fixture whose refusal one consumer misses is a GAP. Gaps known today are baselined in
# tools/refusal_parity_baseline.txt; a NEW gap fails, and a baselined gap that has CLOSED
# fails too, naming the line to delete -- the baseline only shrinks.
#
# Runs on a copy of test/ in scratch (`--target v` writes the .v beside the source).
# CONTROLS, run first, both directions per consumer, derived from probes written here:
# a clean program must be accepted by all three (each reader can see ABSENCE) and a program
# with a checker error refused by all three (each can see PRESENCE). If any control fails
# the gate REFUSES (exit 2) rather than reporting.
#
# CANNOT SEE: a refusal the smoke suite does not register as must-reject; whether a message
# reads the same in each consumer; `smoke_run_fail` fixtures (excluded by must_reject_set).
set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
source tools/zig_toolchain.sh >/dev/null 2>&1 || true
source tools/scratch_paths.sh
ZEBRA="${ZEBRA:-$REPO/zig-out/bin/zebra.exe}"
[ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"
[ -x "$ZEBRA" ] || { echo "refusal-parity: REFUSING -- no compiler at zig-out/bin" >&2; exit 2; }
# REFUSAL_PARITY_BASELINE is a test hook (the red-check points it at a planted baseline);
# no tier sets it.
BASELINE="${REFUSAL_PARITY_BASELINE:-tools/refusal_parity_baseline.txt}"
UPDATE=0
[ "${1:-}" = "--update-baseline" ] && UPDATE=1

W="${ZBR_BS}-refusal-parity"
rm -rf "$W"; mkdir -p "$W/t" "$W/ctl"
git ls-files test | while IFS= read -r f; do
  mkdir -p "$W/t/$(dirname "$f")"; cp "$f" "$W/t/$f"
done

# classify DIR FILE -> prints one of: ok | c-accepts | diag-miss | v-miss | diag-miss,v-miss
# and, on stderr-free stdout, nothing else. Positions: every "<base>:L[:C]: error:" line.
classify() {
  local dir="$1" file="$2" base cout crc dj pos missd=0 vrc vout stem vfile
  base=$(basename "$file")
  cout=$(cd "$dir" && timeout 120 "$ZEBRA" -c "$file" 2>&1 >/dev/null); crc=$?
  if [ $crc -eq 0 ]; then echo "c-accepts"; return; fi
  dj=$(cd "$dir" && timeout 120 "$ZEBRA" diagnostics "$file" --out "$W/diag.json" >/dev/null 2>&1; cat "$W/diag.json" 2>/dev/null)
  rm -f "$W/diag.json"
  pos=$(printf '%s\n' "$cout" | grep -oE "(^|/)${base//./\\.}:[0-9]+(:[0-9]+)?: error:" | sed -E 's#^/##; s#: error:$##; s#^[^:]*:##' | sort -u)
  if [ -z "$pos" ]; then
    # -c refused without naming a position in this file (a dep's error, a driver refusal):
    # the other consumers must still report SOME error
    printf '%s' "$dj" | grep -q '"severity":"error"' || missd=1
  else
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      l=${p%%:*}; c=""
      [ "$p" != "$l" ] && c=${p#*:}
      if [ -n "$c" ]; then
        printf '%s' "$dj" | grep -q "{\"line\":$l,\"col\":$c,\"severity\":\"error\"" || missd=1
      else
        printf '%s' "$dj" | grep -qE "\\{\"line\":$l,\"col\":[0-9]+,\"severity\":\"error\"" || missd=1
      fi
    done <<< "$pos"
  fi
  stem=${base%.zbr}; [[ "$stem" == *_test ]] && stem="${stem}_prog"
  vfile="$dir/$stem.v"; rm -f "$vfile"
  (cd "$dir" && timeout 120 "$ZEBRA" --target v "$file" >/dev/null 2>&1); vrc=$?
  local vmiss=0
  if [ $vrc -eq 0 ] || [ -f "$vfile" ]; then vmiss=1; fi
  rm -f "$vfile"
  if [ $missd -eq 1 ] && [ $vmiss -eq 1 ]; then echo "diag-miss,v-miss"
  elif [ $missd -eq 1 ]; then echo "diag-miss"
  elif [ $vmiss -eq 1 ]; then echo "v-miss"
  else echo "ok"; fi
}

# ── controls ────────────────────────────────────────────────────────────────
printf 'def main()\n    var n: int = 2\n    print("n ${n}")\n' > "$W/ctl/zz_clean.zbr"
printf 'def main()\n    var n: int = "two"\n    print("n ${n}")\n' > "$W/ctl/zz_refused.zbr"
ctl_fail=""
(cd "$W/ctl" && "$ZEBRA" -c zz_clean.zbr >/dev/null 2>&1) || ctl_fail="$ctl_fail clean:-c"
(cd "$W/ctl" && "$ZEBRA" diagnostics zz_clean.zbr --out "$W/c.json" >/dev/null 2>&1)
[ "$(cat "$W/c.json" 2>/dev/null)" = "[]" ] || ctl_fail="$ctl_fail clean:diagnostics"
(cd "$W/ctl" && "$ZEBRA" --target v zz_clean.zbr >/dev/null 2>&1 && [ -f zz_clean.v ]) || ctl_fail="$ctl_fail clean:--target-v"
r=$(classify "$W/ctl" zz_refused.zbr)
[ "$r" = "ok" ] || ctl_fail="$ctl_fail refused:$r"
if [ -n "$ctl_fail" ]; then
  echo "refusal-parity: REFUSING -- a control failed:$ctl_fail (a reader that cannot see both ways has measured nothing)"
  exit 2
fi

# ── the must-reject set ─────────────────────────────────────────────────────
names=$(bash tools/must_reject_set.sh) || { echo "refusal-parity: REFUSING -- must_reject_set failed" >&2; exit 2; }
: > "$W/result.txt"
n=0; missing=0
for nm in $names; do
  rel=$(cd "$W/t" && find test -name "$nm.zbr" | head -1)
  if [ -z "$rel" ]; then missing=$((missing+1)); continue; fi
  n=$((n+1))
  r=$(classify "$W/t/$(dirname "$rel")" "$(basename "$rel")")
  printf '%s %s\n' "$nm" "$r" >> "$W/result.txt"
done
if [ $n -lt 100 ]; then
  echo "refusal-parity: REFUSING -- only $n must-reject fixtures found ($missing missing): the derivation collapsed"
  exit 2
fi
LC_ALL=C sort "$W/result.txt" -o "$W/result.txt"
grep -v ' ok$' "$W/result.txt" > "$W/gaps.txt" || true
ok=$(grep -c ' ok$' "$W/result.txt" || true)
gaps=$(wc -l < "$W/gaps.txt" | tr -d ' ')

if [ $UPDATE -eq 1 ]; then
  { echo "# refusal_parity_check.sh baseline: must-reject fixtures one consumer does not refuse."
    echo "# BUG-778. Shrink it; never grow it. Regenerate with --update-baseline."
    cat "$W/gaps.txt"; } > "$BASELINE"
  echo "refusal-parity: baseline written, $gaps gap(s) of $n fixtures"
  exit 0
fi

grep -v '^#' "$BASELINE" 2>/dev/null | LC_ALL=C sort > "$W/base.txt"
new=$(LC_ALL=C comm -13 "$W/base.txt" "$W/gaps.txt")
closed=$(LC_ALL=C comm -23 "$W/base.txt" "$W/gaps.txt")
rc=0
if [ -n "$new" ]; then
  echo "NEW refusal gaps (a consumer accepts what -c refuses, or -c accepts a must-reject fixture):"
  printf '%s\n' "$new" | sed 's/^/  /'; rc=1
fi
if [ -n "$closed" ]; then
  echo "CLOSED gaps still in $BASELINE -- delete these lines:"
  printf '%s\n' "$closed" | sed 's/^/  /'; rc=1
fi
known=$(wc -l < "$W/base.txt" | tr -d ' ')
if [ $rc -eq 0 ]; then
  echo "refusal-parity: PASS -- $n must-reject fixtures, $ok refused by all three consumers, $gaps known gap(s) (baseline $known)"
else
  echo "refusal-parity: FAIL -- $n fixtures, $ok refused by all three, $gaps gap(s) against a baseline of $known"
fi
exit $rc
