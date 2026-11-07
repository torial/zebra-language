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
# Leg 2 (2026-10-05, BUG-501 1d): a host frees a Zebra-returned list with `_zbr_free` and its
# DebugAllocator must report no leak; freeing nothing must report one (the control).
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
# BOTH legs run the host through this one function. Leg 2 (added 2026-10-05) called
# `zig run` directly, without the retry, and the 2026-10-16 daily refused on exactly that:
# zig could not read std/deque.zig in leg 2's control and the gate said "the
# DebugAllocator reported no leak, so it cannot see one" -- a confident sentence about a
# program that never compiled. Passed twice standalone straight after.
run_zig_host() {   # $1 = dir holding host.zig, $2 = log file
    local tries=0
    while :; do
        ( cd "$1" && zig run host.zig ) > "$2" 2>&1
        if zbr_zig_infra_error "$2" && [ $tries -lt 2 ]; then
            tries=$((tries + 1)); INFRA_RETRIES=$((INFRA_RETRIES + 1)); continue
        fi
        break
    done
}
run_host() { run_zig_host out "$1"; }   # $1 = log file

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
# --- leg 2: _zbr_free (BUG-501 1d) --------------------------------------------------------
# A host that owns a Zebra-returned container frees it with `_zbr_free`, whatever the
# representation -- a value (today) or a reference with a heap header (after the switch).
# THE REAL ATTACKER: the host's own DebugAllocator, asked whether anything leaked. Freeing a
# reference with `deinit` alone leaks the header -- the GameEngine witness found exactly that,
# several times per frame. CONTROL: freeing nothing must be reported as a leak, so a clean
# result cannot mean the detector saw nothing.
printf 'def make(): List(int)\n    var xs = List(int)()\n    var i = 0\n    while i < 50\n        xs.add(i)\n        i = i + 1\n    return xs\n\ndef main()\n    print("lib main ran")\n' > libfree.zbr
if ! "$ZEXE" --library-mode --emit-zig --output-dir outf libfree.zbr >emitf.log 2>&1; then
    echo "library-mode: REFUSING -- the compiler would not emit the _zbr_free library"; cat emitf.log; exit 2
fi
write_free_host() {   # $1 = what the host does with the list: free | none
    cat > outf/host.zig <<EOF
const std = @import("std");
const rt = @import("zebra_rt.zig");
const lib = @import("libfree.zig");
pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    rt._initAllocator(gpa.allocator());
    lib.main(init);
    const xs = lib._zbr_fn_make();
    std.debug.print("items: {}\n", .{xs.items.len});
    if (comptime std.mem.eql(u8, "$1", "free")) rt._zbr_free(xs);
    std.debug.print("leaked: {}\n", .{gpa.deinit() == .leak});
}
EOF
}
run_free_host() { run_zig_host outf "$1"; }
write_free_host none; run_free_host free_none.log
if ! grep -q "leaked: true" free_none.log; then
    echo "library-mode: REFUSING -- with nothing freed the DebugAllocator reported no leak, so it cannot see one"; tail -5 free_none.log; exit 2
fi
write_free_host free; run_free_host free_yes.log
if ! grep -q "items: 50" free_yes.log; then
    echo "library-mode: REFUSING -- the host did not get the 50-item list back"; tail -5 free_yes.log; exit 2
fi
if ! grep -q "leaked: false" free_yes.log; then
    echo "library-mode: FAIL -- _zbr_free left a leak (representation: see below)"; tail -8 free_yes.log; exit 1
fi
# --- leg 3: free-at-sweep (2026-11-07, joint with Fable, the GameEngine's F64 lists) ---------
# A module list rebuilt in a `release` path is queued with `_zbr_free_at_sweep` and freed by
# the host's `_zbr_sweep()` at a frame boundary. THE REAL ATTACKER is the shape it exists for:
# a release fired from INSIDE a walk of the list it replaces. The walk must finish over the old
# list (sum 0..19 = 190) -- freeing at once makes it read freed memory (red-checked: integer
# overflow on garbage). Then: the host's DebugAllocator sees no leak after the sweep; with no
# sweep it sees one (the control); the same list queued twice is freed once (red-checked with
# the dedupe removed: a segfault in the sweep's second free); a queueing inside `allocate` is
# refused by name.
cat > libsw.zbr <<'ZEOF'
var _xs = List(int)()

