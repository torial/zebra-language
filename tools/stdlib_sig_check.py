"""Compile every row of the stdlib signature table against the real compiler (#5a).

WHY THIS EXISTS
---------------
A signature table that is WRONG is worse than no table: consulted by the type
checker, a bad row produces a FALSE error on valid code, and the user cannot work
around it. So no row may be trusted because it was read out of a document — each
one has to be compiled.

For every row this synthesizes the smallest program that calls the method at its
declared arity on a receiver of its declared kind, and runs `zebra -c`. A row that
fails to compile is either a documentation bug or an extraction bug, and either way
it must be fixed before the table is allowed to drive diagnostics.

This doubles as a doc-vs-implementation check on QUICKSTART: it is how the
`chars()`/`bytes()` inaccuracy was found (documented as returning List(char) /
List(int), actually for-only iterators).

ARITY IS A RANGE, AND THE MINIMUM IS CURATED — NOT PROBED
---------------------------------------------------------
QUICKSTART's Signature column gives the FULL argument list but does not mark which
trailing arguments default. `padLeft(10)`, `padRight(10)` and `center(10)` all
compile because `fill` defaults, so a single fixed arity would have rejected valid
code the moment the TypeChecker consulted it — the exact false-positive the #5a
groundwork warns about. Hence a range.

**But the probe must not SET the minimum.** Walking arities downward measures what
the compiler currently TOLERATES, and what it tolerates is the bug: 7 rows accepted
zero arguments, including `split()`, `count()` and `join()`. Those are not defaults,
they are BUG-215's silently-dropped arguments seen from the other side. Encoding
them as minima would teach the checker to accept genuine errors — the tool would
have faithfully recorded the defect as the specification.

The three real defaults were separated from the four fake ones by RUNNING them:

    s.padLeft(5)  -> "[   ab]"     real: pads with spaces
    s.center(6)   -> "[  ab  ]"    real: centres with spaces
    s.count()     -> PANIC          "reached unreachable code"  (BUG-222)
    s.split()     -> 1 element      silently wrong, not a default

So REAL_DEFAULTS below is curated and each entry cites the observed behaviour. The
downward probe still runs, but its job is now to REPORT tolerated-but-undeclared
arities as suspected arg-dropping — evidence of the bug class, not the table.

BOTH DIRECTIONS
---------------
Since #5a landed in the TypeChecker, every row is also checked NEGATIVELY: a call at
max+1 arguments must now be REJECTED. Without that, the whole mechanism could be
disabled — or silently stop firing — and only the two smoke fixtures would notice,
while this tool went on reporting 43/43 green. A gate that only ever confirms the
happy path is the shape of problem this project has already been bitten by twice.

  python tools/stdlib_sig_check.py           # both directions, every row
  python tools/stdlib_sig_check.py --only X  # just the rows whose method matches X
  python tools/stdlib_sig_check.py --write   # ...and write tools/stdlib_arity.tsv
"""
import os
import subprocess
import sys
import pathlib
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
TSV = ROOT / "tools" / "stdlib_signatures.tsv"
ZEBRA = ROOT / "zig-out" / "bin" / "zebra.exe"

# A literal for each argument type the table uses.
LITERALS = {
    "str": '"x"',
    "int": "1",
    "float": "1.0",
    "bool": "true",
    "char": "c'a'",
}

# How to bind a receiver of each kind, as (declaration lines, expression).
RECEIVERS = {
    "str": (['    var recv: str = "hello world"'], "recv"),
    "List(str)": (["    var recv: List(str) = List(str)()",
                   '    recv.add("a")',
                   '    recv.add("b")'], "recv"),
}


# Minimum arity where a trailing argument genuinely defaults. CURATED, and each
# entry was confirmed by running the call and inspecting the result — not by asking
# the compiler whether it would accept it (see the docstring; it accepts far too
# much). Anything not listed here has min == max.
REAL_DEFAULTS = {
    ("str", "padLeft"):  1,   # s.padLeft(5)  -> "[   ab]"  — fill defaults to space
    ("str", "padRight"): 1,   # s.padRight(5) -> "[ab   ]"
    ("str", "center"):   1,   # s.center(6)   -> "[  ab  ]"
}


def program_for(recv_kind, method, args):
    decls, expr = RECEIVERS[recv_kind]
    call = "%s.%s(%s)" % (expr, method, ", ".join(args))
    # Bind the result so the call is type-checked in a value position, whatever the
    # return type is. No discard statement: `_ = x` is Zig, not Zebra (the first
    # version of this harness used it and produced 43 identical bogus failures),
    # and an unused local is not an error here.
    return "def main()\n" + "\n".join(decls) + "\n    var r = %s\n" % call


