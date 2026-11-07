#!/usr/bin/env bash
# pins: BUG-676 a panic under the census lock must PRINT and exit, not hang (leg 4 plants one and runs it under a timeout)
# pins: BUG-677 --census=host counts only after the install; a redundant install and a host build never installed each say so (legs 5-7)
# Leg 8 (2026-11-07): free-at-sweep's pending / freed / sweep counts in the report and the JSON
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
( cd "$W" && timeout 600 "$ZEBRA" --census --output-dir "$W/out" census_probe.zbr > "$W/run.out" 2> "$W/run.err" ); rc=$?
# BUG-676: a census that panics inside its own lock hung here with nothing printed. A hang is
# named as one, never left to the tier's ceiling.
[ "$rc" = 124 ] && { tail -8 "$W/run.err"; die "the --census probe did not finish in 600 s (a deadlock in the census?)"; }
pan=$(grep -m1 "panic:" "$W/run.err")
[ -s "$W/zebra-census.json" ] || [ -z "$pan" ] || die "the --census probe PANICKED ($pan) -- an accounting underflow is a census bug"
[ -s "$W/zebra-census.json" ] || { tail -8 "$W/run.out" "$W/run.err"; die "no zebra-census.json was written (the probe ends in sys.exit; is the flush on that path?)"; }
# Legs 5-7 (BUG-677), each in its own directory so the JSON it leaves (or must NOT leave)
# is its own. Leg 5: --census=host counts only what comes after the install.
mkdir -p "$W/host" && cp tools/fixtures/census_host_probe.zbr "$W/host/"
( cd "$W/host" && timeout 600 "$ZEBRA" --census=host --output-dir out census_host_probe.zbr > run.out 2> run.err ); echo $? > "$W/host/rc"
# Leg 6: a plain --census program that installs AGAIN is told so, once, and its counts are
# unchanged; the same program without the second call prints no note.
mkdir -p "$W/again" "$W/once"
printf 'def main()\n    var s: str = "x" + sys.args().len().toString()\n    zig"_zbr_cens_install();"\n    zig"_zbr_cens_install();"\n    print(s)\n' > "$W/again/again.zbr"
printf 'def main()\n    var s: str = "x" + sys.args().len().toString()\n    print(s)\n' > "$W/once/once.zbr"
( cd "$W/again" && timeout 600 "$ZEBRA" --census --output-dir out again.zbr > run.out 2> run.err ) || true
( cd "$W/once" && timeout 600 "$ZEBRA" --census --output-dir out once.zbr > run.out 2> run.err ) || true
# Leg 7: a --census=host program that never installs says so and leaves no JSON.
mkdir -p "$W/never"
printf 'def main()\n    var s: str = "x" + sys.args().len().toString()\n    print(s)\n' > "$W/never/never.zbr"
( cd "$W/never" && timeout 600 "$ZEBRA" --census=host --output-dir out never.zbr > run.out 2> run.err ) || true
# Leg 8 (2026-11-07): the free-at-sweep counts. Two lists queued and swept, a third queued and
# never swept: the report and the JSON must say 1 pending, 2 freed, 1 sweep -- the engine's
# witness reads "queued, never swept" from here, so a count that sticks at zero would pass it.
mkdir -p "$W/sweep"
cat > "$W/sweep/sweep.zbr" <<'ZEOF'
var _xs = List(int)()

def release(k: int)
    var keep = List(int)()
    for x in _xs
        if x != k
            keep.add(x)
    var old = _xs
    zig"_zbr_free_at_sweep(old)"
    _xs = keep

def main()
    var i = 0
    while i < 10
        _xs.add(i)
        i = i + 1
    release(1)
    release(2)
    zig"_zbr_sweep()"
    release(3)
    print(_xs.count())
ZEOF
( cd "$W/sweep" && timeout 600 "$ZEBRA" --census --output-dir out sweep.zbr > run.out 2> run.err ) || true
# Leg 2: the same program without the flag.
printf 'def main()\n    var s = "a" + sys.args().len().toString()\n    var m = sys.memStats()\n    print("${s} ${m.censusOn} ${m.allocations} ${m.allocBytes} ${m.liveBytes}")\n' > "$W/off.zbr"
( cd "$W" && mkdir -p offdir && cd offdir && timeout 600 "$ZEBRA" --output-dir "$W/out2" ../off.zbr > "$W/off.out" 2> "$W/off.err" ) || true
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
    ( cd "$W/lib/out" && timeout 600 zig run host.zig ) > "$W/lib/host.log" 2>&1
    [ $? = 124 ] && { tail -8 "$W/lib/host.log"; die "the --library-mode host did not finish in 600 s"; }
    zbr_zig_infra_error "$W/lib/host.log" || break