def fill()
    var i = 0
    while i < 20
        _xs.add(i)
        i = i + 1

def release(k: int)
    var keep = List(int)()
    for x in _xs
        if x != k
            keep.add(x)
    var old = _xs
    zig"_zbr_free_at_sweep(old)"
    _xs = keep

def walkRelease(): int
    var sum = 0
    for x in _xs
        if x == 2
            release(5)
        sum = sum + x
    return sum

def requeue()
    var old = _xs
    zig"_zbr_free_at_sweep(old)"
    zig"_zbr_free_at_sweep(old)"
    _xs = List(int)()

def inScope()
    allocate Arena()
        var t = List(int)()
        t.add(1)
        zig"_zbr_free_at_sweep(t)"

def current(): List(int)
    return _xs

def main()
    print("lib main ran")
ZEOF
if ! "$ZEXE" --library-mode --emit-zig --output-dir outs libsw.zbr >emits.log 2>&1; then
    echo "library-mode: REFUSING -- the compiler would not emit the free-at-sweep library"; cat emits.log; exit 2
fi
write_sweep_host() {   # $1 = sweep | nosweep | dup | scope
    cat > outs/host.zig <<EOF
const std = @import("std");
const rt = @import("zebra_rt.zig");
const lib = @import("libsw.zig");
pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    rt._initAllocator(gpa.allocator());
    lib.main(init);
    lib._zbr_fn_fill();
    const m = "$1";
    if (comptime std.mem.eql(u8, m, "scope")) { lib._zbr_fn_inScope(); return; }
    const s = lib._zbr_fn_walkRelease();
    lib._zbr_fn_release(7);
    if (comptime std.mem.eql(u8, m, "dup")) lib._zbr_fn_requeue();
    std.debug.print("walk sum: {} pending: {}\n", .{ s, rt._zbr_sweep_pending() });
    if (comptime !std.mem.eql(u8, m, "nosweep")) rt._zbr_sweep();
    const xs = lib._zbr_fn_current();
    std.debug.print("items: {} dupes: {} after-sweep pending: {}\n", .{ xs.items.len, rt._zbr_sweep_dupes, rt._zbr_sweep_pending() });
    rt._zbr_free(xs);
    std.debug.print("leaked: {}\n", .{gpa.deinit() == .leak});
}
EOF
}
for m in nosweep sweep dup scope; do write_sweep_host $m; run_zig_host outs sweep_$m.log; done
if ! grep -q "leaked: true" sweep_nosweep.log; then
    echo "library-mode: REFUSING -- with no sweep the DebugAllocator reported no leak, so leg 3 cannot see one"; tail -5 sweep_nosweep.log; exit 2
fi
if ! grep -q "walk sum: 190 pending: 2" sweep_sweep.log || ! grep -q "items: 18 dupes: 0 after-sweep pending: 0" sweep_sweep.log; then
    echo "library-mode: FAIL -- free-at-sweep: the walk did not finish over the old list, or the queue was wrong"; tail -8 sweep_sweep.log; exit 1
fi
if ! grep -q "leaked: false" sweep_sweep.log; then
    echo "library-mode: FAIL -- free-at-sweep left a leak after the sweep"; tail -8 sweep_sweep.log; exit 1
fi
if ! grep -q "items: 0 dupes: 1 after-sweep pending: 0" sweep_dup.log || ! grep -q "leaked: false" sweep_dup.log; then
    echo "library-mode: FAIL -- a container queued twice was not freed exactly once"; tail -8 sweep_dup.log; exit 1
fi
if ! grep -q "_zbr_free_at_sweep inside an .allocate. block" sweep_scope.log; then
    echo "library-mode: FAIL -- a queueing inside an allocate block was not refused by name"; tail -5 sweep_scope.log; exit 1
fi
if grep -q "host allocator kept: true" run1.log; then
    echo "library-mode: PASS -- a host allocator survives the library's main (control: the old prologue replaces it); _zbr_free leaves no leak (control: freeing nothing leaks); free-at-sweep survives a mid-walk release, frees once, leaks nothing (control: no sweep leaks), refuses inside allocate; infra-retries=$INFRA_RETRIES"
    exit 0
fi
echo "library-mode: FAIL -- the library's main replaced the host's allocator (BUG-485)"; tail -3 run1.log
exit 1