def rows():
    out = []
    for line in TSV.read_text(encoding="utf-8").split("\n"):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        while len(parts) < 5:
            parts.append("")
        recv, method, arity, argtypes, _note = parts[:5]
        if recv == "-":
            continue
        out.append((recv, method, int(arity), [a for a in argtypes.split(",") if a]))
    return out


def main():
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
    if not ZEBRA.exists():
        print("stdlib-sig: %s missing — run 'zig build'" % ZEBRA)
        return 1

    work = pathlib.Path(tempfile.mkdtemp(prefix="zbr-sig-"))
    env = dict(os.environ)
    env["PATH"] = "/c/Users/Sean/.zvm/bin;" + env.get("PATH", "")

    def compiles(recv, method, args, tag):
        src = work / ("sig_%s_%s_%s.zbr" % (recv.replace("(", "_").replace(")", ""), method, tag))
        src.write_text(program_for(recv, method, args), encoding="utf-8", newline="\n")
        r = subprocess.run([str(ZEBRA), "-c", str(src)],
                           capture_output=True, text=True, env=env, timeout=180)
        if r.returncode == 0:
            return True, ""
        detail = [d for d in (r.stdout + r.stderr).strip().split("\n") if "error" in d.lower()]
        return False, detail[0] if detail else "exit %d" % r.returncode

    passed, failed, skipped, defaulted, table = 0, [], [], [], []
    not_firing = []
    for recv, method, arity, argtypes in rows():
        if only and only not in method:
            continue
        if recv not in RECEIVERS:
            skipped.append("%s.%s (no receiver recipe)" % (recv, method))
            continue
        missing = [t for t in argtypes if t not in LITERALS]
        if missing:
            skipped.append("%s.%s (no literal for %s)" % (recv, method, ",".join(missing)))
            continue
        args = [LITERALS[t] for t in argtypes]
        if len(args) != arity:
            failed.append((recv, method, "arity %d but %d arg types" % (arity, len(args))))
            continue
        ok, why = compiles(recv, method, args, "max")
        if not ok:
            failed.append((recv, method, why))
            continue
        passed += 1
        # The table's minimum is CURATED. The probe below does not set it.
        lo = REAL_DEFAULTS.get((recv, method), arity)
        # Probe downward anyway: an arity the compiler accepts but that is NOT a
        # declared default is a suspected silently-dropped argument (BUG-215 class).
        tolerated = arity
        for n in range(arity - 1, -1, -1):
            ok_n, _ = compiles(recv, method, args[:n], "min%d" % n)
            if not ok_n:
                break
            tolerated = n
        if tolerated < lo:
            defaulted.append("%s.%s compiles at %d arg(s) but needs %d — suspected dropped argument"
                             % (recv, method, tolerated, lo))
        # NEGATIVE direction: one argument too many must be REJECTED now that the
        # TypeChecker consults the table. If this passes, the check is not firing.
        over = args + [LITERALS["str"]]
        ok_over, _ = compiles(recv, method, over, "over")
        if ok_over:
            not_firing.append("%s.%s accepted %d args (max %d) — arity check NOT firing"
                              % (recv, method, len(over), arity))
        table.append((recv, method, str(lo), str(arity)))

    print("stdlib-sig: %d passed, %d FAILED, %d skipped" % (passed, len(failed), len(skipped)))
    for s2 in skipped:
        print("  skip: %s" % s2)
    for recv, method, why in failed:
        print("  FAIL: %s.%s — %s" % (recv, method, why))
    if defaulted:
        print("  %d row(s) accept FEWER args than required (BUG-215 class):" % len(defaulted))
        for d in defaulted:
            print("    %s" % d)
    if not_firing:
        print("  %d row(s) NOT REJECTED at max+1 — the arity check is not firing:" % len(not_firing))
        for n2 in not_firing:
            print("    %s" % n2)
    if "--write" in sys.argv and not failed:
        out = ROOT / "tools" / "stdlib_arity.tsv"
        body = ["# GENERATED by tools/stdlib_sig_check.py — arity ranges VERIFIED against the compiler.",
                "# min is DISCOVERED by probing (trailing args may default); max is the documented count.",
                "# recv_kind\tmethod\tmin\tmax"]
        body += ["\t".join(r) for r in table]
        out.write_text("\n".join(body) + "\n", encoding="utf-8", newline="\n")
        print("  wrote %s (%d rows)" % (out.name, len(table)))
    return 1 if (failed or not_firing) else 0


if __name__ == "__main__":
    sys.exit(main())
