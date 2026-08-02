#!/usr/bin/env bash
# tidy.sh — report what is lying around this tree that should not be, and clear only what
# is unambiguously mine to clear.
#
# WHY
# ---
# Untracked files in `test/` and `examples/` used to change what the heavy gates measured,
# because every one of them globbed the filesystem. That is fixed (tools/corpus_ls.sh),
# so a stray file is now a tidiness question rather than a correctness one -- but strays
# still cost real attention: they clutter `git status`, they get mistaken for work in
# progress, and after a few sessions nobody remembers whether `zz_setprobe.zbr` mattered.
#
# THE SAFETY RULE, and it is the whole design:
#
#     --clean deletes ONLY files matching a known-scratch pattern.
#     Everything else is LISTED and never touched, no matter how junk-shaped it looks.
#
# An untracked `.zbr` in `test/` might be a probe someone abandoned, or it might be the
# fixture they are three minutes from committing. This tool cannot tell, so it does not
# guess -- it reports and leaves the decision with a person. A cleanup tool that deletes
# someone's unfinished work once will never be run again, which makes it worse than no
# cleanup tool at all.
#
#   bash tools/tidy.sh            # report only
#   bash tools/tidy.sh --clean    # remove known-scratch; still only reports the rest
#
# Exit 0 always. This is housekeeping, not a gate: nothing here makes results untrustworthy
# (that is what tools/doctor.sh is for), so it must never block anything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

CLEAN=0
[[ "${1:-}" == "--clean" ]] && CLEAN=1

hdr() { printf '\n\033[1m%s\033[0m\n' "$1"; }
dim() { printf '  \033[90m%s\033[0m\n' "$1"; }

# Known scratch: named by a convention that means "throwaway", or produced by our own
# tools. Each pattern is here because something in this repo creates it.
is_scratch() {
    case "$(basename "$1")" in
        zz_*)             return 0 ;;   # the agreed scratch prefix
        _mut_*)           return 0 ;;   # tools/mutation_check.py per-run scratch
        probe_*)          return 0 ;;   # ad-hoc probes
        _rebuild_probe*)  return 0 ;;   # tools/rebuild.sh hello-world check
        *)                return 1 ;;
    esac
}

total_scratch=0; total_other=0; removed=0

hdr "untracked files in gated directories"
mapfile -t untracked < <(git ls-files --others --exclude-standard -- \
    test examples selfhost IDE 2>/dev/null)
if [[ ${#untracked[@]} -eq 0 ]]; then
    dim "none"
else
    for f in "${untracked[@]}"; do
        if is_scratch "$f"; then
            total_scratch=$((total_scratch + 1))
            if [[ $CLEAN -eq 1 ]]; then
                rm -f "$f" && { printf '  removed  %s\n' "$f"; removed=$((removed + 1)); }
            else
                printf '  scratch  %s\n' "$f"
            fi
        else
            total_other=$((total_other + 1))
            printf '  \033[33mKEPT\033[0m     %s\n' "$f"
        fi
    done
fi

hdr "tool scratch outside the tree"
for d in /tmp/bs-zig /tmp/bs-pre /tmp/bs-A /tmp/bs-B "$REPO/.selfcheck_tmp"; do
    if [[ -e "$d" ]]; then
        if [[ $CLEAN -eq 1 ]]; then
            rm -rf "$d" && printf '  removed  %s\n' "$d"
        else
            printf '  scratch  %s\n' "$d"
        fi
    fi
done
[[ $CLEAN -eq 0 ]] && dim "(doctor.sh --fix also clears the /tmp/bs-* set)"

hdr "mutation reports on disk"
n_rep=$(ls "$REPO"/tools/mutation_report_*.json 2>/dev/null | wc -l)
if [[ "$n_rep" -gt 0 ]]; then
    ls -1 "$REPO"/tools/mutation_report_*.json | sed "s#$REPO/#  #"
    dim "kept deliberately: aggregating runs needs each run's evidence to outlive it"
else
    dim "none"
fi

hdr "summary"
if [[ $CLEAN -eq 1 ]]; then
    printf '  removed %s known-scratch file(s)\n' "$removed"
else
    printf '  %s known-scratch file(s) — clear with --clean\n' "$total_scratch"
fi
if [[ $total_other -gt 0 ]]; then
    printf '  \033[33m%s untracked file(s) LEFT ALONE\033[0m — not scratch-shaped, so this tool\n' "$total_other"
    printf '  will not guess. Commit them, delete them, or rename them zz_* if they are junk.\n'
fi
dim "gates no longer depend on any of this (tools/corpus_ls.sh) — it is only clutter."
exit 0
