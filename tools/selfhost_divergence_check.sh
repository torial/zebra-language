#!/usr/bin/env bash
# selfhost_divergence_check.sh — THE COMPILER-SOURCES AGREEMENT GATE (`selfhost-div`).
#
# Both compilers are pointed at `selfhost/*.zbr` — the compiler's own sources — and
# required to AGREE on whether each one is acceptable.
#
# WHAT IT IS ACTUALLY FOR — stated narrowly, because the first draft of this comment
# overclaimed and the attempt to verify it is what showed the overclaim.
#
# This class of bug does NOT go undetected. When the selfhost wrongly refuses a module the
# compiler is built from, REGENERATION FAILS, so `rebuild.sh` already stops. What is
# missing is not detection, it is BLAME: the error names the SOURCE FILE, so it reads as
# "your code is wrong" when the truth is "your compiler is wrong". BUG-332 cost hours to
# because of exactly that misattribution, and was resolved only when someone thought to ask
# the other compiler by hand. This gate does that by default and says which side is at
# fault.
#
# A CONSEQUENCE WORTH KNOWING: this gate cannot be mutation-verified against BUG-332
# itself. Reverting that fix stops the compiler from regenerating, so no mutant binary can
# be built to test against — the attempt produced a broken tree and a FALSE PASS (the gate
# ran the last good binary). Use SELFDIV_SELF_OVERRIDE below to prove it can fire.
#
# WHY THE N-1 ANCHOR CANNOT REPLACE THIS. `divergence_check` compares against the newest
# `n1-anchor-*` tag, which answers "did this compiler LOSE something it used to do" —
# regressions. BUG-332 was never working: an N-1 selfhost rejects that code too. Only a
# genuinely INDEPENDENT implementation catches a long-standing wrong answer, and the
# bootstrap is the only one this tree has.
#
# THE GATED DIRECTION IS ASYMMETRIC, deliberately:
#   selfhost REFUSES + bootstrap ACCEPTS -> FAIL. Something the compiler is built from is
#     being rejected by the compiler. That is BUG-332's exact shape.
#   bootstrap REFUSES + selfhost ACCEPTS -> INFORMATIONAL. The bootstrap is FROZEN; the
#     selfhost is expected to outgrow it, and gating this would turn every new language
#     feature into a failure.
#
# IT PRINTS ITS OWN COVERAGE EVERY RUN, and that is the point rather than a courtesy.
# The bootstrap is frozen, so the share of the compiler it can still read only falls. When
# it falls far enough this gate has stopped being a reference and the bootstrap can be
# deleted — as a decision with a number attached, instead of when someone gets tired of it.
# Coverage was 12/12 on 2026-09-05, the day this landed.
#
# DAILY TIER on purpose. It runs both compilers over twelve non-trivial modules; it has no
# place in the edit loop, and the class of bug it catches is long-standing rather than
# freshly introduced, so catching it a day later costs nothing.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
# Test hooks. Used by no tier — they exist so this gate can be SHOWN to go red, which
# the bug it was built for cannot demonstrate (see above).
SELF="${SELFDIV_SELF_OVERRIDE:-$REPO/zig-out/bin/zebra.exe}"
BOOT="${SELFDIV_BOOT_OVERRIDE:-$REPO/zig-out/bin/zebra-bootstrap.exe}"
W="$(mktemp -d "${TMPDIR:-/tmp}/zbr_selfdiv.XXXXXX")"

