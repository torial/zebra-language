"""bug_fixture_check.py — A1: every FIXED bug must be pinned by a test that RUNS.

SQLite's discipline is "a regression test for every reported bug." That works as a habit
right up until the day someone is in a hurry, and then it fails silently: the bug is
fixed, the fix is committed, nothing pins it, and a year later it comes back and looks
brand new. This makes the habit mechanical.

WHAT "PINNED" MEANS HERE — deliberately stricter than "a file exists"
--------------------------------------------------------------------
A fixture that is not registered in `tools/selfhost_smoke.sh` is never executed by any
gate, so it pins nothing. It is a file that looks like coverage. This tool therefore
reports three states, not two:

    PINNED           fixture exists AND is registered in smoke      <- actually protects
    FIXTURE-NOT-RUN  fixture exists, nothing runs it                <- looks like coverage
    UNPINNED         no fixture at all

A bug is matched to a fixture by filename (`test/bug224_*.zbr`) or by any test file
MENTIONING it (`BUG-224` in a comment), because some fixtures legitimately cover a bug
under a different name.

DEBT IS BASELINED, NOT IGNORED
------------------------------
There are ~139 fixed bugs and this project is old enough that many predate the fixture
convention; some (tooling bugs, doc bugs, build-script bugs) cannot have a .zbr fixture at
all. Failing on all of them would make the gate useless on day one and it would be
switched off. So the current debt is recorded in a baseline and the gate fails only on
NEW debt — the same shape as full_sweep_baseline. The debt COUNT is printed every run so
it stays visible instead of becoming invisible.

    python tools/bug_fixture_check.py                    # report
    python tools/bug_fixture_check.py --gate             # fail on NEW unpinned fixed bugs
    python tools/bug_fixture_check.py --update-baseline  # accept current debt
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
BASELINE = REPO / "tools" / "bug_fixture_baseline.txt"
SMOKE = REPO / "tools" / "selfhost_smoke.sh"


def fixed_bugs() -> dict:
    """number -> short title, for every bug recorded as FIXED."""
    out = {}
    # BUGS.md carries both open and fixed; the status marker decides.
    p = REPO / "BUGS.md"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^#+\s*BUG-(\d+)\s*:?\s*(.*)$", line)
            if m and ("FIXED" in line or "✅" in line):
                out[int(m.group(1))] = m.group(2)[:70]
    # BUGS_FIXED.md is the archive — everything in it is fixed by definition.
    p = REPO / "BUGS_FIXED.md"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^#+\s*BUG-(\d+)\s*:?\s*(.*)$", line)
            if m:
                out.setdefault(int(m.group(1)), m.group(2)[:70])
    return out


def main() -> int:
    # Windows defaults stdout to cp1252 when it is REDIRECTED, so printing a check mark —
    # or echoing a bug title containing the ✅ status emoji — raises UnicodeEncodeError and
    # the tool exits 1. That is indistinguishable from "the gate failed", which made the
    # first falsification run of this very tool ambiguous. Force UTF-8 with replacement so
    # a verdict is always a verdict.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    bugs = fixed_bugs()
    if not bugs:
        # A tool that finds nothing to check is reporting on itself, not on the repo.
        sys.stderr.write("no FIXED bugs parsed from BUGS.md / BUGS_FIXED.md — the parser "
                         "is broken or the files moved. Refusing to report all-clear.\n")
        return 2

    # test/boundary/*.zbr counts too. A1 (this gate) and A3 (the boundary suite) were
    # built a day apart and did not know about each other: a boundary probe pinning
    # BUG-NNN is a real, running fixture, but this glob was non-recursive so three
    # genuinely-guarded bugs were reported as "no fixture at all" the moment they were
    # marked FIXED. A gate that cries wolf gets switched off, and this one is supposed
    # to make fixes stick.
    tests = sorted((REPO / "test").glob("*.zbr")) + sorted((REPO / "test/boundary").glob("*.zbr"))
    by_name, mentions = {}, {}
    for t in tests:
        m = re.match(r"^bug0*(\d+)[_.]", t.name)
        if m:
            by_name.setdefault(int(m.group(1)), []).append(t.name)
    for t in tests:
        try:
            body = t.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for num in set(int(x) for x in re.findall(r"BUG-0*(\d+)", body)):
            mentions.setdefault(num, []).append(t.name)

    # "Exercised" is broader than "named in selfhost_smoke.sh", and getting this wrong
    # makes the gate cry wolf — which is how a gate stops being read. Three legitimate
    # ways a fixture runs without being smoke-registered by name:
    #   1. another registered test `use`s it as a module (bug082_lib, bug221_*_leaf);
    #   2. a different tool drives it deliberately (bug099_unresolved_test is
    #      compile_check's known-bad witness, and is unregistered ON PURPOSE);
    #   3. it is referenced by any other gate script.
    smoke_text = SMOKE.read_text(encoding="utf-8") if SMOKE.exists() else ""
    registered = set(re.findall(r"test/([A-Za-z0-9_]+)\.zbr", smoke_text))

    tool_text = ""
    for pat in ("*.sh", "*.py"):
        for f in (REPO / "tools").glob(pat):
            if f.name == pathlib.Path(__file__).name:
                continue  # this file names bugs it is REPORTING on, not driving
            try:
                tool_text += f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass
    driven = set(re.findall(r"test/([A-Za-z0-9_]+)\.zbr", tool_text))

    # Boundary probes are driven as a DIRECTORY, not by name: boundary_check.sh globs
    # test/boundary/*.zbr and runs every one. So the per-name regex above can never see
    # them, and matching on the directory is the honest encoding of how they run --
    # exactly the "a different tool drives it deliberately" case in the list above.
    # Guarded rather than assumed: only counted if that glob is really in the runner,
    # so deleting or narrowing it does not silently leave these looking exercised.
    boundary_runner = (REPO / "tools" / "boundary_check.sh")
    if boundary_runner.exists() and 'test/boundary' in boundary_runner.read_text(
            encoding="utf-8", errors="replace"):
        driven |= {t.stem for t in (REPO / "test/boundary").glob("*.zbr")}

    # Transitive: a module imported by something already exercised is itself exercised.
    stems = {t.stem for t in tests}
    exercised = set(registered) | driven
    for _ in range(4):  # fixpoint; import chains here are shallow
        grew = set()
        for t in tests:
            if t.stem not in exercised:
                continue
            try:
                body = t.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for used in re.findall(r"^\s*use\s+([A-Za-z0-9_]+)", body, re.M):
                if used in stems and used not in exercised:
                    grew.add(used)
        if not grew:
            break
        exercised |= grew
    registered = exercised

    pinned, not_run, unpinned = [], [], []
    for num in sorted(bugs):
        files = by_name.get(num, []) + [f for f in mentions.get(num, [])
                                        if f not in by_name.get(num, [])]
        if not files:
            unpinned.append(num)
        elif any(f[:-4] in registered for f in files):
            pinned.append(num)
        else:
            not_run.append((num, files[0]))

    debt = set(unpinned) | {n for n, _ in not_run}

    print(f"fixed bugs: {len(bugs)}   pinned by a test that RUNS: {len(pinned)}")
    print(f"  fixture exists but nothing runs it: {len(not_run)}")
    print(f"  no fixture at all:                  {len(unpinned)}")

    if "--update-baseline" in sys.argv:
        BASELINE.write_text(
            "# DERIVED by tools/bug_fixture_check.py --update-baseline.\n"
            "# Fixed bugs that are NOT pinned by a test that actually runs. This is DEBT,\n"
            "# recorded so the gate can fail on NEW debt without failing on the backlog.\n"
            "# Shrinking this list is good; it should never grow.\n"
            + "".join(f"{n}\t{bugs[n]}\n" for n in sorted(debt)),
            encoding="utf-8", newline="\n")
        print(f"baseline updated: {len(debt)} unpinned -> tools/bug_fixture_baseline.txt")
        return 0

    if "--gate" in sys.argv:
        if not BASELINE.exists():
            sys.stderr.write("no baseline — run: python tools/bug_fixture_check.py "
                             "--update-baseline\n")
            return 2
        known = {int(l.split("\t")[0]) for l in BASELINE.read_text(encoding="utf-8").splitlines()
                 if l.strip() and not l.startswith("#")}
        new_debt = sorted(debt - known)
        fixed_debt = sorted(known - debt)
        if fixed_debt:
            print(f"· newly pinned since baseline ({len(fixed_debt)}): "
                  + ", ".join(f"BUG-{n}" for n in fixed_debt[:12]))
            print("  (run --update-baseline to lock the improvement in)")
        if new_debt:
            sys.stderr.write(
                f"\nbug-fixture gate FAIL — {len(new_debt)} newly FIXED bug(s) with no test "
                f"that runs:\n")
            for n in new_debt:
                where = dict(not_run).get(n)
                why = f"fixture {where} exists but is not registered in smoke" if where \
                      else "no fixture at all"
                sys.stderr.write(f"  BUG-{n}: {bugs[n]}\n      -> {why}\n")
            sys.stderr.write("\nA fix without a fixture is a fix that can silently come "
                             "back. Add test/bug<N>_*.zbr and register it with smoke_run.\n")
            return 1
        print(f"✓ bug-fixture gate PASS — no new unpinned fixed bugs "
              f"(known debt: {len(known)})")
        return 0

    if not_run:
        print("\nfixture exists but NOTHING RUNS IT (looks like coverage, isn't):")
        for n, f in not_run[:20]:
            print(f"  BUG-{n}: {f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
