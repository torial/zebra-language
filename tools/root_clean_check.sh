#!/usr/bin/env bash
# root_clean_check.sh -- the repo root holds no compiled executables.
#
# 134 fixture .exe/.pdb pairs sat in the root on 2026-09-09: 120 from one spill on
# 08-05, the rest from `zebra debug`, which built its binary in the cwd until that day.
# They are gitignored, so nothing noticed. This gate notices. Static tier: no compiler.
#
# Clean with `bash tools/tidy.sh --clean` (it sweeps the root as of 2026-09-09).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
n=$(ls -1 ./*.exe ./*.pdb ./*.obj 2>/dev/null | wc -l | tr -d ' ')
if [[ "$n" -gt 0 ]]; then
    echo "root-clean: $n compiled artifact(s) in the repo root (bash tools/tidy.sh --clean):" >&2
    ls -1 ./*.exe ./*.pdb ./*.obj 2>/dev/null | head -8 >&2
    exit 1
fi
echo "root-clean: 0 compiled artifact(s) in the repo root"
