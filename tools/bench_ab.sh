#!/usr/bin/env bash
# A/B benchmark with the failure modes designed out.
#
#   bash tools/bench_ab.sh <baseline.exe> <A.exe> <B.exe> [rounds] [labelA] [labelB]
#
# `baseline.exe` must be the SAME program with the work parameter set to zero. Its time is
# process startup plus setup, and it is SUBTRACTED -- without it you are measuring Windows
# process creation.
#
# WHY EACH GUARD EXISTS. Every one is a mistake made on 2026-08-26 while measuring BUG-313's
# bounds-check cost, and each produced a confident wrong number rather than an error:
#
#   NO BASELINE -> measured process startup. 0 iterations cost 165 ms, 100 iterations cost
#   149 ms (LESS), 400 cost 208 ms: fixed overhead was ~10x the signal. An early "64%
#   overhead" from that setup was measuring nothing at all.
#
#   SIGNAL BELOW NOISE -> the same binary measured 454 ms and 815 ms in consecutive runs.
#   This machine has a documented 2x spread on identical binaries. So: interleave, take
#   MINIMUMS (least contaminated by interference), and REFUSE when the A-B difference is
#   smaller than the observed spread of the baseline itself.
#
#   DIFFERENT ANSWERS -> two builds that compute different things are not comparable. Their
#   stdout must match exactly, or the comparison is meaningless.
#
#   A MUTANT THAT DIFFERS IN TWO WAYS -> cannot be checked here, and is the one failure this
#   tool cannot see for you. The first BUG-313 mutant removed a bounds check AND changed
#   `@intCast` to `@bitCast`; the "unchecked" build came out 3.6x SLOWER, a backwards result
#   that was the mutant's fault. If a result surprises you, suspect the mutant before the
#   subject. This is printed on every run rather than left in a comment.
set -u

if [ $# -lt 3 ]; then
    sed -n '2,6p' "$0" | sed 's/^# \?//'
    exit 2
fi
BASE="$1"; A="$2"; B="$3"; ROUNDS="${4:-10}"; LA="${5:-A}"; LB="${6:-B}"

for f in "$BASE" "$A" "$B"; do
    [ -x "$f" ] || [ -f "$f" ] || { echo "bench_ab: REFUSING -- not found: $f" >&2; exit 2; }
done

# ── the two builds must compute the same thing ──────────────────────────────────────────
oa="$("$A" 2>&1)"; ob="$("$B" 2>&1)"
if [ "$oa" != "$ob" ]; then
    echo "bench_ab: REFUSING -- the two builds print DIFFERENT output, so they are not" >&2
    echo "  comparable. A timing difference here would be measuring different work." >&2
    echo "    $LA: $(printf '%s' "$oa" | head -2 | tr '\n' ' ')" >&2
    echo "    $LB: $(printf '%s' "$ob" | head -2 | tr '\n' ' ')" >&2
    exit 2
fi

ms() { local s e; s=$(date +%s%N); "$1" >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e-s)/1000000 )); }

bmin=999999999; bmax=0; amin=999999999; amax=0; cmin=999999999; cmax=0
for _ in $(seq 1 "$ROUNDS"); do
    t=$(ms "$BASE"); [ "$t" -lt "$bmin" ] && bmin=$t; [ "$t" -gt "$bmax" ] && bmax=$t
    t=$(ms "$A");    [ "$t" -lt "$amin" ] && amin=$t; [ "$t" -gt "$amax" ] && amax=$t
    t=$(ms "$B");    [ "$t" -lt "$cmin" ] && cmin=$t; [ "$t" -gt "$cmax" ] && cmax=$t
done

# THE NOISE FLOOR IS THE WORST SPREAD OBSERVED, not the baseline's. A first version compared
# against the BASELINE spread only, and reported 11% for a pair that had measured 91% an hour
# earlier on the same binaries -- because a 90 ms process jitters by ~10 ms while a 500 ms one
# jitters by ~250 ms. Using the short process's spread as the floor for the long one's
# difference is how a noise guard passes something it should have refused.
la=$(( amin - bmin )); lb=$(( cmin - bmin ))
aspread=$(( amax - amin )); cspread=$(( cmax - cmin )); bspread=$(( bmax - bmin ))
spread=$bspread
[ "$aspread" -gt "$spread" ] && spread=$aspread
[ "$cspread" -gt "$spread" ] && spread=$cspread

echo "── bench_ab: $ROUNDS interleaved rounds, minimums ──"
printf '  baseline (zero work) : %6s ms   spread %s ms\n' "$bmin" "$bspread"
printf '  %-20s : %6s ms   work = %-5s ms   spread %s ms\n' "$LA" "$amin" "$la" "$aspread"
printf '  %-20s : %6s ms   work = %-5s ms   spread %s ms\n' "$LB" "$cmin" "$lb" "$cspread"
printf '  noise floor (worst spread seen)  : %s ms\n' "$spread"

# ── the work must dominate the fixed overhead ───────────────────────────────────────────
if [ "$la" -le 0 ] || [ "$lb" -le 0 ]; then
    echo "  REFUSING: a build measured NO work above the baseline. Increase the work" >&2
    echo "  parameter until the loop dominates; otherwise this measures process startup." >&2
    exit 2
fi
if [ "$la" -lt "$bmin" ] || [ "$lb" -lt "$bmin" ]; then
    echo "  WARNING: the work is smaller than the fixed overhead ($bmin ms). The subtraction"
    echo "  is doing most of the arithmetic, which makes the result fragile. Prefer more work."
fi

# ── the difference must exceed the observed noise ───────────────────────────────────────
diff=$(( la - lb )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
if [ "$diff" -le "$spread" ]; then
    echo
    echo "  REFUSING TO REPORT A RATIO: the difference between the two builds ($diff ms) is" >&2
    echo "  no larger than the WORST spread seen across this run ($spread ms). Any" >&2
    echo "  percentage computed from that would be noise wearing a decimal point." >&2
    echo "  Increase the work, quiet the machine, or raise the round count." >&2
    exit 1
fi

pct=$(( (la - lb) * 100 / lb ))
echo
printf '  %s is %s%% %s than %s  (%s ms vs %s ms of work)\n' \
    "$LA" "${pct#-}" "$( [ "$pct" -ge 0 ] && echo slower || echo faster )" "$LB" "$la" "$lb"
echo
echo "  NOTE: this tool cannot tell whether the two builds differ in only ONE way. If the"
echo "  result surprises you, suspect the mutant before the subject."
