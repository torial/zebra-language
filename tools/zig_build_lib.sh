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

# Run `zig build-exe`, retrying ONLY an infra failure. Sets ZBR_RC and ZBR_RETRIES.
# Returns zig's exit code, so callers read it exactly as they read the bare command.
#
# Callers MUST report ZBR_RETRIES -- every run, zero included. A retry that is invisible
# is a gate quietly getting slower and less honest; a rising rate is the early warning
# that something in the environment changed. Same discipline as output_sweep's transients.
zbr_zig_build() {         # $1 = main.zig   $2 = stderr file   [$3 = timeout secs]
  local main="$1" berr="$2" tmo="${3:-90}" attempt=1
  ZBR_RETRIES=0
  while :; do
    timeout "$tmo" zig build-exe -fno-emit-bin -lc "$main" >/dev/null 2>"$berr"
    ZBR_RC=$?
    [ "$ZBR_RC" -eq 0 ] && return 0
    if [ "$attempt" -lt 3 ] && zbr_zig_infra_error "$berr"; then
      ZBR_RETRIES=$((ZBR_RETRIES + 1)); attempt=$((attempt + 1)); continue
    fi
    return "$ZBR_RC"
  done
}
