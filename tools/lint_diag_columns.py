#!/usr/bin/env python3
# pins: BUG-121 this gate IS its regression test. The checkExpr half is fixed; the
# pins: BUG-121 WIDER class (18 other fixtures whose diagnostics still report column
# pins: BUG-121 0) is baselined here and fails on growth. There is no test/bug121_*.zbr
# pins: BUG-121 because the claim is about a PROPERTY of every diagnostic, which only a
# pins: BUG-121 scanner can assert.
"""lint_diag_columns.py — THE DIAGNOSTIC-POSITION GATE (BUG-121 / BUG-249 / BUG-284).

A front-end diagnostic that cannot say WHERE is delivered half-finished. `file:8:0:` is
not "position unknown" — it is a plausible-looking coordinate that is simply WRONG, it
defeats caret rendering (which reads line/col to quote the source), and an editor will
happily jump to the wrong place. That is the UNGIT "nothing fabricated" clause, and it
matters more as the front-end-gap programme moves checks inward: every check that lands
there inherits whatever position discipline exists at the time.

THREE BUGS OF THIS EXACT SHAPE WERE FIXED IN TWO DAYS AND NOTHING WOULD HAVE NOTICED ANY
OF THEM:
  BUG-284  zig literals had no span at all           -> every diagnostic said 0:0
  BUG-249  `this`/`nil`/`result` were payload-less   -> 0:0
  BUG-121  checkExpr used the STATEMENT's keyword    -> file:line:0
Each was found by a person reading output. Positions are exactly the kind of thing a
golden-output gate does not assert and a compile gate cannot see.

WHAT IT CHECKS. For every fixture the smoke suite DECLARES must produce a diagnostic, run
`zebra -c` and flag any diagnostic reporting column 0 or line 0.

THE CANDIDATE SET IS DERIVED, never hand-listed: it comes from the `smoke_tc_fail` /
`smoke_run_fail` / `smoke_run_fail_once` registrations, which is where the suite already
says "this must be refused". A hand-maintained list would rot and silently shrink
coverage -- the argument output_sweep makes for deriving its exclusions, and
divergence_check makes for deriving its must-reject set.

THE BASELINE IS NOW EMPTY (2026-08-16). It was 18. BUG-288's three batches took it to
zero, so this gate has changed KIND: it was a ratchet that only failed on growth, and it
is now an ABSOLUTE ASSERTION -- every front-end diagnostic the smoke suite declares
must-fail can say where. Any regression fails immediately, with nothing to hide behind.

That makes the refusal guards load-bearing rather than decorative. With a non-empty
baseline, a scan that silently collapsed would still have printed a suspicious drop; with
an empty one it would print "0 known, 0 NEW" and pass, which is indistinguishable from
success. So: fewer than MIN_CANDIDATES derived is a REFUSAL, not a pass; zero fixtures
producing a parseable diagnostic is a REFUSAL; and the denominator prints on every path
so "0 of 51" cannot be mistaken for "0 of 0". If you are reading a clean run here, check
the candidate and produced counts before believing it.

Keep it at zero. A new entry is not debt to be recorded, it is a regression to be fixed.

CANNOT SEE: whether a non-zero column is the RIGHT column. It asserts a position was
computed, not that it points at the right token. Nor does it see diagnostics from
fixtures that are not registered as failing, nor anything `zig` reports rather than the
Zebra front end. 0 NEW = clean.
"""
import io
import os
import re
import subprocess
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
SMOKE = REPO / "tools" / "selfhost_smoke.sh"
BASELINE = REPO / "tools" / "diag_column_baseline.txt"
ZEBRA = REPO / "zig-out" / "bin" / "zebra.exe"

# Fewer than this means the registration regex stopped matching -- blame the extractor,
# never the compiler under test.
MIN_CANDIDATES = 30

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass

# `file.zbr:LINE:COL: error: msg` -- flag COL == 0, or LINE == 0 (no position at all).
DIAG = re.compile(r"([A-Za-z0-9_./\\-]+\.zbr):(\d+):(\d+): (?:error|warning): (.*)")


def refuse(msg):
    print("[diag-columns] REFUSING — " + msg, file=sys.stderr)
    sys.exit(2)


def candidates():
    if not SMOKE.exists():
        refuse("no selfhost_smoke.sh, so the candidate set cannot be derived")
    text = SMOKE.read_text(encoding="utf-8", errors="replace")
    names = re.findall(
        r"^(?:smoke_tc_fail|smoke_run_fail|smoke_run_fail_once)\s+(test/[A-Za-z0-9_]+\.zbr)",
        text, re.M)
    return sorted(set(names))


