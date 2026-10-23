#!/usr/bin/env bash
# Copy vs view for `split` results under an allocator that frees (docs/design/memory_model.md §6.1).
# Builds one ReleaseFast exe per variant into a private temp dir and runs them INTERLEAVED, R rounds.
# usage: bash bench/split_copy_view/run.sh [rounds]      (Windows: the bench reads the working set
# through kernel32). Each line: variant, shape, ms, allocations, peak/end live requested bytes,
# peak working set, and a checksum that must agree across the policies of one workload.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../tools/zig_toolchain.sh" >/dev/null || exit 2
R=${1:-5}
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
V="W1:arena:false W1:view:false W1:copy_all:false W1:copy_kept:false W2:view:false W2:copy_all:false W2:copy_kept:false W3:view:false W3:copy_all:false W2:view:true W2:copy_all:true W2:copy_kept:true"
names=""
for v in $V; do
  w=${v##*:}; vv=${v%:*}; n=${vv/:/_}_$w
  sed -e "s/@V@/$vv/" -e "s/@W@/$w/" "$HERE/bench.zig" > "$OUT/b_$n.zig"
  (cd "$OUT" && zig build-exe -OReleaseFast "b_$n.zig" -femit-bin="b_$n.exe" > "build_$n.log" 2>&1) \
    || { echo "BUILD FAIL $n"; cat "$OUT/build_$n.log"; exit 2; }
  names="$names $n"
done
for r in $(seq 1 "$R"); do for n in $names; do "$OUT/b_$n.exe" 2>&1; done; done
