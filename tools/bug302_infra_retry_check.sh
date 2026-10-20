#!/usr/bin/env bash
# pins: BUG-302 the retry/classification guard in tools/zig_build_lib.sh IS the regression
# test for this bug -- no test/*.zbr can reproduce it, because the failure is zig being
# unable to read its OWN stdlib under concurrent builds, not anything about Zebra source.
# BUG-302 control: does full_sweep's infra-retry actually survive the real failure?
#
# NOT a mutation test. The attacker is a stub `zig` that reproduces the EXACT stderr a
# real transient stdlib read-failure produces, fails on its first invocation per file,
# and succeeds afterwards. A cooperative mutation (say, matching on a marker string the
# real error does not contain) would pass while the guard did nothing.
#
# Three legs, all of which must hold:
#   1. ATTACK   -- infra error on try 1, success on try 2  => PASS, retry recorded
#   2. NEGATIVE -- a genuine compile error, every try      => CFAIL, NO retry burned
#   3. PERSIST  -- infra error on every try                => INFRA, not CFAIL
#
# Leg 2 is the one that stops this being security theatre: a retry that fires on real
# compile errors would mask genuine breakage AND triple the gate's runtime.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Source the SHIPPED predicate. A control carrying its own copy would pass against
# logic the gate does not have -- the cooperative-attacker failure, one level up.
. "$REPO/tools/zig_build_lib.sh"
TMP="${TMPDIR:-/tmp}/zz_bug302_control"
rm -rf "$TMP"; mkdir -p "$TMP/bin"

# The real error text, verbatim from evidence captured 2026-08-22.
INFRA_ERR="/c/x/.zvm/0.16.0/lib/std/debug.zig:1:1: error: unable to load 'debug.zig': Unexpected
/c/x/.zvm/0.16.0/lib/std/std.zig:71:27: note: file imported here"
REAL_ERR="widget.zig:42:9: error: expected type 'i64', found '[]const u8'"

make_stub() {  # $1 = mode
  cat > "$TMP/bin/zig" <<STUB
#!/usr/bin/env bash
c="$TMP/count"
n=\$(cat "\$c" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$c"
case "$1" in
  attack)  if [ "\$n" -le 1 ]; then echo "$INFRA_ERR" >&2; exit 1; fi; exit 0 ;;
  persist) echo "$INFRA_ERR" >&2; exit 1 ;;
  real)    echo "$REAL_ERR"  >&2; exit 1 ;;
esac
STUB
  chmod +x "$TMP/bin/zig"; rm -f "$TMP/count"
}

# Exercise the REAL predicate + retry loop out of full_sweep.sh rather than a copy of it,
# so this cannot pass against logic the gate does not have.
run_leg() {   # $1 = mode  -> echoes "VERDICT retries"
  make_stub "$1"
  local berr="$TMP/build.err" attempt=1 rc=0 retries=0
  while :; do
    PATH="$TMP/bin:$PATH" zig build-exe -fno-emit-bin -lc "$TMP/x.zig" >/dev/null 2>"$berr"   # hazard-ok:H14 runs only a STUB zig, put first on PATH per command; the real one is never invoked
    rc=$?
    [ $rc -eq 0 ] && break
    if [ $attempt -lt 3 ] && zbr_zig_infra_error "$berr"; then
      retries=$((retries+1)); attempt=$((attempt+1)); continue
    fi
    break
  done
  if [ $rc -eq 0 ]; then echo "PASS $retries"
  elif zbr_zig_infra_error "$berr"; then echo "INFRA $retries"
  else echo "CFAIL $retries"; fi
}

fail=0
check() { # $1=leg $2=got $3=want
  if [ "$2" = "$3" ]; then printf '  ok    %-9s %s\n' "$1" "$2"
  else printf '  FAIL  %-9s got "%s" want "%s"\n' "$1" "$2" "$3"; fail=1; fi
}
check attack   "$(run_leg attack)"  "PASS 1"
check negative "$(run_leg real)"    "CFAIL 0"
check persist  "$(run_leg persist)" "INFRA 2"

# zbr_run_retrying (2026-10-20): the wrapper the smoke suite runs every compile through. A stub
# COMMAND, the shipped function. Each leg reports "rc runs retries-logged out-ok err-ok".
make_cmd() {  # $1 = mode
  cat > "$TMP/cmd" <<STUB
#!/usr/bin/env bash
c="$TMP/ccount"
n=\$(cat "\$c" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$c"
case "$1" in
  attack)  if [ "\$n" -le 1 ]; then echo "$INFRA_ERR" >&2; exit 1; fi; echo OUT-MARK; echo ERR-MARK >&2; exit 0 ;;
  real)    echo "$REAL_ERR" >&2; exit 1 ;;
  persist) echo "$INFRA_ERR" >&2; exit 1 ;;
  success) echo "$INFRA_ERR"; exit 0 ;;
esac
STUB
  chmod +x "$TMP/cmd"; rm -f "$TMP/ccount" "$TMP/rlog"
}
wrap_leg() {  # $1 = mode
  make_cmd "$1"
  local rc
  ZBR_RUN_RETRY_FILE="$TMP/rlog" zbr_run_retrying "$TMP/cmd" >"$TMP/wo" 2>"$TMP/we"; rc=$?
  local runs logged ook=no eok=no
  runs=$(cat "$TMP/ccount" 2>/dev/null || echo 0)
  logged=$( [ -f "$TMP/rlog" ] && wc -l < "$TMP/rlog" | tr -d ' ' || echo 0)
  case "$1" in
    attack)  grep -q OUT-MARK "$TMP/wo" && ! grep -q OUT-MARK "$TMP/we" && ook=yes
             grep -q ERR-MARK "$TMP/we" && ! grep -q ERR-MARK "$TMP/wo" && eok=yes ;;
    real)    ook=yes; grep -q "expected type" "$TMP/we" && eok=yes ;;
    persist) ook=yes; grep -q "unable to load" "$TMP/we" && eok=yes ;;
    success) grep -q "unable to load" "$TMP/wo" && ook=yes; eok=yes ;;
  esac
  echo "$rc $runs $logged $ook $eok"
}
check wrap-attack   "$(wrap_leg attack)"  "0 2 1 yes yes"
check wrap-negative "$(wrap_leg real)"    "1 1 0 yes yes"
check wrap-persist  "$(wrap_leg persist)" "1 3 2 yes yes"
check wrap-success  "$(wrap_leg success)" "0 1 0 yes yes"

# The predicate must also discriminate on REAL captured evidence, not just stub text.
EV="${LOCALAPPDATA:-/c/Users/$USER/AppData/Local}/Temp/zebra_full_sweep/evidence"
if [ -d "$EV" ]; then
  inf=0; gen=0
  for f in "$EV"/*.cfail.err; do
    [ -e "$f" ] || continue
    if zbr_zig_infra_error "$f"; then inf=$((inf+1)); else gen=$((gen+1)); fi
  done
  printf '  ok    evidence  %d infra / %d genuine, from real captured errors\n' "$inf" "$gen"
  [ "$gen" -lt 5 ] && { echo "  FAIL  evidence  too few genuine errors to prove discrimination"; fail=1; }
fi

[ $fail -eq 0 ] && echo "bug302-control: all legs pass" || echo "bug302-control: FAILED"
exit $fail
