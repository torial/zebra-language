#!/usr/bin/env bash
# pins: BUG-321 --help/-h/--version stream and exit code are asserted here, plus the
#       asymmetry (usage for a BAD invocation stays on stderr, non-zero). A CLI bug
#       has no test/*.zbr to be a fixture -- the subject is the compiler AS A COMMAND.
# pins: BUG-323 an unrecognized flag is refused BY NAME with the usage attached, and a
#       VALID flag still works -- both directions, since "refuses unknown flags" is
#       satisfied trivially by a build that refuses everything.
# pins: BUG-327 a build that calls b.run() succeeds and produces the named binary, and
#       running the build FILE directly refuses by name rather than HANGING (exit 124
#       would mean layer 2's infinite self-invocation had returned).
# pins: BUG-322 `zebra repl` and `zebra build` are exercised from a directory OUTSIDE
#       the repo, which is the only place that bug was ever visible.
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
# PER-RUN SCRATCH, and this is not hygiene -- it is a correctness fix. The path used to
# be fixed, so two concurrent runs wrote the SAME .out/.err and read each other's
# results. Observed 2026-09-01: a second invocation while one was in flight produced
# three failures whose evidence came from the OTHER run -- a "missing file" check
# reading the output of a successful compile. The compiler was fine; the harness was
# lying, in the direction of a false RED, which is the recoverable direction but still
# a gate nobody can trust.
#
# CLAUDE.md notes this repo regularly has two agents working in it at once, so a gate
# keyed on a fixed temp path is a matter of time rather than bad luck.
# NOTE: mktemp, not $$ -- in bash `$$` is the SHELL's pid and a ( ... ) & subshell
# INHERITS it, so keying on $$ isolated nothing. Verified by running two at once and
# still getting a failure.
W="$(mktemp -d "${TMPDIR:-/tmp}/zbr_cli_check.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# PER-LEG TIMEOUT, overridable. 90 s is generous on torial (the whole gate runs in ~16 s)
# and NOT on a cold CI runner: 2026-09-12 the BUG-324 leg -- the only one that takes the
# LLVM fallback, on a cache with nothing in it -- was killed at 90 s (exit 124) and reported
# as "left an executable", because a killed compiler never reaches its deleteScratch calls.
# The gate took 164 s there against 16 s locally. gates-quick/full.yml set CLI_CHECK_TMO=300.
TMO="${CLI_CHECK_TMO:-90}"

[ -x "$ZEBRA" ] || { echo "cli-check: REFUSING -- not built: $ZEBRA" >&2; exit 2; }

mkdir -p "$W"
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
bad()  { fail=$((fail+1)); printf '  FAIL   %s\n' "$1"; [ -n "${2:-}" ] && printf '           %s\n' "$2"
         # exit 124 is `timeout` killing the leg, not the compiler answering. Say so on the
         # line, because "exit=124 files=[...]" reads as a verdict about the files.
         case "${2:-}" in *"exit=124"*) printf '           (exit 124 = TIMED OUT at %ss -- the harness limit, not a compiler verdict; raise CLI_CHECK_TMO)\n' "$TMO";; esac; }
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
chk "\`--emit-zig\` writes the source to STDOUT (BUG-317: \`run\` captures to a FILE, so this IS the \`> file\` case)" \
    "$([ "$OUT_N" -gt 200 ] && echo 0 || echo 1)" "stdout=$OUT_N bytes"

# ---- BUG-325 (selfhost half): --emit-zig on a MULTI-MODULE program says so ----------
# stdout carries only the root, which imports dep.zig; without the note the captured
# text reads as a complete program and is not. Single-module must NOT get the note.
mkdir -p "$W/mm"
printf 'def two(): int\n    return 2\n' > "$W/mm/dep.zbr"
printf 'use dep exposing two\ndef main()\n    print(two())\n' > "$W/mm/main.zbr"
run --emit-zig mm/main.zbr
chk "\`--emit-zig\` on a multi-module program NOTES that only the root was printed (BUG-325)" \
    "$([ "$OUT_N" -gt 200 ] && case "$ERR" in *"prints only the root"*) echo 0;; *) echo 1;; esac || echo 1)" \
    "stdout=$OUT_N stderr=[$(echo "$ERR" | tail -1)]"
