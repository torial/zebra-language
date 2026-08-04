#!/usr/bin/env python3
"""doc_example_check.py -- do the code examples in LIVE docs actually compile?

THE HOLE THIS CLOSES
--------------------
224 fenced `zebra` blocks across the docs; before 2026-08-03, **zero** were verified by
anything. Every other gate here protects the compiler from regressing what it already
does. Nothing protected a reader.

That is not theoretical debt. `QUICKSTART.md` -- the file whose own header calls it the
authoritative agent-facing reference -- documented thread spawning as `sys.go(lambda ...)`
in five code blocks. **`lambda` is not a Zebra keyword.** None of those examples had ever
compiled. It was found by trying to follow the doc and failing twice (BUG-245), not by any
instrument.

The governing law, established three times over on 2026-08-03 (BUG-241 Progress, BUG-242
Csv, BUG-245 Shell): **code that nothing executes does not survive a toolchain upgrade,
and nothing tells you.** Doc examples are the largest body of never-executed Zebra in the
repo.

WHAT IS CHECKED, AND WHAT IS DELIBERATELY NOT
---------------------------------------------
Scoped by `doc-status`, the convention `doc_lint` already uses:
  live       -> CHECKED. It claims the language works this way today.
  historical -> skipped. BUGS.md is 24 blocks of deliberately-broken repros; "fixing"
                them would falsify the record.
  design     -> skipped. May describe intent that is not built.
  generated  -> skipped. Edit the tool, not the file.

Blocks are skipped when they are not offered as working code:
  * ELISION (`...`, `..`, `…`) -- advertised as incomplete.
  * COUNTEREXAMPLE -- an inline `# error:` / `# fails` / `# WRONG`, or the same in the
    prose immediately above. Docs legitimately show broken code.
  * `<!-- doc-example-ok: <reason> -->` on the line before the fence. A reason is
    REQUIRED, because an unexplained suppression is how a gate goes quiet.

FRONT END ONLY. This runs `zebra -c`, so it answers "does this parse and resolve?" and NOT
"does the emitted Zig compile?" -- deliberately: a doc fragment has no modules around it,
and a full compile would drown real syntax errors in missing-dependency noise. `-c` is the
level at which a doc example makes its claim.

SIGNAL vs ARTIFACT -- the design decision that makes this gate usable
---------------------------------------------------------------------
A naive "compile every block" run produces ~100 failures on this corpus, ~90% of them
noise. A gate at that ratio gets suppressed wholesale, which is worse than no gate. The
noise is separable by ERROR KIND rather than by guessing at block structure:

  ARTIFACT  "undefined name: 'data'" -- the fragment refers to something introduced in the
            surrounding prose. Says nothing about whether the SYNTAX is valid. NOT gated.
  SIGNAL    "unexpected member: 'lambda'", "expected '(', got X" -- the parser could not
            READ the construct. That is a claim about the language being wrong, and it is
            exactly the shape of the sys.go(lambda ...) bug. GATED.

BASELINED, like full_sweep / bug_fixture / registration: the existing SIGNAL failures are
recorded so this fails only on NEW breakage. A gate that starts life red is a gate people
learn to ignore. Shrink the baseline; do not grow it.

Exit: 0 clean, 1 new signal failure(s), 2 the checker itself is not working.
"""
import hashlib
import pathlib
import re
import subprocess
import sys


def block_key(doc_name, body):
    """Identify a block by its CONTENT, never by its position.

    The first version keyed on `doc#<index>`. Inserting one code block into QUICKSTART
    shifted every later index by one, so five untouched, already-baselined blocks were
    reported as NEW breakage. A block index belongs to a *version of the file*; the
    baseline outlives that version.

    Content hashing has the properties wanted here: moving a block keeps its key (it is
    the same example), and EDITING one changes its key — which is correct, since an edited
    example should be re-judged rather than inheriting a pass.
    """
    h = hashlib.sha1(body.strip().encode("utf-8", "replace")).hexdigest()[:10]
    return f"{doc_name}#{h}"

REPO = pathlib.Path(__file__).resolve().parent.parent
ZEBRA = REPO / "zig-out" / "bin" / "zebra.exe"
BASELINE = REPO / "tools" / "doc_example_baseline.txt"
# SHORT path on purpose: the first version wrote to a ~100-char scratch path and every
# error message was truncated to just the path -- it reported 119 failures and could not
# say why one of them failed.
WORK = pathlib.Path("C:/tmp/zbr-docex") if sys.platform == "win32" else pathlib.Path("/tmp/zbr-docex")

FENCE = re.compile(r'^```zebra[ \t]*$(.*?)^```[ \t]*$', re.M | re.S)
STATUS = re.compile(r'doc-status:\s*([a-z]+)')
SUPPRESS = re.compile(r'<!--\s*doc-example-ok:\s*(.+?)\s*-->')

