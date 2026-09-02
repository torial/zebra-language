#!/usr/bin/env bash
# THE CLI-SURFACE GATE — the only gate that exercises the compiler AS A COMMAND.
#
#   bash tools/cli_check.sh
#
# WHY IT EXISTS. Every other gate asks what the compiler DOES WITH A PROGRAM: does it
# emit, does the emit compile, does the program print the right thing. Nothing asked what
# the compiler does when a PERSON types something at it. That gap is not hypothetical --
# four bugs were found in it on 2026-08-30/09-01, and one of them (BUG-327) had a hard
# compile error sitting inside `zebra build` through 37 green gates.
#
# The gap is structural, not an oversight: the compiler's argument handling is not part of
# compiling the compiler, so the whole self-hosting self-check region never touches it.
# See wiki/pages/concepts/concept_self-verification-blind-spot.md.
#
# IT RUNS FROM A SCRATCH DIRECTORY OUTSIDE THE REPO, AND THAT IS THE POINT.
# BUG-322 was four delegations resolving "zig-out/bin/zebra-bootstrap.exe" RELATIVE TO THE
# CWD, so `zebra repl` and `zebra build` crashed for every user while working perfectly
# from the repo root. A CLI suite run from the repo root would have passed on the day that
# bug shipped. Every leg here runs in $W, which is not inside the repo.
#
# EVERY LEG HAS A TIMEOUT. BUG-327's second layer turns `zebra build` into an infinite
# loop; without a timeout this gate would HANG rather than fail, which is strictly worse.
#
# KNOWN-BROKEN BEHAVIOUR IS PINNED, NOT SKIPPED (the @boundary-pending idiom): a pin
# asserts today's WRONG answer, prints its ticket every run, and FAILS THE GATE THE DAY
# THE BUG IS FIXED -- which is the signal to promote it to a real assertion. Excluding
# them instead is how node-addon rotted for two weeks.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
W="${TMPDIR:-/tmp}/zbr_cli_check"
TMO=90

[ -x "$ZEBRA" ] || { echo "cli-check: REFUSING -- not built: $ZEBRA" >&2; exit 2; }

rm -rf "$W"; mkdir -p "$W"
case "$W" in "$REPO"*) echo "cli-check: REFUSING -- scratch dir is inside the repo" >&2; exit 2;; esac

cat > "$W/hello.zbr" <<'EOF'
def main()
    print("hi")
EOF
cat > "$W/bad.zbr" <<'EOF'
def main()
    var x: int = "nope"
EOF

pass=0; fail=0; xfail=0; xpass=0
O="$W/.out"; E="$W/.err"

run() {  # run <args...>  -> sets RC / OUT_N / ERR_N / OUT / ERR
    ( cd "$W" && timeout "$TMO" "$ZEBRA" "$@" >"$O" 2>"$E" </dev/null )
    RC=$?
    OUT_N=$(wc -c < "$O" | tr -d ' '); ERR_N=$(wc -c < "$E" | tr -d ' ')
    OUT=$(tr -d '\r' < "$O"); ERR=$(tr -d '\r' < "$E")
}