run --emit-zig hello.zbr
chk "...and a single-module program gets NO such note" \
    "$(case "$ERR" in *"prints only the root"*) echo 1;; *) echo 0;; esac)" "stderr=[$(echo "$ERR" | tail -1)]"

# ---- BUG-324: a FAILED compile leaves NO executable in --output-dir -----------------
# Zig can leave a stub at -femit-bin that segfaults with no output; anything reading the
# directory instead of the exit code would find it. Positive control: a GOOD compile
# still leaves its binary there (a fix that deletes unconditionally must not pass).
printf 'def main()\n    var x: int = zig"@as(i64, \\"s\\")"\n    print(x)\n' > "$W/zigbad.zbr"
rm -rf "$W/od_bad" "$W/od_good"
run --output-dir od_bad zigbad.zbr
chk "a FAILED compile leaves no executable in --output-dir (BUG-324)" \
    "$([ "$RC" != 0 ] && [ "$(ls "$W/od_bad" 2>/dev/null | grep -c '\.exe$')" = 0 ] && echo 0 || echo 1)" \
    "exit=$RC files=[$(ls "$W/od_bad" 2>/dev/null | tr '\n' ' ')]"
run --output-dir od_good hello.zbr
chk "...and a GOOD compile still leaves its executable there (control)" \
    "$([ "$RC" = 0 ] && [ "$(ls "$W/od_good" 2>/dev/null | grep -c '\.exe$')" -ge 1 ] && echo 0 || echo 1)" \
    "exit=$RC files=[$(ls "$W/od_good" 2>/dev/null | tr '\n' ' ')]"

# ---- `zebra up` (2026-09-14): refuses, by name and OFFLINE, outside an install layout --
# The compiler under test lives in zig-out/bin, not .../current, so `up` must refuse
# before touching the network -- which is also what makes this leg deterministic.
run up
chk "\`zebra up\` outside an installed layout REFUSES by name, before any download" \
    "$([ "$RC" = 2 ] && case "$ERR" in *"REFUSING"*"not an installed release"*) echo 0;; *) echo 1;; esac || echo 1)" \
    "exit=$RC stderr=[$(echo "$ERR" | head -1)]"

# ---- `zebra test --list` / `--only` (zebra-ide's tests pane, 2026-09-09) -----------
# `--list` is front-end only: label<TAB>line per test that WOULD run, from the harness's
# own inclusion rule, so the list and the run cannot disagree. A test with a parameter
# and a non-static class method are NOT tests and must not be listed. `--only` runs the
# named subset. These are pure CLI surface and, like everything in this file, invisible
# to every gate that feeds the compiler a program.
cat > "$W/tl.zbr" <<'ZEOF'
def test_alpha()
    assert 1 == 1

def test_beta()
    assert_eq 2, 2

def test_with_param(x: int)
    pass

class Calc
    def test_instance()
        pass
    static
        def test_static()
            assert 3 == 3

def main()
    print("tl")
ZEOF
run test --list tl.zbr
chk "\`test --list\` prints label<TAB>line per runnable test, in run order" \
    "$([ "$RC" = 0 ] && [ "$OUT" = "$(printf 'test_alpha\t1\ntest_beta\t4\nCalc.test_static\t14')" ] && echo 0 || echo 1)" \
    "exit=$RC stdout=[$OUT]"
chk "...and does NOT build (no 'compiling:' chatter, no .zig written)" \
    "$(case "$ERR$OUT" in *compiling:*) echo 1;; *) [ ! -f "$W/tl.zig" ] && echo 0 || echo 1;; esac)" "stderr=[$ERR]"
