#!/usr/bin/env bash
# Which stdlib RUNTIME HELPERS can the bootstrap emit that the selfhost cannot?
#
# This is the shape BUG-242's writer half had: `_csv_writer_init` / `_csv_write_row` /
# `_csv_build` existed in the preamble AND in src/CodeGen.zig, but no selfhost source
# ever emitted them, so selfhost-compiled programs could not reach the code at all --
# which is also why its Zig-0.16 migration was never done. Unreachable code does not
# get migrated and does not get found.
#
# Compares the RUNTIME SURFACE rather than emitter FUNCTION NAMES. A name diff
# over-reports by ~30, because the selfhost dispatches most stdlib methods inline in
# its `branch recv_t` instead of via a `def genXxxMethod`.
#
# VALIDATED NON-CIRCULARLY. Run against the commit BEFORE the BUG-242 fix it lists exactly
# `_csv_writer_init`, `_csv_write_row`, `_csv_build`; run after, zero. It re-derives a real
# defect on the tree that shipped it, which is the only evidence that a clean result here
# means anything.
#
# RESULT 2026-08-03: 73 helpers, of which 72 are `_stub_*` / `_gui_*` — expected and NOT a
# finding, since `--gui-backend=*` delegates to the bootstrap by design. Exactly ONE real
# entry remains:
#
#     _build_auto_run   the bootstrap appends `_build_auto_run();` to the end of top-level
#                       main in build-script mode (src/CodeGen.zig:4775, :6549). No selfhost
#                       source emits it. Narrow, but it is the same shape as the Csv writer.
#
# NOT A GATE, deliberately. Being unreachable is not automatically a defect — the GUI stubs
# prove that — so this reports and a person decides. Gating it would mean encoding "which
# absences are fine", which is the kind of list that rots.
#
# Usage: unreachable_runtime.sh [REV]   -- REV compares an older selfhost (for controls)
set -uo pipefail
REPO="/c/Projects/zebra-language"
REV="${1:-}"

cd "$REPO" || exit 2

PREAMBLE="$(cat selfhost/stdlib_preamble.zig)"
BOOT="$(cat src/CodeGen.zig src/Builtins.zig 2>/dev/null)"
if [[ -n "$REV" ]]; then
    SELF="$(git show "$REV:selfhost/CodeGen.zbr" 2>/dev/null; git show "$REV:selfhost/CgHelpers.zbr" 2>/dev/null)"
else
    SELF="$(cat selfhost/CodeGen.zbr selfhost/CgHelpers.zbr)"
fi

# CONTROL 1: the three inputs must be non-empty. An empty SELF would report the entire
# runtime as unreachable -- a spectacular false alarm that looks like a finding.
if [[ -z "$PREAMBLE" || -z "$BOOT" || -z "$SELF" ]]; then
    echo "REFUSING TO REPORT: preamble=${#PREAMBLE} bootstrap=${#BOOT} selfhost=${#SELF} bytes." >&2
    echo "One input failed to load; any verdict here would be fiction." >&2
    exit 2
fi

# The runtime surface: `pub fn _name(` in the preamble.
mapfile -t HELPERS < <(printf '%s\n' "$PREAMBLE" | grep -oE '^pub fn (_[a-z0-9_]+)\(' | sed 's/^pub fn //; s/($//; s/(//' | sort -u)

# CONTROL 2: a name that is definitely PRESENT must classify as present, and a name that
# is definitely ABSENT must classify as absent. Derived at runtime, not pinned to a known
# gap -- a control pinned to a gap fails on the day you fix it.
probe_present="_csv_parse"           # emitted by both, today and historically
probe_absent="_zz_definitely_not_a_real_helper"
grep -qF -- "$probe_present" <<<"$SELF"  || { echo "CONTROL FAILED: '$probe_present' not found in selfhost source; the scan cannot see." >&2; exit 2; }
grep -qF -- "$probe_absent"  <<<"$SELF"  && { echo "CONTROL FAILED: absent probe matched; the matcher is broken." >&2; exit 2; }

echo "runtime helpers in preamble: ${#HELPERS[@]}"
echo ""
echo "EMITTED BY BOOTSTRAP, NEVER BY SELFHOST:"
n=0
for h in "${HELPERS[@]}"; do
    if grep -qF -- "\"$h" <<<"$BOOT" || grep -qF -- "$h(" <<<"$BOOT"; then
        if ! grep -qF -- "$h" <<<"$SELF"; then
            echo "    $h"
            n=$((n + 1))
        fi
    fi
done
echo ""
echo "total: $n"
