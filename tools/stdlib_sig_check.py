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

  python tools/stdlib_sig_check.py           # check every row
  python tools/stdlib_sig_check.py --only X  # just the rows whose method matches X
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

    passed, failed, skipped = 0, [], []
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
        src = work / ("sig_%s_%s.zbr" % (recv.replace("(", "_").replace(")", ""), method))
        src.write_text(program_for(recv, method, args), encoding="utf-8", newline="\n")
        r = subprocess.run([str(ZEBRA), "-c", str(src)],
                           capture_output=True, text=True, env=env, timeout=180)
        if r.returncode == 0:
            passed += 1
        else:
            detail = (r.stdout + r.stderr).strip().split("\n")
            detail = [d for d in detail if "error" in d.lower()]
            failed.append((recv, method, detail[0] if detail else "exit %d" % r.returncode))

    print("stdlib-sig: %d passed, %d FAILED, %d skipped" % (passed, len(failed), len(skipped)))
    for s in skipped:
        print("  skip: %s" % s)
    for recv, method, why in failed:
        print("  FAIL: %s.%s — %s" % (recv, method, why))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