ok()   { pass=$((pass+1)); printf '  ok     %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL   %s\n' "$1"; [ -n "${2:-}" ] && printf '           %s\n' "$2"; }
chk()  { if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# A pin asserts the CURRENT WRONG behaviour. If the condition stops holding, the bug is
# fixed and the gate FAILS so the pin gets promoted rather than quietly outliving its bug.
pin()  { # pin <label> <ticket> <still-broken?0/1>
    if [ "$3" = 0 ]; then xfail=$((xfail+1)); printf '  xfail  %s  (%s)\n' "$1" "$2"
    else xpass=$((xpass+1)); fail=$((fail+1))
         printf '  FAIL   %s is FIXED (%s) — promote this pin to a real assertion\n' "$1" "$2"; fi; }

echo "── CLI surface (run from $W, deliberately OUTSIDE the repo) ──"

# ---- POSITIVE CONTROL FIRST -------------------------------------------------------
# If the compiler cannot do the simplest correct thing, every absence test below passes
# vacuously and this gate reports green while measuring nothing.
run -c hello.zbr
if [ "$RC" != 0 ] || [ "$ERR_N" = 0 ]; then
    echo "cli-check: REFUSING -- the control (\`-c\` on a good file) did not succeed:" >&2
    echo "  exit=$RC stdout=$OUT_N stderr=$ERR_N" >&2
    head -3 "$E" >&2
    exit 2
fi
ok "control: \`-c\` on a valid file exits 0 and reports"

# ---- things that must SUCCEED -----------------------------------------------------
run hello.zbr
chk "running a program exits 0 and prints to STDOUT" \
    "$([ "$RC" = 0 ] && case "$OUT" in *hi*) echo 0;; *) echo 1;; esac || echo 1)" \
    "exit=$RC stdout=[$OUT]"

run --emit-zig hello.zbr
chk "\`--emit-zig\` writes the source to STDOUT" \
    "$([ "$OUT_N" -gt 200 ] && echo 0 || echo 1)" "stdout=$OUT_N bytes"

# ---- things that must FAIL, and say why --------------------------------------------
run -c bad.zbr
chk "a type error exits non-zero" "$([ "$RC" != 0 ] && echo 0 || echo 1)" "exit=$RC"
chk "...and names the file and a position" \
    "$(case "$ERR" in *bad.zbr:*) echo 0;; *) echo 1;; esac)" "stderr=[$(echo "$ERR"|head -2|tr '\n' ' ')]"

run -c no_such_file.zbr
chk "a missing source file is REFUSED by name" \
    "$([ "$RC" != 0 ] && case "$ERR" in *no_such_file*) echo 0;; *) echo 1;; esac || echo 1)" \
    "exit=$RC stderr=[$ERR]"

run
chk "no arguments prints usage to STDERR and exits non-zero" \
    "$([ "$RC" != 0 ] && [ "$ERR_N" -gt 500 ] && [ "$OUT_N" = 0 ] && echo 0 || echo 1)" \
    "exit=$RC stdout=$OUT_N stderr=$ERR_N"

# ---- diagnostics belong on stderr, output on stdout ---------------------------------
run hello.zbr
chk "diagnostics do NOT contaminate stdout" \
    "$(case "$OUT" in *compiling:*) echo 1;; *) echo 0;; esac)" "stdout=[$OUT]"

# ---- the delegated subcommands, from OUTSIDE the repo (BUG-322) ---------------------
run repl
chk "\`zebra repl\` starts from a user directory (BUG-322)" \
    "$([ "$RC" = 0 ] && echo 0 || echo 1)" "exit=$RC — a panic here is BUG-322 regressing"

run build
chk "\`zebra build\` does not CRASH from a user directory (BUG-322)" \
    "$([ "$RC" != 3 ] && [ "$RC" != 124 ] && echo 0 || echo 1)" \
    "exit=$RC (3=panic, 124=hang: both are regressions)"
chk "...and says something rather than failing silently" \
    "$([ "$ERR_N" -gt 0 ] || [ "$OUT_N" -gt 0 ] && echo 0 || echo 1)" "stdout=$OUT_N stderr=$ERR_N"

# ---- KNOWN-BROKEN, PINNED -----------------------------------------------------------
run --version
pin "\`--version\` writes to stderr, not stdout" "BUG-321" "$([ "$OUT_N" = 0 ] && echo 0 || echo 1)"

run --help
pin "\`--help\` writes to stderr and exits non-zero" "BUG-321" \
    "$([ "$OUT_N" = 0 ] && [ "$RC" != 0 ] && echo 0 || echo 1)"

run --no-such-flag hello.zbr
pin "an unknown flag is silently ignored" "BUG-323" "$([ "$RC" = 0 ] && echo 0 || echo 1)"

echo
printf '  %s passed, %s pinned (known-broken), %s FAILED\n' "$pass" "$xfail" "$fail"
if [ "$fail" -eq 0 ]; then
    echo "cli-check: PASS — $pass assertion(s), $xfail pin(s)"
    exit 0
fi
[ "$xpass" -gt 0 ] && echo "  NOTE: $xpass pin(s) started passing — that is a FIX to promote, not a break." >&2
echo "cli-check: $fail FAILED" >&2
exit 1
