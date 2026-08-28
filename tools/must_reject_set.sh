#!/usr/bin/env bash
# THE MUST-REJECT ENUMERATOR — the names the smoke suite declares the FRONT END must refuse.
#
# The mirror of tools/positive_set.sh, and it exists for the same reason: one derivation,
# several consumers. `divergence_check.sh` carried its own copy inline
# (`'^smoke_tc_fail +test/[A-Za-z0-9_]+\.zbr'`) and that copy was LOSSY -- it required a
# flat path, so the three registrations under `test/fail_fixtures/` were invisible to it
# and its MUST_REJECT list was 48 where the suite registers 51. Harmless today only
# because `corpus_ls.sh test` does not recurse, so those names never reach the loop that
# consults it: an unstruck gap, armored here because a shared derivation costs nothing
# extra to get right.
#
# WHAT COUNTS AS MUST-REJECT, and what deliberately does NOT:
#
#   smoke_tc_fail          the front end must refuse it            -> INCLUDED
#   smoke_multi_parse_fail a multi-file parse must refuse it       -> INCLUDED
#   smoke_run_fail         "must fail SOMEHOW" -- it runs the whole
#                          compiler and asserts a non-zero exit, so
#                          a compile-time refusal and a runtime error
#                          both satisfy it                         -> EXCLUDED
#
# That last exclusion is a correction of a wrong model, not a judgement call. `run_fail`
# looked like "must emit cleanly, then fail when run", which would have made it a second
# must-NOT-emitfail set; reading the helper showed it asserts only that the run fails.
# Three of the eight registrations do in fact fail at compile time. Requiring them to
# EMITFAIL would be inventing a promise the suite does not make; forbidding it would be
# inventing the opposite one.
set -u
cd "$(dirname "$0")/.."
SMOKE=tools/selfhost_smoke.sh
FLOOR=40

[ -f "$SMOKE" ] || { echo "must_reject_set: REFUSING — $SMOKE not found" >&2; exit 2; }

# Registrations only: a line STARTING with the helper and naming a .zbr. The function
# DEFINITION (`smoke_tc_fail() {`) must not match, and a `\` continuation puts the
# expected-message argument on the next line, which is fine -- the path is on this one.
names="$(grep -hoE '^(smoke_tc_fail|smoke_multi_parse_fail)[[:space:]]+[^[:space:]]+\.zbr' "$SMOKE" \
         | sed -E 's/^[a-z_]+[[:space:]]+//; s#.*/##; s#\.zbr$##' \
         | sort -u)"

n=$(printf '%s\n' "$names" | grep -c .)

# REFUSE rather than report a collapsed set. A consumer that receives an empty must-reject
# list does not fail -- it silently treats every rejection as unexpected (divergence) or
# every EMITFAIL as accounted-for (the digest). Both read as a normal run.
if [ "$n" -lt "$FLOOR" ]; then
    echo "must_reject_set: REFUSING — derived only $n name(s), floor is $FLOOR." >&2
    echo "  The registration pattern has probably stopped matching. A short list here is" >&2
    echo "  invisible downstream: it does not error, it just quietly asserts less." >&2
    exit 2
fi

# A basename collision would make the NAME keying ambiguous for every consumer, all of
# which key on basename (the sweeps report basenames, not paths).
dupes="$(grep -hoE '^(smoke_tc_fail|smoke_multi_parse_fail)[[:space:]]+[^[:space:]]+\.zbr' "$SMOKE" \
         | sed -E 's/^[a-z_]+[[:space:]]+//; s#.*/##; s#\.zbr$##' | sort | uniq -d)"
if [ -n "$dupes" ]; then
    echo "must_reject_set: REFUSING — basename collision, consumers key on basename:" >&2
    printf '  %s\n' $dupes >&2
    exit 2
fi

printf '%s\n' "$names"