# Authoritative, read from selfhost/Parser.zbr's top-level dispatch -- NOT guessed. A
# missing keyword here does not fail loudly: it wraps a valid top-level declaration inside
# `def main()` and reports a syntax error that is the harness's fault. `type`, `namespace`,
# `sig`, `static` and `export` were all absent from the first draft and produced exactly
# that -- 12 fake failures.
TOPLEVEL = ("use", "namespace", "class", "struct", "interface", "mixin", "extend",
            "union", "enum", "sig", "type", "static", "export", "def", "var")
# `var` is deliberately EXCLUDED from hoisting even though it is a legal top-level form.
# Hoisting reorders the block, and reordering manufactures failures: a doc block that reads
#     try
#     var r = ...
#     catch |e|
# had its `var` lifted above the loose statements, which SPLIT the `try` from its `catch`
# and reported a syntax error in a block that was never wrong. A `var` left in place lands
# inside the synthesized `main`, which is valid; the worst case is an "undefined name"
# artifact, and those are not gated.
HOISTABLE = tuple(k for k in TOPLEVEL if k != "var")
TOPDECL = re.compile(r'^(' + '|'.join(HOISTABLE) + r')\b')
# Clauses written at COLUMN 0 that CONTINUE the declaration above them rather than starting
# a new one. Zebra's method-level `catch`/`ensure` are the load-bearing case.
CONTINUATION = re.compile(r'^(catch|ensure|require|finally)\b')

ELISION = re.compile(r'\.\.\.|^\s*\.\.\s*$|…', re.M)
# A block advertising that its contents are NOT to be copied. Two conventions are in use:
# an inline `# error:` / `# fails`, and STYLE_GUIDE's `# ✗ Non-canonical (sweep target)`,
# which marks 15 blocks of deliberately-legacy form. Missing the second made the gate
# report a style guide's own counterexamples as breakage -- the loudest possible way to be
# wrong, since those blocks are wrong ON PURPOSE and saying so is their entire job.
COUNTER = re.compile(r'#\s*(error|fails|compile error|does not compile|WRONG|rejected|'
                     r'not allowed|invalid)|✗|non-canonical|sweep target|'
                     r'#\s*(avoid|do not|don.t)\b', re.I)
ARTIFACT = re.compile(r"undefined name|unexpected end of input|"
                      r"must have at least one variant|unknown type|not found|"
                      r"no such module|undeclared|cannot find", re.I)


def assemble(body):
    """Turn a doc block into a compilable unit.

    Docs routinely write a declaration and then loose statements under a `# Use:` heading:

        class Circle
            ...
        var c = Circle(5.0)
        print(c.area())

    Zebra allows `var` at the top level but not `print`, so the block as written is not a
    valid file even though nothing about it is wrong as documentation. Loose statements are
    therefore collected into a synthesized `main`, and declarations are emitted as-is.
    """
    lines = body.strip("\n").split("\n")
    decls, loose = [], []
    i = 0
    while i < len(lines):
        ln = lines[i]
        if not ln.strip() or ln.lstrip().startswith("#"):
            (decls if decls and not loose else loose).append(ln)
            i += 1
            continue
        # An attribute (`@derive(...)`, `@export`, `@tag`, `@reflectable`) introduces the
        # declaration on the FOLLOWING line. Consume it alone and let the next iteration
        # handle the declaration and its body; treating it as a loose statement wrapped it
        # inside `def main()` and produced 5 fake "unexpected expression token: '@derive'"
        # failures.
        if ln.startswith("@"):
            decls.append(ln)
            i += 1
            continue
        if TOPDECL.match(ln):
            decls.append(ln)
            i += 1
            # Its indented body, PLUS any method-level continuation clause. `catch` and
            # `ensure` are written at COLUMN 0 and belong to the `def` above them:
            #     def risky()
            #         var r = divide(10, 0)
            #     catch |e|
            #         print("Error")
            # Verified valid by compiling it. Treating that `catch` as a loose statement
            # moved it into the synthesized main, SPLITTING it from its def, and reported a
            # syntax error in two docs that were both correct.
            while i < len(lines):
                cur = lines[i]
                if not cur.strip() or cur[:1] in (" ", "\t"):
                    decls.append(cur)
                    i += 1
                elif CONTINUATION.match(cur):
                    decls.append(cur)
                    i += 1
                else:
                    break
            continue
        loose.append(ln)
        i += 1

    if not loose or not any(l.strip() and not l.lstrip().startswith("#") for l in loose):
        return "\n".join(decls) + "\n"
    wrapped = "def main()\n" + "".join(
        (("    " + l) if l.strip() else l) + "\n" for l in loose)
    return ("\n".join(decls) + "\n" + wrapped) if decls else wrapped


def live_docs():
    docs = sorted(list(REPO.glob("*.md")) + list(REPO.glob("docs/*.md")))
    out = []
    for d in docs:
        m = STATUS.search(d.read_text(encoding="utf-8", errors="replace")[:200])
        if m and m.group(1) == "live":
            out.append(d)
    return out


