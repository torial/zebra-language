#!/usr/bin/env bash
# coverage_check.sh — THE COVERAGE-MAP GATE (`coverage-map`, FAST tier, 2026-09-23).
#
# `--coverage` is our own instrumentation: genStmt bumps a per-line counter beside the
# `// zbr:` marker it already emits, every module ends with its record (path, the
# instrumented lines, the counters), the entry prologue attaches them and the runtime
# writes zebra-coverage.json on exit. Nothing else in the tree reads that file, so
# nothing else could notice the counts drifting, the denominator shrinking, a dep
# module going missing, or the flush being skipped on sys.exit.
#
# THE ORACLE IS THE SOURCE TEXT. tools/fixtures/coverage_probe.zbr labels its lines
# `# cov:hit` / `# cov:miss` / `# cov:none` and this script derives the expected map from
# those comments, never from anything the compiler said (the debug-map lesson: two
# lookups broken in compensating ways agree perfectly). The probe ends in sys.exit, so
# a flush that only runs on a normal return goes red here. The dep module carries a
# never-called function, so a dep whose record was never attached goes red too.
#
# REFUSES (exit 2) below 10 labelled lines or if the JSON is missing/unparseable,
# because every absence assertion is vacuous without a denominator.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
ZEBRA="$REPO/zig-out/bin/zebra.exe"
[ -x "$ZEBRA" ] || ZEBRA="$REPO/zig-out/bin/zebra"
W="$(mktemp -d "${TMPDIR:-/tmp}/zbr_cov.XXXXXX")"
trap 'rm -rf "$W"' EXIT
die() { printf 'coverage-map: REFUSING to report — %s\n' "$1"; exit 2; }
[ -x "$ZEBRA" ] || die "zebra not built"
cp tools/fixtures/coverage_probe.zbr tools/fixtures/coverage_probe_dep.zbr "$W/"
( cd "$W" && "$ZEBRA" --coverage --output-dir "$W/out" coverage_probe.zbr > "$W/run.log" 2>&1 ) || true
[ -s "$W/zebra-coverage.json" ] || { cat "$W/run.log" | tail -5; die "no zebra-coverage.json was written (the probe ends in sys.exit; is the flush on that path?)"; }
# `python` first: on torial the `python3` name is the Microsoft Store stub (exit 49).
PY=python; command -v python >/dev/null 2>&1 || PY=python3
"$PY" - "$W" <<'PY'
import json, sys, re, pathlib
w = pathlib.Path(sys.argv[1])
try:
    cov = json.loads((w / "zebra-coverage.json").read_text())
except Exception as e:
    print(f"coverage-map: REFUSING to report — JSON unparseable: {e}"); sys.exit(2)
files = cov.get("files", {})
passed = failed = labelled = 0
def ok(m): 
    global passed; passed += 1; print(f"  ok   {m}")
def bad(m):
    global failed; failed += 1; print(f"  FAIL {m}")
for src in ("coverage_probe.zbr", "coverage_probe_dep.zbr"):
    key = next((k for k in files if k.endswith(src)), None)
    if key is None:
        bad(f"{src}: absent from the JSON (every module must attach its record)"); continue
    lines = {int(k): v for k, v in files[key]["lines"].items()}
    for n, text in enumerate((w / src).read_text().splitlines(), 1):
        m = re.search(r"# cov:(hit|miss|none)\s*$", text)
        if not m: continue
        labelled += 1
        want = m.group(1)
        if want == "none":
            (ok if n not in lines else bad)(f"{src}:{n} not instrumented (got {lines.get(n)})")
        elif want == "hit":
            (ok if lines.get(n, 0) > 0 else bad)(f"{src}:{n} hit (count {lines.get(n)})")
        else:
            (ok if n in lines and lines[n] == 0 else bad)(f"{src}:{n} instrumented and never ran (count {lines.get(n)})")
    extra = sorted(l for l in lines if l not in {n for n, t in enumerate((w / src).read_text().splitlines(), 1) if re.search(r"# cov:(hit|miss)\s*$", t)})
    (ok if not extra else bad)(f"{src}: no instrumented line outside the labelled set (extra: {extra})")
if labelled < 10:
    print(f"coverage-map: REFUSING to report — only {labelled} labelled lines"); sys.exit(2)
print(f"coverage-map: {passed} passed, {failed} failed ({labelled} labelled lines, {len(files)} files)")
sys.exit(1 if failed else 0)
PY
