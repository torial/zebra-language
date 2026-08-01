#!/usr/bin/env bash
# kill_orphans.sh — clear compiler processes holding a lock on THIS tree's zig-out,
# and nothing else.
#
# WHY THIS EXISTS
# ---------------
# `rebuild.sh` and `doctor.sh --fix` both used to do:
#
#     taskkill //F //IM zebra.exe
#
# which is MACHINE-WIDE. It kills every zebra.exe on the box, including:
#
#   * a mutation run in `C:\Projects\zebra-mutants` (a deliberately isolated worktree,
#     whose whole purpose is not to be affected by what happens here);
#   * a PARALLEL SESSION's build in another checkout — this repo regularly has two agents
#     working in it at once;
#   * anything Sean is running by hand.
#
# The victim does not get an explanation. It sees a compiler that vanished, or a
# regeneration that failed for no visible reason — and in a harness, "regeneration
# failed" is scored as a RESULT. Observed 2026-08-01: running `rebuild.sh` in the main
# checkout killed the bootstrap belonging to a mutation run in the sibling worktree,
# mid-mutant. That is a wrong number manufactured by an unrelated tool, which is the
# exact class docs/testing_strategy.md 3b is about.
#
# The lock this is meant to clear (`AccessDenied` on zig-out/bin/compiler_rt.dll) is only
# ever held by a process running FROM this tree. Filtering by executable path loses
# nothing and stops the collateral damage.
#
#   bash tools/kill_orphans.sh            # scope: the repo this script lives in
#   bash tools/kill_orphans.sh --count    # report only, kill nothing
#   bash tools/kill_orphans.sh --root DIR # scope: DIR (used by the mutant worktree)
#
# Prints one line per process killed. Exit 0 always — having nothing to kill is normal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNT_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count) COUNT_ONLY=1 ;;
        --root)  ROOT="$2"; shift ;;
        *) echo "kill_orphans: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done

# Git Bash gives /c/... ; Win32_Process reports C:\... . Normalise to the Windows form
# and lowercase it, because path comparison here is case-insensitive in practice.
WIN_ROOT="$(cd "$ROOT" && pwd -W 2>/dev/null || echo "$ROOT")"
WIN_ROOT="$(echo "$WIN_ROOT" | tr '/' '\\' | tr 'A-Z' 'a-z')"

NAMES="zebra.exe zebra-bootstrap.exe zebra-selfhost.exe zebra-selfhost-B.exe zig.exe"
FILTER=""
for n in $NAMES; do
    FILTER="${FILTER}${FILTER:+ or }Name='$n'"
done

# PowerShell is used for exactly one thing here — Win32_Process exposes ExecutablePath,
# and neither tasklist nor taskkill can filter on it. wmic is deprecated and returned
# nothing on this machine when tried.
listing=$(powershell -NoProfile -Command \
    "Get-CimInstance Win32_Process -Filter \"$FILTER\" | ForEach-Object { \"\$(\$_.ProcessId)|\$(\$_.ExecutablePath)\" }" \
    2>/dev/null | tr -d '\r')

killed=0
skipped=0
while IFS='|' read -r pid path; do
    [[ -z "${pid:-}" ]] && continue
    lc="$(echo "${path:-}" | tr 'A-Z' 'a-z')"
    case "$lc" in
        "$WIN_ROOT"*)
            if [[ $COUNT_ONLY -eq 1 ]]; then
                echo "  would kill $pid  $path"
            else
                taskkill //F //PID "$pid" >/dev/null 2>&1 \
                    && echo "  killed orphaned $(basename "${path:-pid $pid}") (pid $pid)"
            fi
            killed=$((killed + 1))
            ;;
        *)
            # Belongs to another tree — a sibling worktree, a parallel session, or Sean.
            # Naming it is the point: silence here is what made the old behaviour look
            # like an unrelated failure to whoever owned the process.
            echo "  leaving alone (not this tree): $path (pid $pid)"
            skipped=$((skipped + 1))
            ;;
    esac
done <<< "$listing"

if [[ $killed -eq 0 && $skipped -eq 0 ]]; then
    echo "  no compiler processes running"
fi
exit 0
