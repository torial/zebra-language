#!/usr/bin/env bash
# THE POSITIVE-SET ENUMERATOR — the tests the smoke suite declares must SUCCEED.
#
# One derivation, two consumers, for the same reason tools/corpus_ls.sh exists: the set
# was previously computed inside compile_check.sh alone, and full_sweep.sh now needs the
# identical answer to assert compile_check's property. Two copies of "what counts as a
# positive test" would drift the first time a registration helper is added, and the
# drift would be SILENT — a gate would simply check fewer files.
#
# The source of truth is selfhost_smoke.sh's own registrations: a helper that asserts
# SUCCESS (smoke / smoke_turbo / smoke_test / smoke_run / smoke_run_bootstrap /
# smoke_warn) marks a positive test; the *_fail helpers mark negatives and are excluded,
# as are library-only modules that are never registered at all.
#
# REFUSES rather than printing an empty set: a collapsed regex would otherwise hand its
# caller "zero positive tests", which reads as a clean sweep.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SMOKE="$REPO/tools/selfhost_smoke.sh"

if [ ! -f "$SMOKE" ]; then
    echo "positive_set: REFUSING — cannot find tools/selfhost_smoke.sh" >&2
    exit 2
fi

# HARNESS LIMITS, not bugs: these need external source/C files the emit step does not
# materialize, so they cannot be compile-checked standalone. They ARE registered
# positive and DO pass under selfhost_smoke, which runs them properly -- what fails is
# the standalone-emit harness, not the test.
#
# THE LIST LIVES HERE, WITH THE ENUMERATOR, on purpose. It used to sit inside
# compile_check.sh (hence its "N passed, 0 FAILED, 2 skipped"). When full_sweep gained
# the same absolute assertion it did NOT inherit the skips, and c_interop_test --
# correctly CFAIL in a standalone sweep -- would have been reported as a must-pass
# FAILURE. A gate that libels a working file is one people learn to disbelieve, which
# is why full_sweep has a DEPMISS bucket at all.
SKIP=" c_interop_test forgot_parens_test "

out=$(grep -hE '^(smoke|smoke_turbo|smoke_test|smoke_run|smoke_run_bootstrap|smoke_warn) +test/' "$SMOKE" \
      | awk '{print $2}' | sort -u)

# Drop the skips with ONE grep rather than a basename-per-file loop: 278 process
# spawns is seconds of pure overhead on Git Bash, and this is called from two gates.
skip_re=$(printf '%s
' $SKIP | grep -v '^$' | paste -sd'|' -)
if [ -n "$skip_re" ]; then
    out=$(printf '%s
' "$out" | grep -vE "/(${skip_re})\.zbr$")
fi

n=$(printf '%s\n' "$out" | grep -c .)
if [ "$n" -lt 100 ]; then
    echo "positive_set: REFUSING — only $n positive tests found; expected >=100." >&2
    echo "  A collapsed derivation must not look like a small corpus." >&2
    exit 2
fi
printf '%s\n' "$out"