# IT MUST SNAPSHOT THE GENERATED .zig, and this is not defensive tidiness -- it is the
# only reason the gate is usable. BUG-325: `--emit-zig --output-dir` REWRITES DEPENDENCY
# MODULES IN PLACE, so simply asking the compiler about selfhost/Ast.zbr rewrites eleven
# generated files beside it. The first version of this gate did that on every run and left
# a half-updated tree behind; the symptom is `doctor` refusing with "zebra.exe was NOT
# built from the generated Zig now on disk", several minutes after the gate reported PASS,
# with nothing to connect the two. `-c` is no escape: it writes too, and the bootstrap
# cannot use it on a module with no `main`.
#
# Same shape as bootstrap_check.sh's /tmp/bs-pre snapshot, and for the same reason.
SNAP="$W/pre"
mkdir -p "$SNAP"
cp selfhost/*.zig "$SNAP/" 2>/dev/null
_snap_n=$(ls "$SNAP" 2>/dev/null | wc -l | tr -d ' ')
restore_tree() {
  if [ "${_snap_n:-0}" -gt 0 ]; then
    cp "$SNAP"/*.zig selfhost/ 2>/dev/null
  fi
  rm -rf "$W"
}
trap restore_tree EXIT

die() { printf 'selfhost-div: REFUSING to report — %s\n' "$1"; exit 2; }

[ -x "$SELF" ] || die "zebra.exe not built"
# An empty snapshot means the restore below cannot undo what this gate is about to
# do to the tree. Refuse rather than corrupt it.
[ "${_snap_n:-0}" -ge 8 ] || die "snapshotted only ${_snap_n:-0} generated .zig — refusing to run, the restore would not cover the damage"
if [ ! -x "$BOOT" ]; then
  # The bootstrap is the whole reference. Missing it makes every comparison vacuous, and a
  # vacuous run must not look like agreement.
  die "zebra-bootstrap.exe not present — this gate IS the two-implementation comparison"
fi

# The module list is DERIVED from bootstrap_check.sh's FILES — the authority on what the
# compiler is BUILT FROM — not written down here. A module added to the compiler and not to
# this list would be silently uncompared, which is how the original gap existed.
#
# SCOPED TO THE BUILT MODULES ON PURPOSE. Globbing selfhost/*.zbr also picks up ten aux and
# phase-test files, and on this gate's first run one of them (pipeline_test.zbr) fired: it
# carries call sites stale behind an API change, so the SELFHOST correctly refuses it while
# the bootstrap — which does not arity-check there — accepts. That is the reverse of the
# bug this gate exists for, and gating it would mean a red board for the selfhost being
# RIGHT. The aux files are real debt, but they are a hygiene question, not an agreement one.
FILES_LINE=$(grep -m1 '^FILES=(' "$REPO/tools/bootstrap_check.sh")
[ -n "$FILES_LINE" ] || die "could not read the FILES list from bootstrap_check.sh"
MODLIST=$(printf '%s' "$FILES_LINE" | sed 's/^FILES=(//; s/)$//')
MODULES=()
for _m in $MODLIST; do
  [ -f "selfhost/$_m.zbr" ] || die "FILES names $_m but selfhost/$_m.zbr does not exist"
  MODULES+=("selfhost/$_m.zbr")
done
n=${#MODULES[@]}
[ "$n" -ge 8 ] || die "only $n compiler modules derived — the derivation collapsed"

regress=""; advance=""; agree=0
for src in "${MODULES[@]}"; do
  base="$(basename "$src" .zbr)"
  # Each compiler is asked the question it can answer without a `main`: emit. The two take
  # DIFFERENT flags for it -- the bootstrap has no --output-dir and writes to stdout -- and
  # conflating them is how an earlier attempt scored every file as a difference.
  timeout 300 "$SELF" --emit-zig --output-dir "$W/self" "$src" >"$W/$base.self" 2>&1
  s_rc=$?
  timeout 300 "$BOOT" --emit-zig "$src" >"$W/$base.boot.zig" 2>"$W/$base.boot"
  b_rc=$?
  if [ $s_rc -ne 0 ] && [ $b_rc -eq 0 ]; then
    regress="$regress $base"
  elif [ $s_rc -eq 0 ] && [ $b_rc -ne 0 ]; then
    advance="$advance $base"
  else
    agree=$((agree+1))
  fi
done

b_ok=$(( agree + $(printf '%s' "$regress" | wc -w) ))
echo "selfhost-div: $n modules; agree $agree; bootstrap can still read $b_ok/$n"
if [ -n "$advance" ]; then
  echo "  informational — the selfhost has outgrown the frozen bootstrap here:$advance"
  echo "  (expected and NOT gated; this number rising is the bootstrap's coverage decaying)"
fi

if [ -n "$regress" ]; then
  echo "  ✗ THE COMPILER REFUSES ITS OWN SOURCES, and the bootstrap accepts them:$regress"
  echo "    This is BUG-332's shape. The source is not the suspect; the selfhost is."
  for m in $regress; do
    echo "    -- $m --"
    grep -E 'error' "$W/$m.self" | head -3 | sed 's/^/       /'
  done
  exit 1
fi
echo "selfhost-div: PASS — both compilers agree on every module they can both read"
exit 0
