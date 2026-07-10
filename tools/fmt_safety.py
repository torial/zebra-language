#!/usr/bin/env python3
"""Safety gate for `zebra fmt` (the whitespace/formatter pass).

Three checks, strongest first:

1. STRING PRESERVATION — format fixtures full of tricky strings (regular with
   escapes, raw `r"…"`/`r'…'`, no-sub `ns'…'`, triple-quoted multi-line blocks,
   char literals, `#` comments) and assert the protected content is byte-for-byte
   unchanged while interior code spacing is collapsed.

2. EMIT-EQUIVALENCE — for every real source file, emit Zig before and after
   formatting a copy; the emitted Zig must be identical (formatting must never
   change program semantics).

3. IDEMPOTENCE — format(format(x)) == format(x).
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZEBRA = os.path.join(ROOT, "zig-out", "bin", "zebra.exe")

passed = 0
failed = 0


def check(cond, name, detail=""):
    global passed, failed
    if cond:
        print("  PASS: %s" % name); passed += 1
    else:
        print("  FAIL: %s%s" % (name, ("  — " + detail) if detail else "")); failed += 1


def fmt_text(text):
    """Format a source string via `zebra fmt <tmpfile>` (in-place) and return it."""
    d = tempfile.mkdtemp()
    try:
        p = os.path.join(d, "f.zbr")
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        subprocess.run([ZEBRA, "fmt", p], capture_output=True, timeout=30)
        with open(p, "r", encoding="utf-8") as fh:
            return fh.read()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def emit_zig(path, out_dir):
    """Emit Zig for `path` into out_dir; return the .zig text (minus source-path
    comments) or None.  `// Source:` and `// zbr:<path>:<line>` embed the input
    file path, which differs between the original and a temp-dir copy — strip
    those lines so the comparison sees only real code."""
    os.makedirs(out_dir, exist_ok=True)
    subprocess.run([ZEBRA, "--emit-zig", "--output-dir", out_dir, path],
                   capture_output=True, timeout=120)
    base = os.path.splitext(os.path.basename(path))[0] + ".zig"
    zp = os.path.join(out_dir, base)
    if not os.path.exists(zp):
        return None
    with open(zp, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    kept = [ln for ln in lines
            if not ln.startswith("// Source:") and not ln.startswith("// zbr:")]
    return "\n".join(kept)


def test_string_preservation():
    print("[1] string preservation")
    # (name, input, must-appear-verbatim-in-output substrings, must-NOT-appear)
    cases = [
        ("interior collapse",
         "def f()\n    var x  =  1\n",
         ["var x = 1"], ["x  =", "=  1"]),
        ("leading indent kept",
         "def f()\n        var x = 1\n",
         ["        var x = 1"], []),
        ("regular string content",
         'def f()\n    var s = "a  b   c"\n',
         ['"a  b   c"'], []),
        ("escaped quote in string",
         'def f()\n    var s = "a\\"  b"\n',
         ['"a\\"  b"'], []),
        ("comment content kept",
         "def f()\n    var x = 1  # a  b   c\n",
         ["# a  b   c"], []),
        ("raw double string",
         'def f()\n    var r = r"\\d+  \\w+"\n',
         ['r"\\d+  \\w+"'], []),
        ("raw single w/ dquotes",
         "def f()\n    var j = r'{\"k\":  \"v\"}'\n",
         ["r'{\"k\":  \"v\"}'"], []),
        ("char literal",
         "def f()\n    var c = ' '\n",
         ["' '"], []),
        ("triple single-line",
         'def f()\n    var q = """a  b   c"""\n',
         ['"""a  b   c"""'], []),
        ("triple multi-line block",
         'def f()\n    var h = """\n    <a>  двойной   space</a>\n        deep   indent\n    """\n',
         ["    <a>  двойной   space</a>", "        deep   indent"], []),
        ("code after triple close collapses",
         'def f()\n    var q = """x"""  +  y()\n',
         ['"""x""" + y()'], ['"""  +']),
    ]
    for name, inp, musts, mustnots in cases:
        out = fmt_text(inp)
        ok = all(m in out for m in musts) and all(mn not in out for mn in mustnots)
        check(ok, name, "got:\n%s" % out if not ok else "")


def test_emit_equivalence_and_idempotence():
    print("[2] emit-equivalence + [3] idempotence over real sources")
    files = []
    for sub in ("selfhost", "test"):
        base = os.path.join(ROOT, sub)
        for dirpath, _, names in os.walk(base):
            for nm in names:
                if nm.endswith(".zbr"):
                    files.append(os.path.join(dirpath, nm))
    files.sort()
    print("  (%d .zbr files)" % len(files))

    changed = 0
    emit_diffs = []
    idem_diffs = []
    emit_checked = 0
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            orig = fh.read()
        f1 = fmt_text(orig)
        f2 = fmt_text(f1)
        if f1 != f2:
            idem_diffs.append(path)
        if f1 != orig:
            changed += 1
            # Only the files formatting actually CHANGES need the emit check.
            d = tempfile.mkdtemp()
            try:
                fp = os.path.join(d, os.path.basename(path))
                with open(fp, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(f1)
                before = emit_zig(path, os.path.join(d, "before"))
                after = emit_zig(fp, os.path.join(d, "after"))
                if before is not None and after is not None:
                    emit_checked += 1
                    if before != after:
                        emit_diffs.append(path)
            finally:
                shutil.rmtree(d, ignore_errors=True)

    print("  formatting changed %d/%d files; emit-checked %d changed files"
          % (changed, len(files), emit_checked))
    check(not idem_diffs, "idempotent on every source",
          "non-idempotent: " + ", ".join(idem_diffs[:5]))
    check(not emit_diffs, "emitted Zig identical before/after format",
          "emit changed: " + ", ".join(emit_diffs[:5]))


def main():
    if not os.path.exists(ZEBRA):
        print("FAIL: zebra.exe not built", file=sys.stderr); return 1
    test_string_preservation()
    test_emit_equivalence_and_idempotence()
    print("fmt safety: %d/%d passed" % (passed, passed + failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
