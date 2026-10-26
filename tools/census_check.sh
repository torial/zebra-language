#!/usr/bin/env bash
# census_check.sh — THE ALLOCATION-CENSUS GATE (`census`, FAST tier, 2026-10-23).
#
# `zebra --census` (docs/design/memory_model.md §3 item 6) counts every allocation under
# (source line, allocating function): genStmt sets the runtime's current site beside the
# `// zbr:` marker, every function / constructor / statement lambda saves and restores it,
# the entry prologue wraps `_allocator`, and the runtime prints a report on stderr and
# writes zebra-census.json at exit. Nothing else reads that file, so nothing else could
# notice the counts going to zero, a site charged to the wrong line, or the flush skipped.
#
# THE ORACLE IS THE SOURCE TEXT. tools/fixtures/census_probe.zbr labels lines
# `# cens:none` / `# cens:>=N` / `# cens:kind=TEXT` / `# cens:via=TEXT`; the expected table is derived from
# those comments, never from anything the compiler said. Its `post-call` lines are the
# property that makes the census worth having: an allocation after a call returns belongs
# to the CALLER, and a census without the save/restore charges it to the callee's last line.
# The probe ends in sys.exit (the flush must run on that path), uses a dep module (its
# lines must carry its file name), a statement lambda, a class constructor, a growing List
# (kind = container growth), a scoped `allocate Arena()` block (released at its end) and a
# module var (charged to `<init>`).
#
# Leg 2 runs the same probe WITHOUT --census: no file, no report, and sys.memStats()'s
# census fields are -1 (unmeasured), never 0.
#
# REFUSES (exit 2) below 15 labelled lines, if the JSON is missing or unparseable, or if
# the totals are zero -- every absence assertion is vacuous without a denominator.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/zig_toolchain.sh"   # the PINNED zig, also standalone (hazard_lint H14)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
[ -x "$ZEBRA" ] || [ ! -x "${ZEBRA%.exe}" ] || ZEBRA="${ZEBRA%.exe}"
[ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"
W="$(mktemp -d "${TMPDIR:-/tmp}/zbr_cens.XXXXXX")"
trap 'rm -rf "$W"' EXIT
die() { printf 'census: REFUSING to report — %s\n' "$1"; exit 2; }
[ -x "$ZEBRA" ] || die "zebra not built"
cp tools/fixtures/census_probe.zbr tools/fixtures/census_probe_dep.zbr "$W/"
( cd "$W" && "$ZEBRA" --census --output-dir "$W/out" census_probe.zbr > "$W/run.out" 2> "$W/run.err" ) || true
[ -s "$W/zebra-census.json" ] || { tail -8 "$W/run.out" "$W/run.err"; die "no zebra-census.json was written (the probe ends in sys.exit; is the flush on that path?)"; }
# Leg 2: the same program without the flag.
printf 'def main()\n    var s = "a" + sys.args().len().toString()\n    var m = sys.memStats()\n    print("${s} ${m.censusOn} ${m.allocations} ${m.allocBytes} ${m.liveBytes}")\n' > "$W/off.zbr"
( cd "$W" && mkdir -p offdir && cd offdir && "$ZEBRA" --output-dir "$W/out2" ../off.zbr > "$W/off.out" 2> "$W/off.err" ) || true
# Leg 3: --library-mode under a Zig host that installs its own allocator (the GameEngine's
# shape). The census must wrap the HOST's allocator -- a census over the arena alone would
# report almost nothing for an embedded program, a convincing near-zero -- and a host must
# be able to ask for a report after main has returned (`_zbr_cens_flush`, here twice).
. "$REPO/tools/zig_build_lib.sh"   # BUG-302: retry only zig failing to read its own std
mkdir -p "$W/lib" && printf 'def main()\n    var i: int = 0\n    var s: str = ""\n    while i < 30\n        s = "x" + i.toString()\n        i = i + 1\n    print("lib main ran ${s}")\n' > "$W/lib/libc.zbr"
( cd "$W/lib" && "$ZEBRA" --library-mode --census --emit-zig --output-dir out libc.zbr > emit.log 2>&1 ) || { tail -5 "$W/lib/emit.log"; die "the compiler would not emit the --library-mode --census program"; }
cat > "$W/lib/out/host.zig" <<'EOF'
const std = @import("std");
const rt = @import("zebra_rt.zig");
const lib = @import("libc.zig");
pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const host = gpa.allocator();
    rt._initAllocator(host);
    lib.main(init);
    std.debug.print("wraps host allocator: {}\n", .{rt._zbr_cens_root.child.ptr == host.ptr});
    const extra = try rt._allocator.alloc(u8, 100);
    rt._allocator.free(extra);
    rt._zbr_cens_flush();
}
EOF
for t in 1 2 3; do
    ( cd "$W/lib/out" && zig run host.zig ) > "$W/lib/host.log" 2>&1
    zbr_zig_infra_error "$W/lib/host.log" || break
