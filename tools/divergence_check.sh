#!/usr/bin/env bash
# divergence_check.sh — the independent witness for selfhost-vs-bootstrap DIVERGENCE.
#
# The existing gates (round-trip, smoke, compile_check) all EMIT with one compiler,
# so a case where the self-hosted compiler DISAGREES with the bootstrap is invisible
# to them — round-trip only proves the selfhost is self-consistent, not that it
# matches the reference. This harness closes that blind spot: it emits every corpus
# file with BOTH `zebra-bootstrap.exe` and `zebra.exe`, compile-checks each output
# with `zig build-exe -fno-emit-bin`, and reports where the two disagree.
#
#   SELFHOST GAP  = bootstrap handles it, selfhost does not  (selfhost lags — the
#                   File.listDir / Math.log / List(float32) class; matters most as
#                   the bootstrap sunsets toward 1.0).
#   BOOTSTRAP GAP = selfhost handles it, bootstrap does not  (bootstrap lags — e.g.
#                   SIMD / f32x8, which the bootstrap never learned).
#
# Bootstrap emits to STDOUT (no --output-dir), so it can only materialize a single
# root file. Files with a local `use` (multi-module) are therefore selfhost-only
# here and reported separately, not as divergences.
#
# Usage:
#   bash tools/divergence_check.sh                # test/ + examples/
#   bash tools/divergence_check.sh --only json    # names containing 'json'
#   JOBS=4 bash tools/divergence_check.sh         # parallelism (default 4)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/zbr-divergence"
BOOT="$REPO/zig-out/bin/zebra-bootstrap.exe"
SELF="$REPO/zig-out/bin/zebra.exe"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

# emit+compile one file with one compiler; echo a status token.
#   EMITFAIL | NOMAIN | CPASS | CFAIL
emit_and_check() { # $1=compiler $2=mode(boot|self) $3=absfile $4=workdir
  local zebra="$1" mode="$2" f="$3" wdir="$4"
  local name; name=$(basename "$f" .zbr)
  local main="$wdir/$name.zig"
  rm -rf "$wdir"; mkdir -p "$wdir"
  if [ "$mode" = boot ]; then
    "$zebra" --emit-zig "$f" > "$main" 2>/dev/null || { echo EMITFAIL; return; }
  else
    "$zebra" --emit-zig "$f" --output-dir "$wdir" >/dev/null 2>&1 || { echo EMITFAIL; return; }
  fi
  [ -s "$main" ] || { echo EMITFAIL; return; }
  grep -q "pub fn main" "$main" || { echo NOMAIN; return; }
  if zig build-exe -fno-emit-bin -lc "$main" >/dev/null 2>&1; then echo CPASS; else echo CFAIL; fi
}

if [ "${1:-}" = "--worker" ]; then
  f="$2"; name=$(basename "$f" .zbr)
  # multi-module (has a local `use`) → bootstrap can't materialize deps via stdout.
  if grep -qE '^use ' "$f"; then
    s=$(emit_and_check "$SELF" self "$f" "$OUT/ws-$name")
    echo "$name|MULTI|$s"; exit 0
  fi
  b=$(emit_and_check "$BOOT" boot "$f" "$OUT/wb-$name")
  s=$(emit_and_check "$SELF" self "$f" "$OUT/ws-$name")
  echo "$name|$b|$s"; exit 0
fi

ONLY=""
while [ $# -gt 0 ]; do case "$1" in --only) ONLY="${2:-}"; shift 2;; *) shift;; esac; done
JOBS="${JOBS:-4}"; mkdir -p "$OUT"

files=$(ls "$REPO"/test/*.zbr "$REPO"/examples/*.zbr 2>/dev/null | sort -u)
worklist=""
for f in $files; do
  name=$(basename "$f" .zbr)
  [ -n "$ONLY" ] && { case "$name" in *"$ONLY"*) ;; *) continue;; esac; }
  worklist="$worklist$f"$'\n'
done

results=$(printf '%s' "$worklist" | grep -v '^$' \
          | xargs -P"$JOBS" -I{} bash "$0" --worker {})

# classify
self_gap=""; boot_gap=""; agree_fail=""; multi_selffail=""
np=0; naf=0; nsg=0; nbg=0; nnomain=0; nmulti=0
while IFS='|' read -r name b s; do
  [ -z "$name" ] && continue
  if [ "$b" = MULTI ]; then
    nmulti=$((nmulti+1))
    [ "$s" = CFAIL ] || [ "$s" = EMITFAIL ] && multi_selffail="$multi_selffail $name($s)"
    continue
  fi
  # normalize NOMAIN (library) — skip from divergence accounting
  if [ "$b" = NOMAIN ] || [ "$s" = NOMAIN ]; then nnomain=$((nnomain+1)); continue; fi
  b_ok=0; s_ok=0
  [ "$b" = CPASS ] && b_ok=1
  [ "$s" = CPASS ] && s_ok=1
  if [ "$b_ok" = 1 ] && [ "$s_ok" = 1 ]; then np=$((np+1))
  elif [ "$b_ok" = 1 ] && [ "$s_ok" = 0 ]; then nsg=$((nsg+1)); self_gap="$self_gap $name(self=$s)"
  elif [ "$b_ok" = 0 ] && [ "$s_ok" = 1 ]; then nbg=$((nbg+1)); boot_gap="$boot_gap $name(boot=$b)"
  else naf=$((naf+1)); agree_fail="$agree_fail $name"
  fi
done <<< "$results"

echo "═══ selfhost ↔ bootstrap divergence ═══ (jobs=$JOBS${ONLY:+, only=$ONLY})"
echo "single-module files: $np agree-pass · $naf agree-fail · $nnomain library(no-main)"
echo "multi-module (selfhost-only, bootstrap N/A): $nmulti"
echo
echo "▶ SELFHOST GAPS ($nsg) — bootstrap OK, selfhost fails (selfhost lags):"
[ -n "$self_gap" ] && echo "   $self_gap" || echo "   (none)"
echo
echo "▶ BOOTSTRAP GAPS ($nbg) — selfhost OK, bootstrap fails (bootstrap lags):"
[ -n "$boot_gap" ] && echo "   $boot_gap" || echo "   (none)"
echo
echo "· agree-fail (both fail — genuinely-broken test or both lag): $agree_fail"
[ -n "$multi_selffail" ] && { echo; echo "· multi-module selfhost failures (not A/B-checkable): $multi_selffail"; }
