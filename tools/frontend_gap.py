"""THE FRONT-END GAP: which failures does `zebra -c` wave through that `zig` then rejects?

Sean's observation, 2026-08-03: all four BUG-243 files spot-checked pass `-c` with zero
errors and then fail to build. `-c` is documented as front-end-only and deliberately
incomplete -- but "incomplete" is not a size, and the gap is exactly the work named by
NEXT_STEPS' organizing goal, "move checking INTO Zebra".

Every entry this prints is a case where the compiler HAD the program in front of it, said
nothing, and let Zig deliver the diagnosis instead -- in Zig's vocabulary, about emitted
code the user never wrote.

METHOD. For each tracked corpus file that is NOT in tools/full_sweep_baseline.txt (i.e. it
does not emit+compile cleanly), run `-c`. If `-c` exits 0, the front end missed it. Bucket
by the Zig error so the result is a PRIORITISED LIST of checks to add, not a number.

Deliberately scoped to the non-baseline set: files in the baseline compile fine, so there
is nothing for `-c` to have missed.

WHAT THIS CANNOT SAY. A file can be an intentional NEGATIVE test whose failure is meant to
come from Zig. This does not distinguish those, so the output is a candidate list for
triage, not a defect list. Registered negatives are flagged where detectable.
"""
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(r"C:\Projects\zebra-language")
ZEBRA = REPO / "zig-out" / "bin" / "zebra.exe"
BASE = REPO / "tools" / "full_sweep_baseline.txt"
SMOKE = REPO / "tools" / "selfhost_smoke.sh"

# Coarse buckets, chosen so each names a CHECK that could exist rather than a symptom.
BUCKETS = [
    ("undeclared identifier / scope", r"undeclared identifier|not declared|no member named"),
    ("unhandled error union (§28b)", r"error union is ignored|error is ignored|must be handled"),
    ("type mismatch", r"expected type"),
    ("const/var mutability", r"never mutated|cannot assign to constant"),
    ("arity", r"expected \d+ argument"),
    ("struct field", r"missing struct field|no field named"),
    ("unused", r"unused (function parameter|local|variable)"),
]


def tracked():
    out = subprocess.run(["git", "-C", str(REPO), "ls-files", "--", "test"],
                         capture_output=True, check=True).stdout.decode("utf-8", "replace")
    return sorted(ln for ln in out.split("\n")
                  if ln.startswith("test/") and ln.endswith(".zbr")
                  and "/" not in ln[len("test/"):])


def main():
    if not ZEBRA.is_file():
        print("REFUSING TO REPORT: compiler not built.")
        return 2
    base = {l.strip() for l in BASE.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.startswith("#")}
    smoke = SMOKE.read_text(encoding="utf-8")
    negatives = set(re.findall(r'^smoke\w*fail\w*\s+(?:test/)?(\S+?)\.zbr', smoke, re.M))

    files = tracked()
    if not files or not base:
        print(f"REFUSING TO REPORT: {len(files)} files, {len(base)} baseline entries.")
        return 2

    cand = [f for f in files if f[len("test/"):-len(".zbr")] not in base]
    print(f"corpus {len(files)}, baseline-clean {len(base)}, "
          f"NON-COMPILING candidates {len(cand)}\n")

    missed, caught, skipped = [], 0, 0
    for rel in cand:
        name = rel[len("test/"):-len(".zbr")]
        c = subprocess.run([str(ZEBRA), "-c", str(REPO / rel)],
                           capture_output=True, cwd=str(REPO), timeout=180)
        if c.returncode != 0:
            caught += 1
            continue
        full = subprocess.run([str(ZEBRA), str(REPO / rel)],
                              capture_output=True, cwd=str(REPO), timeout=400)
        if full.returncode == 0:
            skipped += 1        # compiles after all (not in baseline for another reason)
            continue
        raw = (full.stdout + full.stderr).decode("utf-8", "replace")
        line = next((l.strip() for l in raw.split("\n") if "error:" in l), "?")
        bucket = next((b for b, pat in BUCKETS if re.search(pat, line, re.I)), "other")
        missed.append((name, bucket, line[-95:], name in negatives))

    print(f"-c CAUGHT it:          {caught}")
    print(f"compiled after all:    {skipped}")
    print(f"-c MISSED it:          {len(missed)}   <- the front-end gap\n")

    by = {}
    for n, b, msg, neg in missed:
        by.setdefault(b, []).append((n, msg, neg))
    for b in sorted(by, key=lambda k: -len(by[k])):
        print(f"  {b}  ({len(by[b])})")
        for n, msg, neg in by[b][:6]:
            tag = " [registered-negative]" if neg else ""
            print(f"      {n}{tag}\n          {msg}")
        if len(by[b]) > 6:
            print(f"      ... and {len(by[b]) - 6} more")
    return 0


if __name__ == "__main__":
    sys.exit(main())
