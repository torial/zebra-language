#!/usr/bin/env python3
"""registration_check.py -- every corpus file must have its status ASSERTED somewhere.

THE HOLE THIS CLOSES
--------------------
`full_sweep` gates against a baseline (337 of 421 files). A file that has NEVER passed is
not in the baseline, so it cannot make the gate red however broken it is. And if nothing
registers it with a `smoke*` helper, nothing asserts it should fail either.

**A permanently-broken file is therefore indistinguishable from an intentionally negative
one, and both look like a green board.**

That is not hypothetical. On 2026-08-01/02, fifteen files were found in exactly this
state -- BUG-241 (uncompilable since the Zig 0.16 migration), BUG-242, and thirteen more
inventoried in BUG-243. Two of them are REGRESSION FIXTURES for BUG-106 and BUG-108 that
have never run, so those fixes are unverified.

`tools/bug_fixture_check.py` already enforces this shape for *bug* fixtures ("counts a
fixture as real only if something actually RUNS it"). Nothing enforced it for ordinary
feature tests. This does.

WHAT IT ASKS
------------
For every tracked `test/*.zbr`: is its status asserted by *something*?

  * registered with any `smoke*` helper in tools/selfhost_smoke.sh, OR
  * present in tools/full_sweep_baseline.txt (it emits and compiles clean), OR
  * listed in tools/registration_exempt.txt WITH A REASON.

A file in none of those is a file nobody has an opinion about, which is how the fifteen
got there.

BASELINED, like bug_fixture_check: the existing debt is recorded so this fails only on
NEW debt. A gate that starts life red is a gate people learn to ignore. Shrink the
baseline as BUG-243 is worked; `--update-baseline` to re-record.

Exit: 0 clean, 1 new unasserted file(s), 2 the checker itself is not working.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SMOKE = REPO / "tools" / "selfhost_smoke.sh"
SWEEP_BASE = REPO / "tools" / "full_sweep_baseline.txt"
EXEMPT = REPO / "tools" / "registration_exempt.txt"
BASELINE = REPO / "tools" / "registration_baseline.txt"


def tracked_tests():
    import subprocess
    out = subprocess.run(["git", "-C", str(REPO), "ls-files", "--", "test"],
                         capture_output=True, check=True).stdout.decode("utf-8", "replace")
    return sorted({ln[len("test/"):-len(".zbr")] for ln in out.split("\n")
                   if ln.startswith("test/") and ln.endswith(".zbr")
                   and "/" not in ln[len("test/"):]})


def registered():
    text = SMOKE.read_text(encoding="utf-8")
    return {m.rsplit("/", 1)[-1][:-4]
            for m in re.findall(r'^smoke\w*\s+(test/\S+\.zbr)', text, re.M)}


def sweep_clean():
    if not SWEEP_BASE.exists():
        return set()
    return {ln.strip() for ln in SWEEP_BASE.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.startswith("#")}


def exempt():
    """name -> reason. A reason is REQUIRED; a bare name is itself reported."""
    out, bad = {}, []
    if EXEMPT.exists():
        for ln in EXEMPT.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            name, _, reason = ln.partition("#")
            name, reason = name.strip(), reason.strip()
            if not reason:
                bad.append(name)
            out[name] = reason
    return out, bad


def baselined():
    if not BASELINE.exists():
        return set()
    return {ln.strip() for ln in BASELINE.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.startswith("#")}


def main():
    argv = sys.argv[1:]
    tests = tracked_tests()
    reg, clean = registered(), sweep_clean()
    ex, bad_ex = exempt()

    # CONTROL. If either source parses empty, every file looks unasserted and this
    # would report a spectacular false alarm -- or, with an --update-baseline, quietly
    # baseline the entire corpus and go green forever.
    if not tests or not reg or not clean:
        print(f"REFUSING TO REPORT: parsed {len(tests)} tests, {len(reg)} registrations, "
              f"{len(clean)} sweep-clean names. One of the three parsers has stopped "
              f"working; any verdict here would be fiction.")
        return 2

    unasserted = sorted(n for n in tests
                        if n not in reg and n not in clean and n not in ex)

    if "--update-baseline" in argv:
        BASELINE.write_text(
            "# Files whose status nothing asserts -- existing debt, recorded so the gate\n"
            "# fails only on NEW debt. Shrink this; do not grow it. See BUG-243.\n"
            + "\n".join(unasserted) + "\n", encoding="utf-8", newline="\n")
        print(f"baseline recorded: {len(unasserted)} unasserted file(s)")
        return 0

    known = baselined()
    new = [n for n in unasserted if n not in known]
    fixed = sorted(known - set(unasserted))

    for n in new:
        print(f"  UNASSERTED  test/{n}.zbr — no smoke registration, not sweep-clean, "
              f"not exempt")
    for n in bad_ex:
        print(f"  NO REASON   {n} is exempt with no reason given — state why")
    if fixed:
        print(f"  · {len(fixed)} previously-unasserted file(s) now covered "
              f"(--update-baseline to lock it in): {', '.join(fixed[:6])}"
              + (" …" if len(fixed) > 6 else ""))

    total_bad = len(new) + len(bad_ex)
    print(f"\n[registration] {len(tests)} tracked tests, {len(unasserted)} unasserted "
          f"({len(known)} known debt), {len(new)} NEW")
    return 1 if total_bad else 0


if __name__ == "__main__":
    sys.exit(main())