def check(src, name):
    f = WORK / f"{name}.zbr"
    # newline='\n' is mandatory. A lone \r crashes the tokenizer with
    # error.UnexpectedCharacter and NO source location, which would look like a doc bug.
    f.write_text(src, encoding="utf-8", newline="\n")
    try:
        r = subprocess.run([str(ZEBRA), "-c", str(f)], capture_output=True,
                           cwd=str(WORK), timeout=120)
    except subprocess.TimeoutExpired:
        return "TIMEOUT while checking"
    if r.returncode == 0:
        return None
    raw = (r.stdout + r.stderr).decode("utf-8", "replace")
    raw = raw.replace(str(WORK) + "\\", "").replace(str(WORK) + "/", "")
    for l in raw.split("\n"):
        if "error" in l.lower():
            return l.strip()
    return (raw.strip().split("\n") or ["unknown failure"])[-1]


def controls():
    """Prove the checker can see, BEFORE trusting anything it reports.

    Derived at runtime rather than pinned to a known-broken doc: a control pinned to a gap
    fails on the day you fix the gap, which is exactly when you least want to be editing
    your instrument.
    """
    good = check('def main()\n    print("ok")\n', "_ctl_good")
    if good is not None:
        return f"a trivially VALID program was rejected ({good})"
    bad = check('def main()\n    this is not zebra @@@\n', "_ctl_bad")
    if bad is None:
        return "a trivially INVALID program was accepted"
    return None


def baselined():
    if not BASELINE.exists():
        return set()
    return {l.strip() for l in BASELINE.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.startswith("#")}


def main():
    argv = sys.argv[1:]
    if not ZEBRA.is_file():
        print(f"REFUSING TO REPORT: {ZEBRA} not built. Nothing could be checked, and a "
              f"clean result here would mean only that.")
        return 2
    WORK.mkdir(parents=True, exist_ok=True)

    err = controls()
    if err:
        print(f"REFUSING TO REPORT: control failed -- {err}.\n"
              f"The checker has stopped checking; any verdict would be fiction.")
        return 2

    docs = live_docs()
    if not docs or not any(d.name == "QUICKSTART.md" for d in docs):
        print(f"REFUSING TO REPORT: {len(docs)} live doc(s) found and QUICKSTART.md is "
              f"not among them. The doc-status scan is broken.")
        return 2

    checked = skipped = passed = 0
    artifacts, signals = [], []
    for d in docs:
        text = d.read_text(encoding="utf-8", errors="replace")
        for i, m in enumerate(FENCE.finditer(text)):
            body = m.group(1)
            if not body.strip():
                continue
            pre = text[max(0, m.start() - 260):m.start()]
            if (SUPPRESS.search(pre) or ELISION.search(body)
                    or COUNTER.search(body) or COUNTER.search(pre)):
                skipped += 1
                continue
            checked += 1
            res = check(assemble(body), f"{d.stem[:8]}_{i}")
            if res is None:
                passed += 1
            elif ARTIFACT.search(res):
                artifacts.append((block_key(d.name, body), res))
            else:
                signals.append((block_key(d.name, body), res))

    keys = sorted(k for k, _ in signals)
    if "--update-baseline" in argv:
        BASELINE.write_text(
            "# Doc examples in LIVE docs whose SYNTAX does not parse -- existing debt,\n"
            "# recorded so the gate fails only on NEW breakage. Shrink this; do not grow\n"
            "# it. Each line is <doc>#<block index>. See tools/doc_example_check.py.\n"
            + "\n".join(keys) + "\n", encoding="utf-8", newline="\n")
        print(f"baseline recorded: {len(keys)} signal failure(s)")
        return 0

    known = baselined()
    new = [(k, msg) for k, msg in signals if k not in known]
    fixed = sorted(known - set(keys))

    # `--show` lists the WHOLE signal set with messages, baselined or not. Without it the
    # only way to see what the baseline contains is to delete it and re-run, which is how
    # a baseline quietly becomes a list nobody can read.
    if "--show" in argv:
        for k, msg in sorted(signals):
            mark = "known" if k in known else " NEW "
            print(f"  [{mark}] {k}: {msg}")
        if artifacts:
            print(f"\n  ({len(artifacts)} fragment artifact(s) not gated:)")
            for k, msg in sorted(artifacts)[:8]:
                print(f"      {k}: {msg}")

    for k, msg in new:
        print(f"  BROKEN EXAMPLE  {k}: {msg}")
    if fixed:
        print(f"  · {len(fixed)} previously-broken example(s) now parse "
              f"(--update-baseline to lock it in): {', '.join(fixed[:6])}"
              + (" …" if len(fixed) > 6 else ""))

    print(f"\n[doc-example] {len(docs)} live doc(s), {checked} block(s) checked, "
          f"{skipped} skipped (elision/counterexample/suppressed)")
    print(f"              {passed} parse, {len(artifacts)} fragment artifact(s) "
          f"(not gated), {len(signals)} syntax failure(s) ({len(known)} known), "
          f"{len(new)} NEW")
    if not argv:
        print("  NOT checked: whether an example is CORRECT, only that it parses and "
              "resolves;\n  and whether its OUTPUT is what the prose claims. `-c` is "
              "front-end only.")
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main())
