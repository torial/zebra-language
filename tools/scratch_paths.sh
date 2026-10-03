#!/usr/bin/env bash
# Per-checkout prefix for the round-trip's scratch directories (BUG-521). SOURCE it after
# REPO is set; it defines ZBR_BS, and the tools spell their scratch as "${ZBR_BS}-zig",
# "${ZBR_BS}-pre", "${ZBR_BS}-A", ... where they used to spell /tmp/bs-zig, /tmp/bs-pre.
#
# Why: those were ONE set of paths for every checkout on the machine. On 2026-10-03 a
# rebuild in the main tree cleared /tmp/bs-zig underneath a rebuild in a worktree, and the
# worktree's failure path then RESTORED its selfhost/*.zig from /tmp/bs-pre -- the main
# tree's snapshot. Another checkout's generated files, put back silently by the step whose
# job is to leave the tree as it found it. This repo routinely has a second agent and
# isolated worktrees, so concurrent rebuilds are the normal case, not an accident.
#
# Keyed on the checkout's real path: a worktree, a second clone and the main tree never
# share a directory, and the same checkout always finds its own (so doctor/tidy can still
# clear what a killed run left behind).
if [ -z "${REPO:-}" ]; then
    echo "scratch_paths.sh: REPO is not set -- source this after REPO=..." >&2
    exit 2
fi
ZBR_BS="/tmp/bs-$(cd "$REPO" && pwd -P | md5sum | cut -c1-8)"   # hazard-ok:H12 the per-checkout prefix itself