done
grep -q "lib main ran" "$W/lib/host.log" || { tail -8 "$W/lib/host.log"; die "the Zig host did not run the library"; }
# Leg 4 (BUG-676): a panic raised INSIDE the census lock must print and exit. A correct census
# never panics there, so the leg plants one in a scratch copy of the emitted runtime (the 50th
# allocation panics) and builds it. The old handler allocated through `_allocator` on Windows and
# deadlocked with nothing printed; POSIX's getenv never allocated, so off Windows the leg passes
# against either handler and says so.
mkdir -p "$W/pan" && cp tools/fixtures/census_probe.zbr tools/fixtures/census_probe_dep.zbr "$W/pan/"
( cd "$W/pan" && timeout 600 "$ZEBRA" --census --emit-zig --output-dir out census_probe.zbr > emit.log 2>&1 ) || { tail -5 "$W/pan/emit.log"; die "leg 4: the probe would not emit"; }
anchor='^    _zbr_cens.allocs += 1;$'
[ "$(grep -c "$anchor" "$W/pan/out/zebra_rt.zig")" = 1 ] || die "leg 4: the anchor '_zbr_cens.allocs += 1;' is not in the emitted runtime exactly once -- the planted panic would be a no-op"
sed -i "s/$anchor/&\n    if (_zbr_cens.allocs == 50) @panic(\"census lock test\");/" "$W/pan/out/zebra_rt.zig"
grep -q 'census lock test' "$W/pan/out/zebra_rt.zig" || die "leg 4: the planted panic did not land"
for t in 1 2 3; do
    ( cd "$W/pan/out" && timeout 600 zig build-exe census_probe.zig -lc -femit-bin=pan.exe ) > "$W/pan/build.log" 2>&1
    zbr_zig_infra_error "$W/pan/build.log" || break
done
[ -x "$W/pan/out/pan.exe" ] || { tail -5 "$W/pan/build.log"; die "leg 4: the planted-panic probe did not build"; }
( cd "$W/pan/out" && timeout 30 ./pan.exe > ../pan.out 2> ../pan.err ); echo $? > "$W/pan/rc"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo windows > "$W/pan/os" ;; *) echo other > "$W/pan/os" ;; esac
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
            elif tok == "kept=0":
                kc = sum(r["keptCount"] for r in here)
                (ok if count > 0 and kc == 0 else bad)(f"{src}:{n} allocates ({count}) and keeps nothing (got {kc} blocks kept)")
            elif tok.startswith("keptall="):
                k = tok[8:]
                sel = [r for r in here if r["kind"] and k in r["kind"]]
                good = sel and all(r["keptCount"] == r["count"] and r["keptBytes"] == r["bytes"] for r in sel)
                (ok if good else bad)(f"{src}:{n} every {k!r} block still live, kept == requested (got {[(r['count'], r['bytes'], r['keptCount'], r['keptBytes']) for r in sel]})")
            elif tok.startswith("kept1="):
                k = tok[6:]
                sel = [r for r in here if r.get("via") and k in r["via"]]
                kc = sum(r["keptCount"] for r in sel)
                grew = sum(r["count"] for r in sel)
                (ok if sel and grew > 1 and kc == 1 else bad)(f"{src}:{n} {k!r} grew {grew} times and keeps one buffer (got {kc})")
init = [s for s in sites if s["file"] == "<init>"]
(ok if init else bad)(f"module var initialisation charged to <init> ({sum(s['count'] for s in init)} allocations)")
(ok if tot.get("releasedScopes", 0) >= 1 else bad)(f"the scoped allocate block was released ({tot.get('releasedScopes')})")
(ok if tot.get("interned", 0) >= 1 else bad)(f"interned strings counted ({tot.get('interned')})")
(ok if "arenaCapacity" in tot and tot["arenaCapacity"] >= tot.get("live", 0) else bad)(f"arena capacity reported and >= live ({tot.get('arenaCapacity')} vs {tot.get('live')})")
summed = sum(s["count"] for s in sites)
(ok if summed == tot["allocations"] else bad)(f"site counts sum to the allocation total ({summed} vs {tot['allocations']}; a resize adds bytes, not an allocation)")
# The kept column: every block the pointer maps hold is live, and nothing else is -- so the
# per-site kept bytes must sum to the totals' live figure exactly, with no block unseen and no
# length disagreeing. Derived from the run, not recorded.
kb = sum(s["keptBytes"] for s in sites)
(ok if kb == tot.get("live") and kb == tot.get("keptBytes") else bad)(f"site kept bytes sum to the live total ({kb} vs live {tot.get('live')}, totals.keptBytes {tot.get('keptBytes')})")
for f in ("unseenFrees", "unseenResizes", "lengthMismatches"):
    (ok if tot.get(f) == 0 else bad)(f"{f} is 0 (got {tot.get(f)})")
(ok if tot.get("frees", 0) >= 30 else bad)(f"the alloc/free loop's frees are counted ({tot.get('frees')})")
(ok if cen.get("version") == 2 and "keptNote" in cen else bad)(f"zebra-census.json is version 2 and carries the kept note (version {cen.get('version')})")
(ok if "top by bytes kept" in (w / "run.err").read_text(errors="replace") else bad)("the stderr report ranks sites by bytes kept")
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
    (ok if lt.get("keptBytes") == lt["live"] and lt.get("lengthMismatches") == 0 else bad)(f"--library-mode: kept bytes equal live under the host's allocator ({lt.get('keptBytes')} vs {lt['live']})")