done
grep -q "lib main ran" "$W/lib/host.log" || { tail -8 "$W/lib/host.log"; die "the Zig host did not run the library"; }
PY=python; command -v python >/dev/null 2>&1 || PY=python3
"$PY" - "$W" <<'PY'
import json, sys, re, pathlib
w = pathlib.Path(sys.argv[1])
try:
    cen = json.loads((w / "zebra-census.json").read_text())
except Exception as e:
    print(f"census: REFUSING to report — JSON unparseable: {e}"); sys.exit(2)
tot = cen.get("totals", {})
sites = cen.get("sites", [])
if not tot.get("allocations") or not sites:
    print(f"census: REFUSING to report — zero allocations / no sites: the wrapper is not installed"); sys.exit(2)
passed = failed = labelled = 0
def ok(m):
    global passed; passed += 1; print(f"  ok   {m}")
def bad(m):
    global failed; failed += 1; print(f"  FAIL {m}")
for src in ("census_probe.zbr", "census_probe_dep.zbr"):
    rows = [s for s in sites if s["file"].endswith("/" + src) or s["file"] == src]
    if not rows:
        bad(f"{src}: no site carries this file name"); continue
    by_line = {}
    for r in rows:
        by_line.setdefault(r["line"], []).append(r)
    for n, text in enumerate((w / src).read_text().splitlines(), 1):
        m = re.search(r"# cens:(.*)$", text)
        if not m or text.lstrip().startswith("#"): continue
        labelled += 1
        here = by_line.get(n, [])
        count = sum(r["count"] for r in here)
        for tok in m.group(1).split():
            if tok == "none":
                (ok if count == 0 else bad)(f"{src}:{n} no allocation (got {count}: {[r['kind'] for r in here]})")
            elif tok.startswith(">="):
                want = int(tok[2:])
                (ok if count >= want else bad)(f"{src}:{n} at least {want} allocations (got {count})")
            elif tok.startswith("kind="):
                k = tok[5:]
                kinds = [r["kind"] for r in here]
                (ok if any(x and k in x for x in kinds) else bad)(f"{src}:{n} a kind containing {k!r} (got {kinds})")
            elif tok.startswith("via="):
                k = tok[4:]
                vias = [r.get("via") for r in here]
                (ok if any(x and k in x for x in vias) else bad)(f"{src}:{n} a via (innermost std frame) containing {k!r} (got {vias})")
init = [s for s in sites if s["file"] == "<init>"]
(ok if init else bad)(f"module var initialisation charged to <init> ({sum(s['count'] for s in init)} allocations)")
(ok if tot.get("releasedScopes", 0) >= 1 else bad)(f"the scoped allocate block was released ({tot.get('releasedScopes')})")
(ok if tot.get("interned", 0) >= 1 else bad)(f"interned strings counted ({tot.get('interned')})")
(ok if "arenaCapacity" in tot and tot["arenaCapacity"] >= tot.get("live", 0) else bad)(f"arena capacity reported and >= live ({tot.get('arenaCapacity')} vs {tot.get('live')})")
summed = sum(s["count"] for s in sites)
(ok if summed >= tot["allocations"] else bad)(f"site counts cover the allocation total ({summed} rows-count vs {tot['allocations']} allocations; growth in place adds rows, not allocations)")
err = (w / "run.err").read_text(errors="replace")
(ok if "Allocation census" in err and "NOT counted" in err else bad)("the stderr report was printed, and names what it does not count")
out = (w / "run.out").read_text(errors="replace")
(ok if "Allocation census" not in out else bad)("the report is on stderr, not stdout")
# Leg 2
off_out = (w / "off.out").read_text(errors="replace").strip()
(ok if off_out.endswith("false -1 -1 -1") else bad)(f"without --census, memStats census fields read unmeasured (-1), not 0 (got {off_out!r})")
(ok if not (w / "offdir" / "zebra-census.json").exists() else bad)("without --census, no zebra-census.json")
(ok if "Allocation census" not in (w / "off.err").read_text(errors="replace") else bad)("without --census, no report")
# Leg 3
hl = (w / "lib" / "host.log").read_text(errors="replace")
(ok if "wraps host allocator: true" in hl else bad)("--library-mode: the census wraps the HOST's allocator")
(ok if hl.count("Allocation census") == 2 else bad)(f"--library-mode: main's exit report and the host's own flush both printed (got {hl.count('Allocation census')})")
(ok if "the host's (--library-mode)" in hl and "program arena holds" not in hl else bad)("--library-mode: the report says the allocator is the host's, and prints no arena line")
lj = w / "lib" / "out" / "zebra-census.json"
try:
    lt = json.loads(lj.read_text())["totals"]
    (ok if lt["allocations"] >= 31 and lt["frees"] >= 1 and "arenaCapacity" not in lt else bad)(f"--library-mode: 30 loop allocations and the host's own alloc/free counted, no arena figure ({lt})")
except Exception as e:
    bad(f"--library-mode: no readable zebra-census.json from the host's flush ({e})")
if labelled < 15:
    print(f"census: REFUSING to report — only {labelled} labelled lines"); sys.exit(2)
print(f"census: {passed} passed, {failed} failed ({labelled} labelled lines, {len(sites)} sites, {tot['allocations']} allocations)")
sys.exit(1 if failed else 0)
PY