run test --only test_beta,Calc.test_static tl.zbr
chk "\`test --only a,B.c\` runs exactly the named tests" \
    "$([ "$RC" = 0 ] && case "$ERR" in *"PASS: test_beta"*"PASS: Calc.test_static"*"2 passed, 0 failed"*) case "$ERR" in *test_alpha*) echo 1;; *) echo 0;; esac;; *) echo 1;; esac || echo 1)" \
    "exit=$RC stderr=[$(echo "$ERR" | grep -E 'PASS|FAIL|passed' | tr '\n' ' ')]"

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
# THE REPL IS NATIVE AS OF 2026-09-02 (ported from src/Repl.zig), so this asserts that it
# EVALUATES, not merely that it starts. Starting proved something when the REPL was a
# delegation and the risk was BUG-322's relative path; now the risk is the port, and the
# property that matters is that SESSION STATE CARRIES BETWEEN CELLS -- the whole premise of
# replaying the session each time. Two bugs were found by driving exactly this and were
# invisible to both the front-end check and the build.
printf 'var x = 21\nprint("${x * 2}")\n:quit\n' > "$W/repl_in.txt"
( cd "$W" && timeout 420 "$ZEBRA" repl < "$W/repl_in.txt" >"$O" 2>"$E" )
RC=$?; OUT=$(tr -d '\r' < "$O"); ERR=$(tr -d '\r' < "$E")
chk "\`zebra repl\` runs from a user directory (BUG-322)" \
    "$([ "$RC" = 0 ] && echo 0 || echo 1)" "exit=$RC — a panic here is BUG-322 regressing"
chk "...and session state carries between cells (21 * 2 = 42)" \
    "$(case "$OUT$ERR" in *42*) echo 0;; *) echo 1;; esac)" \
    "stdout=[$(echo "$OUT" | tr '\n' ' ' | cut -c1-60)]"

# A DECL CELL must be accepted and then be CALLABLE. This is the case that failed on the
# first working build: a declarations-only session has no `def main()`, so running it died,
# and because it died the decl was never committed -- so the next cell reported the name as
# undefined. One defect presenting as two. Decl cells are type-checked, not run.
printf 'def dbl(n: int): int\n    return n * 2\n\nprint("${dbl(21)}")\n:quit\n' > "$W/repl_decl.txt"
( cd "$W" && timeout 420 "$ZEBRA" repl < "$W/repl_decl.txt" >"$O" 2>"$E" )
RC=$?; OUT=$(tr -d '\r' < "$O"); ERR=$(tr -d '\r' < "$E")
chk "a REPL decl cell is accepted and then callable" \
    "$(case "$OUT$ERR" in *42*) echo 0;; *) echo 1;; esac)" \
    "exit=$RC out=[$(echo "$OUT" | tr '\n' ' ' | cut -c1-50)]"

# NEGATIVE DIRECTION: :clear must ACTUALLY reset, not just print that it did. Asserted by
# the FAILURE that follows it -- if :clear were a no-op, `a` would still be defined.
printf 'var a = 1\n:clear\nprint("${a}")\n:quit\n' > "$W/repl_clear.txt"
( cd "$W" && timeout 420 "$ZEBRA" repl < "$W/repl_clear.txt" >"$O" 2>"$E" )
ERR=$(tr -d '\r' < "$E")
chk ":clear really resets the session (proven by the later failure)" \
    "$(case "$ERR" in *"undefined name"*) echo 0;; *) echo 1;; esac)" \
    "stderr=[$(echo "$ERR" | grep -i undefined | head -1 | cut -c1-50)]"

run build
chk "\`zebra build\` does not CRASH from a user directory (BUG-322)" \
    "$([ "$RC" != 3 ] && [ "$RC" != 124 ] && echo 0 || echo 1)" \
    "exit=$RC (3=panic, 124=hang: both are regressions)"
chk "...and says something rather than failing silently" \
    "$([ "$ERR_N" -gt 0 ] || [ "$OUT_N" -gt 0 ] && echo 0 || echo 1)" "stdout=$OUT_N stderr=$ERR_N"