except Exception as e:
    bad(f"--library-mode: no readable zebra-census.json from the host's flush ({e})")
# Leg 4 (BUG-676)
prc = int((w / "pan" / "rc").read_text().strip())
perr = (w / "pan" / "pan.err").read_text(errors="replace")
pos = (w / "pan" / "os").read_text().strip()
note = "" if pos == "windows" else " (not Windows: the old handler never allocated here, so this cannot fail on this OS)"
if prc == 124:
    bad(f"a panic inside the census lock HUNG (30 s timeout, nothing printed) -- BUG-676{note}")
else:
    (ok if prc != 0 and "panic: census lock test" in perr else bad)(f"a panic inside the census lock prints and exits (rc={prc}, stderr {perr.strip()[:80]!r}){note}")
# Legs 5-7 (BUG-677)
hsrc = (w / "host" / "census_host_probe.zbr").read_text().splitlines()
hrc = (w / "host" / "rc").read_text().strip()
try:
    hcen = json.loads((w / "host" / "zebra-census.json").read_text())
except Exception as e:
    hcen = None
    bad(f"--census=host: the program installed the census and no readable zebra-census.json was written (rc={hrc}, {e})")
if hcen is not None:
    hrows = [r for r in hcen.get("sites", []) if r["file"].endswith("census_host_probe.zbr")]
    hl = 0
    for n, text in enumerate(hsrc, 1):
        m = re.search(r"# cens:(\S+)", text)
        if not m or text.lstrip().startswith("#"): continue
        hl += 1
        count = sum(r["count"] for r in hrows if r["line"] == n)
        tok = m.group(1)
        if tok == "none":
            (ok if count == 0 else bad)(f"--census=host: line {n} allocates BEFORE the install and is not counted (got {count})")
        else:
            want = int(tok[2:])
            (ok if count >= want else bad)(f"--census=host: line {n} allocates after the install and is counted (got {count}, want >= {want})")
    if hl < 2:
        bad(f"--census=host: the probe's labels were not found ({hl}) -- the oracle is empty")
    herr = (w / "host" / "run.err").read_text(errors="replace")
    (ok if "called again" not in herr and "never installed" not in herr else bad)("--census=host: one install prints neither note")
aerr = (w / "again" / "run.err").read_text(errors="replace")
oerr = (w / "once" / "run.err").read_text(errors="replace")
(ok if aerr.count("_zbr_cens_install() called again") == 1 and "entry prologue installed" in aerr else bad)(f"a second install is named once, with who installed first ({aerr.count('called again')} notes)")
(ok if "called again" not in oerr and "Allocation census" in oerr else bad)("a program that installs once prints no note, and still reports")
try:
    at = json.loads((w / "again" / "zebra-census.json").read_text())["totals"]
    ot = json.loads((w / "once" / "zebra-census.json").read_text())["totals"]
    (ok if at["allocations"] == ot["allocations"] else bad)(f"a redundant install changes no count ({at['allocations']} vs {ot['allocations']})")
except Exception as e:
    bad(f"legs 6: a census JSON is missing or unreadable ({e})")
nerr = (w / "never" / "run.err").read_text(errors="replace")
nout = (w / "never" / "run.out").read_text(errors="replace")
(ok if "never installed" in nerr and "x1" in nout else bad)(f"--census=host with no install: the program ran and the exit says it was never installed ({nerr.strip()[-120:]!r})")
(ok if not (w / "never" / "zebra-census.json").exists() and "Allocation census" not in nerr else bad)("--census=host with no install: no zebra-census.json and no report")
# Leg 8 (free-at-sweep)
serr = (w / "sweep" / "run.err").read_text(errors="replace")
sout = (w / "sweep" / "run.out").read_text(errors="replace")
(ok if "7" in sout.split() else bad)(f"free-at-sweep: the program ran and printed 7 ({sout.strip()[:40]!r})")
(ok if "free-at-sweep: 1 containers queued and not yet swept, 2 freed by 1 sweeps, 0 duplicate" in serr else bad)("free-at-sweep: the report says 1 pending, 2 freed, 1 sweep")
try:
    st = json.loads((w / "sweep" / "zebra-census.json").read_text())["totals"]
    (ok if (st.get("sweepPending"), st.get("sweepFreed"), st.get("sweeps"), st.get("sweepDuplicates")) == (1, 2, 1, 0) else bad)(f"free-at-sweep: the JSON totals say 1 pending, 2 freed, 1 sweep, 0 duplicates ({st.get('sweepPending')}, {st.get('sweepFreed')}, {st.get('sweeps')}, {st.get('sweepDuplicates')})")
except Exception as e:
    bad(f"leg 8: no readable zebra-census.json ({e})")
if labelled < 15:
    print(f"census: REFUSING to report — only {labelled} labelled lines"); sys.exit(2)
print(f"census: {passed} passed, {failed} failed ({labelled} labelled lines, {len(sites)} sites, {tot['allocations']} allocations)")
sys.exit(1 if failed else 0)
PY