def classify(output):
    """Diagnostics in `output` whose position is missing. Pure, so it is testable."""
    bad = []
    for m in DIAG.finditer(output):
        _f, line, col, msg = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
        if col == 0 or line == 0:
            bad.append((line, col, msg.strip()))
    return bad


def selftest():
    """Both directions on synthetic input, before any real scan."""
    dead = []
    if not classify("a.zbr:8:0: error: bad position"):
        dead.append("a col-0 diagnostic was NOT flagged")
    if not classify("a.zbr:0:0: error: no position at all"):
        dead.append("a line-0 diagnostic was NOT flagged")
    if classify("a.zbr:6:13: error: perfectly good position"):
        dead.append("a WELL-POSITIONED diagnostic was flagged")
    if classify("nothing resembling a diagnostic here"):
        dead.append("non-diagnostic text was flagged")
    return dead


def main():
    dead = selftest()
    if dead:
        refuse("SELF-TEST FAILED, so a clean result would mean nothing:\n    "
               + "\n    ".join(dead))
    if "--selftest" in sys.argv[1:]:
        print("[diag-columns] self-test OK: 4/4 discriminate")
        return 0

    if not ZEBRA.exists():
        refuse("no compiler at %s — run `zig build`" % ZEBRA)

    cands = candidates()
    if len(cands) < MIN_CANDIDATES:
        refuse("derived only %d candidate(s) from selfhost_smoke.sh (expected >= %d). "
               "The registration regex has stopped matching." % (len(cands), MIN_CANDIDATES))

    found, produced = {}, 0
    for rel in cands:
        f = REPO / rel
        if not f.exists():
            continue
        try:
            r = subprocess.run([str(ZEBRA), "-c", str(f)], capture_output=True,
                               text=True, timeout=120, cwd=str(REPO))
        except (OSError, subprocess.SubprocessError):
            continue
        out = (r.stdout or "") + (r.stderr or "")
        if DIAG.search(out):
            produced += 1
        bad = classify(out)
        if bad:
            name = pathlib.Path(rel).stem
            found[name] = bad[0]

    # Every candidate is registered as MUST-FAIL. If none produced a parseable
    # diagnostic, the harness is broken and "0 findings" would be a lie of the exact
    # kind this repo has receipts for.
    if produced == 0:
        refuse("not one of the %d must-fail fixtures produced a parseable diagnostic. "
               "That is a harness failure, not a clean result." % len(cands))

    known = set()
    if BASELINE.exists():
        known = {l.split("\t")[0].strip() for l in
                 BASELINE.read_text(encoding="utf-8").splitlines()
                 if l.strip() and not l.startswith("#")}

    if "--update-baseline" in sys.argv[1:]:
        with io.open(BASELINE, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# DERIVED by tools/lint_diag_columns.py --update-baseline.\n"
                     "# Fixtures whose front-end diagnostic reports column 0 (or no line\n"
                     "# at all). This is DEBT: each is a real diagnostic a user can hit\n"
                     "# that cannot say where. Shrink this list; it should never grow.\n")
            for n in sorted(found):
                line, col, msg = found[n]
                fh.write("%s\t%d:%d\t%s\n" % (n, line, col, msg[:88]))
        print("[diag-columns] baseline written: %d entry(s)" % len(found))
        return 0

    # The denominator prints on EVERY path, pass or fail. A gate that hides how much it
    # examined when it fails leaves the reader unable to tell "18 of 55" from "18 of 18",
    # and the second would mean the scan had collapsed.
    print("[diag-columns] %d candidate(s), %d produced diagnostics; %d position-less"
          % (len(cands), produced, len(found)))

    new = sorted(set(found) - known)
    gone = sorted(known - set(found))
    for n in gone:
        print("  fixed since baseline: %s" % n)
    print("              NOT checked: whether a non-zero column is the RIGHT column — this")
    print("              asserts a position was computed, not that it points at the token.")
    if new:
        print("[diag-columns] FAIL — %d fixture(s) newly report a diagnostic with no position:"
              % len(new))
        for n in new:
            line, col, msg = found[n]
            print("    %-40s %d:%d  %s" % (n, line, col, msg[:70]))
        return 1
    print("[diag-columns] %d known, 0 NEW" % len(known))
    return 0


if __name__ == "__main__":
    sys.exit(main())