# ---- the build EXECUTION path, which nothing else covers ---------------------------
# `b.run()` appears in the whole corpus ONLY inside comments saying it is deliberately not
# called -- both committed build fixtures are declarative BY INTENT. So the Build API's
# DECLARATION half is covered three times over and its EXECUTION half zero times, which is
# the hole BUG-327 lived in. This scaffolds a project whose build actually runs.
mkdir -p "$W/proj"
cat > "$W/proj/app.zbr" <<'ZBR'
def main()
    print("app ran")
ZBR
cat > "$W/proj/build.zbr" <<'ZBR'
def main()
    var b = Build.new()
    var app = b.exe("demo", "app.zbr")
    b.run()
ZBR
# `zebra build` -- the SUBCOMMAND, which is what a user runs and what sets
# ZEBRA_COMPILER for the generated build program. An earlier version of this leg ran
# `zebra build.zbr` (the file, as an ordinary program); that path does NOT export the
# variable, so the leg was measuring the unsupported invocation and failing on our
# own refusal message. Both are tested now, separately.
#
# A REAL BUILD, so the timeout is generous: it emits, then runs `zig build-exe`.
( cd "$W/proj" && timeout 420 "$ZEBRA" build >"$O" 2>"$E" </dev/null )
RC=$?; ERR=$(tr -d '\r' < "$E")

# PINNED: the build machinery calls std.fs.selfExePathAlloc, which Zig 0.16 REMOVED, so
# any build that actually executes cannot compile. Measured on BOTH paths -- this is not a
# delegation problem, the selfhost fails at the same line for the same reason. The
# declarative fixtures hid it because the bootstrap splices the preamble inline (eager Zig
# analysis) while the selfhost imports zebra_rt.zig (lazy), so an uncalled stale function
# is never analysed.
# PROMOTED 2026-09-01, the day BUG-327 was fixed. This was a pin asserting that a
# build which actually runs could not compile; it failed the gate the moment the bug
# was fixed, which is what the pin existed to do.
chk "a build that calls b.run() SUCCEEDS" \
    "$([ "$RC" = 0 ] && echo 0 || echo 1)" "exit=$RC  $(echo "$ERR" | tail -1)"
chk "...and produces the named binary" \
    "$([ -x "$W/proj/zig-out/bin/demo" ] || [ -x "$W/proj/zig-out/bin/demo.exe" ] && echo 0 || echo 1)" \
    "zig-out/bin: $(ls "$W/proj/zig-out/bin" 2>/dev/null | tr "\n" " ")"

# ── the two modes the bootstrap delegation was carrying (ported 2026-09-04) ──────────
# BOTH of these failed SILENTLY with exit 0 before the port, which is why they are
# asserted on OUTPUT and never on the exit code. They were invisible while `zebra build`
# delegated, because the bootstrap has both modes -- so these legs only became capable of
# failing on the day the subcommand went native.

# A build file that never calls b.run() must still build. Without CodeGen's build mode
# the file compiles, runs, exits 0 and produces NOTHING; the bootstrap builds the target
# from identical source, which is how the gap was measured.
mkdir -p "$W/proj_autorun"
cp "$W/proj/app.zbr" "$W/proj_autorun/app.zbr"
cat > "$W/proj_autorun/build.zbr" <<'ZBR'
def main()
    var b = Build.new()
    var app = b.exe("demo", "app.zbr")
ZBR
( cd "$W/proj_autorun" && timeout 420 "$ZEBRA" build >"$O" 2>"$E" </dev/null )
RC=$?
chk "a build with NO explicit b.run() still produces the binary (auto-run)" \
    "$([ -x "$W/proj_autorun/zig-out/bin/demo" ] || [ -x "$W/proj_autorun/zig-out/bin/demo.exe" ] && echo 0 || echo 1)" \
    "exit=$RC  zig-out/bin: $(ls "$W/proj_autorun/zig-out/bin" 2>/dev/null | tr "\n" " ")"

