#!/usr/bin/env bash
# ONE definition of "zig failed for a reason that is not about OUR code".
#
# Sourced, never executed. Three gates run `zig build-exe` over emitted output and each
# classified ANY non-zero exit as "our emitted Zig is bad": full_sweep.sh (CFAIL),
# divergence_check.sh (CFAIL -> counted as a SELFHOST GAP), compile_check.sh (FAIL).
#
# BUG-302 is what that costs. Zig can fail because it could not read ITS OWN STDLIB:
#
#   .../.zvm/0.16.0/lib/std/debug.zig:1:1: error: unable to load 'debug.zig': Unexpected
#   .../.zvm/0.16.0/lib/std/std.zig:71:27: note: file imported here
#
# `Unexpected` is zig's catch-all for an unmapped OS error; on Windows it shows up under
# concurrent builds sharing the stdlib. The failing path is INSIDE THE ZIG INSTALLATION,
# so our program was never compiled -- and "emitted bad Zig" is a claim about code zig
# never read. Measured 2026-08-22: of 20 CFAILs in one full_sweep run, 19 were genuine
# errors in our output and the single infra error was exactly the file that had
# "regressed" against the baseline.
#
# It lives here rather than being pasted three times because the PREDICATE is the thing
# that must not drift -- the same argument corpus_ls.sh makes for the corpus, and the
# lesson isZigKeyword paid for with a hand-maintained list guarding against a bug caused
# by a hand-maintained list.
#
# Controlled by tools/zz_bug302_control, which drives the REAL failure through a stub zig
# (fails once with the verbatim error, then succeeds) rather than mutating a marker.

# Is this stderr an infrastructure failure rather than a verdict on our code?
#
# Deliberately NOT matched: `unable to load ...: FileNotFound`. That one means a dep of
# OURS was never emitted, it is deterministic, and full_sweep already buckets it as
# DEPMISS. Retrying it would burn three builds to reach the same answer.
zbr_zig_infra_error() {   # $1 = stderr file
  grep -qE "unable to load .*: (Unexpected|AccessDenied|SharingViolation|Busy)" "$1"
}

# ── The VERDICT CACHE (2026-09-26) ──────────────────────────────────────────────────────
# zig's answer to `build-exe -fno-emit-bin` is a pure function of what it reads: the
# emitted files in the program's directory, the zig installation, and the flags. So the
# verdict is cached under a hash of exactly those, and a later run whose emitted files are
# byte-identical reuses it without starting zig. A compiler change typically alters the
# emit of a handful of files; the rest of full_sweep / compile_check / divergence (whose
# N-1 anchor side never changes at all, and whose current side is what full_sweep just
# checked) becomes a lookup. It was ~60 of the daily's 110 minutes.
#
# What keeps it honest:
#   * the key covers EVERY file beside the root (deps, zebra_rt.zig), the root's name, the
#     flags, and `zig version` -- a new zig, a changed runtime or a changed dep all miss;
#   * an INFRA failure (BUG-302) and a timeout are never cached -- only zig's own verdict;
#   * a cached failure restores zig's stderr, so the evidence a gate keeps is unchanged;
#   * every lookup is logged when ZBR_VCACHE_LOG is set, and gates print hit/miss counts
#     on their summary line, zero included -- a cache that is silently serving answers is
#     how a gate stops looking;
#   * ZBR_VCACHE=0 turns it off (a fresh measurement), and tools/verdict_cache_check.sh
#     attacks it with a stub zig: a changed dep, a new zig version and an infra failure
#     must each MISS, and a cached failure must come back with its stderr.
ZBR_VCACHE_DIR="${ZBR_VCACHE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.zig-cache/zbr-verdicts}"
export ZBR_VCACHE_DIR

# `zig version` is read once per gate (exported), not per lookup: 84 ms x ~1000 lookups.
# An explicit ZBR_ZIG_VERSION wins, so the control can play a new zig.
if [ -z "${ZBR_ZIG_VERSION:-}" ]; then ZBR_ZIG_VERSION="$(zig version 2>/dev/null)"; fi
export ZBR_ZIG_VERSION

