#!/usr/bin/env bash
# pins: BUG-485 a Zig host keeps its allocator across a --library-mode main (the regression test for the fix)
# THE EMBEDDING GATE (BUG-485), registered as `library-mode` (FAST tier).
#
# `--library-mode` compiles a Zebra program to be linked into a HOST process. The host
# owns allocation: it calls `_initAllocator(host_alloc)` and later frees what Zebra
# allocated with that allocator. The library's `main()` used to reset `_allocator` to the
# runtime arena on entry, so everything the script allocated before returning lived in the
# arena and the host's first free of it was "Invalid free" -- two GameEngine crashes in
# one night.
#
# THE REAL ATTACKER, not a mutation: a Zig host installs a DebugAllocator, calls the
# library's main, and asks whether the runtime's allocator is still the host's.
# THE NEGATIVE CONTROL runs the same host against the emitted program with the OLD prologue
# restored, and must see the allocator replaced -- otherwise the check cannot fail and a
# pass would mean nothing.
#
# CANNOT SEE: frees the host performs later (it asserts the precondition, not the crash),
# or a runtime that allocates from some other global.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ZEXE="$REPO/zig-out/bin/zebra.exe"
[[ -x "$ZEXE" ]] || ZEXE="$REPO/zig-out/bin/zebra"
[[ -x "$ZEXE" ]] || { echo "library-mode: no built compiler" >&2; exit 2; }
source "$REPO/tools/zig_toolchain.sh"   # the PINNED zig (.zig-version), not the shared ~/.zvm/bin default
# BUG-302: zig can fail to read ITS OWN std under concurrent load ("unable to load
# 'big.zig': Unexpected"). The first FULL after this gate was registered refused on exactly
# that in its negative control (2026-10-01; passed twice standalone). Same predicate as every
# other zig-invoking gate; only that failure is retried, and the count is printed.
. "$REPO/tools/zig_build_lib.sh"
INFRA_RETRIES=0
run_host() {   # $1 = log file
    local tries=0
    while :; do
        ( cd out && zig run host.zig ) > "$1" 2>&1
        if zbr_zig_infra_error "$1" && [ $tries -lt 2 ]; then
            tries=$((tries + 1)); INFRA_RETRIES=$((INFRA_RETRIES + 1)); continue
        fi
        break
    done
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work" || exit 2
printf 'def main()\n    print("lib main ran")\n' > lib485.zbr
if ! "$ZEXE" --library-mode --emit-zig --output-dir out lib485.zbr >emit.log 2>&1; then
    echo "library-mode: REFUSING -- the compiler would not emit the library"; cat emit.log; exit 2
fi
cat > out/host.zig <<'EOF'
const std = @import("std");
const rt = @import("zebra_rt.zig");
const lib = @import("lib485.zig");
pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const host = gpa.allocator();
    rt._initAllocator(host);
    lib.main(init);
    std.debug.print("host allocator kept: {}\n", .{rt._allocator.ptr == host.ptr});
}
EOF
run_host run1.log
if ! grep -q "lib main ran" run1.log; then
    echo "library-mode: REFUSING -- the host did not run the library (see below)"; tail -5 run1.log; exit 2
fi
# negative control: the old prologue
if ! grep -q '_host_alloc_set' out/lib485.zig; then
    echo "library-mode: FAIL -- the library prologue does not consult _host_alloc_set"; grep -n '_allocator' out/lib485.zig; exit 1
fi
sed 's/if (!_zbr_rt._host_alloc_set) _zbr_rt._allocator = _prog_alloc();/_zbr_rt._allocator = _prog_alloc();/; s/if (!_host_alloc_set) _allocator = _prog_alloc();/_allocator = _prog_alloc();/' out/lib485.zig > out/lib485_old.zig
mv out/lib485_old.zig out/lib485.zig
run_host run2.log
if ! grep -q "host allocator kept: false" run2.log; then
    echo "library-mode: REFUSING -- the negative control did not see the allocator replaced, so the check cannot fail"; tail -3 run2.log; exit 2
fi
if grep -q "host allocator kept: true" run1.log; then
    echo "library-mode: PASS -- a host allocator survives the library's main (control: the old prologue replaces it); infra-retries=$INFRA_RETRIES"
    exit 0
fi
echo "library-mode: FAIL -- the library's main replaced the host's allocator (BUG-485)"; tail -3 run1.log
exit 1