# `--list-targets` must LIST and must NOT build. Asserted in both directions on purpose:
# "prints something" passes against a run that also built, and "built nothing" passes
# against a run that printed nothing, so either alone is satisfied by the broken case.
mkdir -p "$W/proj_lt"
cp "$W/proj/app.zbr" "$W/proj_lt/app.zbr"
cp "$W/proj/build.zbr" "$W/proj_lt/build.zbr"
( cd "$W/proj_lt" && timeout 420 "$ZEBRA" build --list-targets >"$O" 2>"$E" </dev/null )
RC=$?; LT=$(grep '^{' "$O" 2>/dev/null | head -1)
chk "--list-targets emits the target JSON" \
    "$(case "$LT" in *'"targets"'*'"demo"'*) echo 0;; *) echo 1;; esac)" \
    "exit=$RC  got: ${LT:-<nothing on stdout>}"
chk "...and does NOT build while listing" \
    "$([ -e "$W/proj_lt/zig-out/bin/demo" ] || [ -e "$W/proj_lt/zig-out/bin/demo.exe" ] && echo 1 || echo 0)" \
    "zig-out/bin: $(ls "$W/proj_lt/zig-out/bin" 2>/dev/null | tr "\n" " ")"

# RUNNING THE BUILD FILE DIRECTLY. Until 2026-09-08 this got no ZEBRA_COMPILER and the
# contract was "refuse by name" (the fix for BUG-327 layer 2 was explicitly to refuse
# rather than guess). The contract CHANGED with the IDE work: every program the compiler
# runs now inherits ZEBRA_COMPILER (a program may itself invoke `zebra lsp`, `zebra
# build`, a nested compile), so `zebra build.zbr` is an ordinary supported run and must
# BUILD. This leg sat asserting the old refusal for a day and went red on the first
# machine to re-run the FAST tier (2026-09-09); the refusal path still exists and is
# still what a build program run with NO compiler in its environment sees, so that is
# what the second leg pins -- with the variable scrubbed and the program run by hand.
rm -rf "$W/proj/zig-out"
( cd "$W/proj" && timeout 420 "$ZEBRA" build.zbr >"$O" 2>"$E" </dev/null )
RC=$?; ERR=$(tr -d '\r' < "$E")
chk "running the build FILE directly builds (the child inherits ZEBRA_COMPILER)" \
    "$([ "$RC" = 0 ] && { [ -x "$W/proj/zig-out/bin/demo" ] || [ -x "$W/proj/zig-out/bin/demo.exe" ]; } && echo 0 || echo 1)" \
    "exit=$RC (124=hang would be BUG-327 layer 2 returning) zig-out/bin: $(ls "$W/proj/zig-out/bin" 2>/dev/null | tr "\n" " ")"

# The generated build PROGRAM with no compiler named in its environment must refuse by
# name, not guess (a guess is what produced BUG-327's infinite self-invocation). Emit it
# with --output-dir, build it with zig, run it with ZEBRA_COMPILER unset.
mkdir -p "$W/proj_bare"
cp "$W/proj/build.zbr" "$W/proj_bare/build.zbr"; cp "$W/proj/app.zbr" "$W/proj_bare/app.zbr"
( cd "$W/proj_bare" && timeout 420 "$ZEBRA" --emit-zig --output-dir out build.zbr >/dev/null 2>&1 \
  && cd out && timeout 420 zig build-exe build.zig -lc >/dev/null 2>&1 ) </dev/null