zbr_verdict_key() {       # $1 = main.zig  -> echoes a hex key, or nothing if it cannot
  local main="$1" dir root zv sums
  dir="${main%/*}"; root="${main##*/}"
  [ "$dir" = "$main" ] && dir="."
  zv="${ZBR_ZIG_VERSION:-}"
  [ -n "$zv" ] || zv="$(zig version 2>/dev/null)"
  [ -n "$zv" ] || return 1
  # Every regular file under the program's directory except the gate's own *.err
  # evidence, in byte order (LC_ALL=C: a sort is a property of a collation too -- H11).
  # Two processes, not six: this runs once per file per gate.
  sums="$(cd "$dir" && LC_ALL=C; shopt -s globstar nullglob dotglob
          fs=(); for f in **; do [ -f "$f" ] || continue
                   case "$f" in *.err|.zig-cache/*|zig-cache/*) continue;; esac; fs+=("$f"); done
          [ ${#fs[@]} -gt 0 ] && sha256sum -- "${fs[@]}")" || return 1
  [ -n "$sums" ] || return 1
  local k
  k="$(printf 'zbr-verdict v1\nzig %s\nflags build-exe -fno-emit-bin -lc\nroot %s\n%s\n' "$zv" "$root" "$sums" | sha256sum)"
  printf '%s\n' "${k:0:64}"
}

# Run `zig build-exe`, retrying ONLY an infra failure. Sets ZBR_RC and ZBR_RETRIES.
# Returns zig's exit code, so callers read it exactly as they read the bare command.
#
# Callers MUST report ZBR_RETRIES -- every run, zero included. A retry that is invisible
# is a gate quietly getting slower and less honest; a rising rate is the early warning
# that something in the environment changed. Same discipline as output_sweep's transients.
zbr_zig_build() {         # $1 = main.zig   $2 = stderr file   [$3 = timeout secs]
  local main="$1" berr="$2" tmo="${3:-90}" attempt=1 key="" cdir=""
  ZBR_RETRIES=0
  if [ "${ZBR_VCACHE:-1}" != 0 ]; then
    key="$(zbr_verdict_key "$main")"
    if [ -n "$key" ]; then
      cdir="$ZBR_VCACHE_DIR/${key:0:2}/$key"
      if [ -f "$cdir/rc" ]; then
        ZBR_RC="$(cat "$cdir/rc")"
        cp "$cdir/stderr" "$berr" 2>/dev/null || : > "$berr"
        [ -n "${ZBR_VCACHE_LOG:-}" ] && echo hit >> "$ZBR_VCACHE_LOG"
        return "$ZBR_RC"
      fi
    fi
  fi
  while :; do
    timeout "$tmo" zig build-exe -fno-emit-bin -lc "$main" >/dev/null 2>"$berr"
    ZBR_RC=$?
    [ "$ZBR_RC" -eq 0 ] && break
    if [ "$attempt" -lt 3 ] && zbr_zig_infra_error "$berr"; then
      ZBR_RETRIES=$((ZBR_RETRIES + 1)); attempt=$((attempt + 1)); continue
    fi
    break
  done
  if [ -n "$key" ]; then
    [ -n "${ZBR_VCACHE_LOG:-}" ] && echo miss >> "$ZBR_VCACHE_LOG"
    # Only zig's own verdict is worth keeping: not an infra failure, not a timeout.
    if [ "$ZBR_RC" -ne 124 ] && ! { [ "$ZBR_RC" -ne 0 ] && zbr_zig_infra_error "$berr"; }; then
      local tmp="$cdir.tmp.$$"
      # Written aside, then renamed into place. A worker that loses the race to the same
      # key discards its copy (mv onto an existing dir would NEST it, not replace it).
      if mkdir -p "$tmp" 2>/dev/null && cp "$berr" "$tmp/stderr" 2>/dev/null && echo "$ZBR_RC" > "$tmp/rc"; then
        mkdir -p "$(dirname "$cdir")"
        if [ -e "$cdir" ]; then rm -rf "$tmp"; else mv "$tmp" "$cdir" 2>/dev/null || rm -rf "$tmp"; fi
      else
        rm -rf "$tmp"
      fi
    fi
  fi
  return "$ZBR_RC"
}

# Summary helper for gates: "zig-verdict-cache: H hit / M miss" from a log file (0/0 if none).
zbr_vcache_summary() {    # $1 = log file
  local h=0 m=0
  if [ -f "$1" ]; then h=$(grep -c '^hit$' "$1"); m=$(grep -c '^miss$' "$1"); fi
  if [ "${ZBR_VCACHE:-1}" = 0 ]; then echo "zig-verdict-cache: off"; else echo "zig-verdict-cache: $h hit / $m miss"; fi
}
export -f zbr_verdict_key zbr_zig_build zbr_zig_infra_error zbr_vcache_summary