BARE="$W/proj_bare/out/build"; [ -x "$BARE" ] || BARE="$W/proj_bare/out/build.exe"
if [ -x "$BARE" ]; then
    ( cd "$W/proj_bare" && env -u ZEBRA_COMPILER timeout "$TMO" "$BARE" >"$O" 2>"$E" </dev/null )
    RC=$?; ERR=$(tr -d '\r' < "$E")
    chk "a build program with NO ZEBRA_COMPILER refuses by name rather than guessing" \
        "$([ "$RC" != 0 ] && [ "$RC" != 124 ] && case "$ERR" in *ZEBRA_COMPILER*) echo 0;; *) echo 1;; esac || echo 1)" \
        "exit=$RC (124=hang would be BUG-327 layer 2 returning) stderr=[$(echo "$ERR" | head -1)]"
else
    bad "a build program with NO ZEBRA_COMPILER refuses by name" "could not build the bare build program to test it"
fi

# ---- KNOWN-BROKEN, PINNED -----------------------------------------------------------
# PROMOTED from pins 2026-09-01, the day BUG-321 was fixed. The pins failed the gate the
# moment the bug was fixed, which is exactly what they existed to do; these are the real
# assertions they were placeholders for.
run --version
chk "\`--version\` writes to STDOUT and exits 0" \
    "$([ "$RC" = 0 ] && [ "$OUT_N" -gt 0 ] && [ "$ERR_N" = 0 ] && echo 0 || echo 1)" \
    "exit=$RC stdout=$OUT_N stderr=$ERR_N"

run --help
chk "\`--help\` writes to STDOUT and exits 0" \
    "$([ "$RC" = 0 ] && [ "$OUT_N" -gt 500 ] && echo 0 || echo 1)" \
    "exit=$RC stdout=$OUT_N"
chk "\`-h\` is the short form of --help" \
    "$(run -h; [ "$RC" = 0 ] && [ "$OUT_N" -gt 500 ] && echo 0 || echo 1)" "exit=$RC stdout=$OUT_N"

# THE ASYMMETRY IS THE POINT, so it is asserted rather than assumed: the SAME usage text
# shown because the invocation was WRONG must stay on stderr with a non-zero exit. A fix
# that simply moved everything to stdout would pass the two checks above and break this.
run
chk "usage shown for a BAD invocation stays on STDERR, non-zero" \
    "$([ "$RC" != 0 ] && [ "$OUT_N" = 0 ] && [ "$ERR_N" -gt 500 ] && echo 0 || echo 1)" \
    "exit=$RC stdout=$OUT_N stderr=$ERR_N"

# PROMOTED 2026-09-01, the day BUG-323 was fixed.
run --no-such-flag hello.zbr
chk "an unknown flag is REFUSED, not ignored" \
    "$([ "$RC" != 0 ] && echo 0 || echo 1)" "exit=$RC"
chk "...and the refusal NAMES the offending flag" \
    "$(case "$ERR" in *--no-such-flag*) echo 0;; *) echo 1;; esac)" \
    "stderr=[$(echo "$ERR" | head -1)]"
chk "...and prints the usage so the user can see what IS valid" \
    "$([ "$ERR_N" -gt 500 ] && echo 0 || echo 1)" "stderr=$ERR_N bytes"

# THE OTHER DIRECTION, so a fix that refuses EVERYTHING cannot pass: a real flag still
# works, and a typo of it does not. --TURBO is the case that matters -- it used to be
# silently ignored, handing you the opposite build with a successful-looking run.
run --turbo hello.zbr
chk "a VALID flag is still accepted" "$([ "$RC" = 0 ] && echo 0 || echo 1)" "exit=$RC"
run --TURBO hello.zbr
chk "a case-wrong flag is refused rather than silently ignored" \
    "$([ "$RC" != 0 ] && echo 0 || echo 1)" "exit=$RC"

echo
printf '  %s passed, %s pinned (known-broken), %s FAILED\n' "$pass" "$xfail" "$fail"
if [ "$fail" -eq 0 ]; then
    echo "cli-check: PASS — $pass assertion(s), $xfail pin(s)"
    exit 0
fi
[ "$xpass" -gt 0 ] && echo "  NOTE: $xpass pin(s) started passing — that is a FIX to promote, not a break." >&2
echo "cli-check: $fail FAILED" >&2
exit 1
