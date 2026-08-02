#!/usr/bin/env python3
"""hazard_lint.py -- static gate over the REPO'S OWN TOOLING (static, instant, no build).

Every other lint in `tools/` looks at Zebra code.  This one looks at the scripts we use
to measure Zebra code, because that is where the expensive mistakes of 2026-07/08 were:
five bugs in `tools/mutation_check.py` in two days, **none of which crashed, warned, or
exited non-zero.**  Each produced a confident, plausible, wrong number, and two of them
were published before being caught.

The rule this file exists to make mechanical is in `docs/testing_strategy.md` 3b:

    Prose is not a control.  CLAUDE.md documents the CRLF trap in a section of its own,
    and that did not stop the author who had read it that week from writing it.

So a hazard with a receipt does not get a paragraph.  It gets a check that fails.

Every hazard below cites the incident that earned it.  A hazard with no receipt does not
belong here -- speculative rules train people to suppress the tool.

Suppression
-----------
Put `# hazard-ok: <reason>` (or `# hazard-ok:H2 <reason>`) on the flagged line.  A reason
is required; a bare marker is itself reported, because an unexplained suppression is how
a gate goes quiet.

Self-test
---------
`--selftest` runs every check against embedded known-bad snippets and fails if any check
does NOT fire.  It runs automatically before every real scan, and a scan REFUSES to report
"clean" if a control did not fire -- the point of the whole exercise being that a checker
which has stopped checking must never look like a checker that found nothing.

Historical control (the reason to believe this tool at all)
----------------------------------------------------------
A self-test proves the checks fire on defects *written to be found by them*, which is
circular.  The non-circular check is to run this against the revision that actually
shipped the bugs.  `--rev 7156d3e` does that, and reports:

    :301 [H1] write_text() without newline="\n"        <- bug 3, the 241 fabricated detections
    :185 [H3] constant fallback inside emit_fingerprint <- bug 5, the "0 survivors" headline
    :184 [H4] compiler-SPECIFIC emit header             <- bug 5's root cause

Three of the five two-day bugs, statically, in milliseconds, on the commit that published
them.  Bugs 1 (worktree could not build) and 2 (WSL `bash`) are not visible to a static
checker in that revision -- 2 was fixed before it was ever committed, and 1 is an
environment fact, not a text pattern.  Both are covered instead by the harness's own
baseline control, which is the other half of the discipline.

Exit status: 0 = clean, 1 = at least one hazard, 2 = the checker itself is not working.
"""
import ast
import re
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent

# Files this tool scans.  Deliberately the tooling, not the whole repo.
SCAN_GLOBS = ["tools/*.py", "tools/*.sh", "fuzz/*.py", "*.py"]

SUPPRESS = re.compile(r"#\s*hazard-ok(?::(\w+))?\s*(.*)$")


class Hazard:
    def __init__(self, code, path, line, msg):
        self.code, self.path, self.line, self.msg = code, path, line, msg

    def __str__(self):
        rel = self.path
        return f"{rel}:{self.line}: [{self.code}] {self.msg}"


def suppressed(src_lines, lineno, code):
    """A `# hazard-ok` on the flagged line, WITH a reason.  Bare markers are reported."""
    if not (1 <= lineno <= len(src_lines)):
        return False
    m = SUPPRESS.search(src_lines[lineno - 1])
    if not m:
        return False
    want, reason = m.group(1), (m.group(2) or "").strip()
    if want and want != code:
        return False
    return bool(reason)


def bare_suppression(src_lines, lineno):
    m = SUPPRESS.search(src_lines[lineno - 1]) if 1 <= lineno <= len(src_lines) else None
    return bool(m) and not (m.group(2) or "").strip()


# --------------------------------------------------------------------------- H1
# RECEIPT: mutation_check.py restored a mutated .zbr with
#     src.write_text(original, encoding="utf-8")        # no newline="\n"
# On Windows that writes CRLF; the Zebra tokenizer rejects a lone CR.  The source stayed
# corrupt for the rest of the run, every later regeneration failed for that reason alone,
# and the harness scored 241 of 300 mutants as "the bootstrap refused this mutant".  The
# conclusion drawn from it (self-hosting is a strong safety net) was published and then
# retracted.  The APPLY site three lines above had newline="\n"; the restore did not.
#
# Scope note: this fires on any text write in a file that mentions `.zbr` anywhere,
# because the failing write was `src.write_text(...)` where `src` came from a module-level
# TARGETS list far away.  Dataflow-precise detection would not have caught the real bug.
def check_h1(path, text, lines, tree):
    if ".zbr" not in text:
        return []
    hits = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        kwargs = {k.arg for k in node.keywords if k.arg}
        what = None
        if isinstance(node.func, ast.Attribute) and node.func.attr == "write_text":
            what = "write_text()"
        elif isinstance(node.func, ast.Name) and node.func.id == "open":
            mode = ""
            if len(node.args) > 1 and isinstance(node.args[1], ast.Constant):
                mode = str(node.args[1].value)
            for k in node.keywords:
                if k.arg == "mode" and isinstance(k.value, ast.Constant):
                    mode = str(k.value.value)
            # The target must NAME a .zbr. An open() handed straight to subprocess as a
            # stdout handle does no Python-level newline translation, so a file-level
            # guard alone produces noise here -- tools/scaling_probe.py:59 opening a
            # '.zig' redirect target was the false positive that established this.
            target = ast.get_source_segment(text, node.args[0]) if node.args else ""
            if ("w" in mode or "a" in mode) and "b" not in mode and "zbr" in (target or ""):
                what = f"open(..., {mode!r})"
        if what and "newline" not in kwargs:
            hits.append(Hazard("H1", path, node.lineno,
                               f"{what} without newline=\"\\n\" in a script that touches "
                               f".zbr files -- Windows writes CRLF and the Zebra tokenizer "
                               f"rejects a lone CR (error.UnexpectedCharacter)"))
    return hits


# --------------------------------------------------------------------------- H2
# RECEIPT: mutation_check.py invoked the boundary detector as ["bash", "tools/..."].
# On this machine bare `bash` resolves to WSL, which translates paths to /mnt/c and runs
# a different filesystem view; the detector silently failed and every mutant looked
# detected.  Caught by the harness's own baseline check -- i.e. by a positive control,
# which is the only reason it was not a third published wrong number.
# Also: CLAUDE.md/memory record that wsl-prefixed commands prompt Sean interactively.
def prose_lines(text):
    """1-based line numbers spanned by a MULTI-LINE string literal.

    Prose EXPLAINING a hazard must not be reported AS the hazard -- the same reasoning
    that makes H4 skip `#` comments. A checker that punishes the documentation teaches
    people to delete the documentation, and the docstring is where the receipt lives.
    Found when H2 flagged its own explanation inside tools/doc_lint.py.

    Only MULTI-line strings are skipped, so a real single-line `["bash", ...]` argument
    list is still checked. tokenize rather than a delimiter scanner: it gets raw strings,
    f-strings and nesting right, and it cannot be confused by a quote inside a comment.
    """
    import io
    import tokenize
    inside = set()
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.STRING and tok.end[0] > tok.start[0]:
                inside.update(range(tok.start[0], tok.end[0] + 1))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass          # an unparseable file is H0's problem, not this helper's
    return inside


BASH_CONST = re.compile(r"""["'](?:bash|sh)["']""")
WSL_CALL = re.compile(r"""(^|[\s"'\[(=])wsl(\.exe)?[\s"']""")


def check_h2(path, text, lines, tree=None):
    hits = []
    prose = prose_lines(text) if path.endswith(".py") else set()
    for i, ln in enumerate(lines, 1):
        if i in prose:
            continue
        stripped = ln.split("#")[0]
        if BASH_CONST.search(stripped) and ("subprocess" in text or "run(" in text):
            hits.append(Hazard("H2", path, i,
                               'bare "bash"/"sh" as a command -- resolves to WSL on this '
                               'machine (path translation to /mnt/c). Use the Git Bash '
                               r'path: r"C:\Program Files\Git\bin\bash.exe"'))
        if WSL_CALL.search(stripped):
            hits.append(Hazard("H2", path, i,
                               "wsl-prefixed command -- prompts interactively on this "
                               "machine and must not appear in an unattended tool"))
    return hits


# --------------------------------------------------------------------------- H3
# RECEIPT: mutation_check.py's emit_fingerprint() did
#     h.update((out[out.index(m):] if m in out else f"<FAIL {rc}>").encode())
# The marker was never found (H4), so the sentinel was hashed EVERY time and the
# fingerprint was a constant.  Every mutant compared equal to the baseline, was filed
# NO-EFFECT, and the run reported "0 survivors" having never looked at emitted code.
#
# The class, stated generally: a silent constant fallback on a path that feeds a
# comparison always biases toward "nothing changed" -- the answer that ends the
# investigation.  A function that cannot compute its answer must return None or raise.
FINGERPRINT_FN = re.compile(r"finger|hash|digest|checksum|signature", re.I)


def _yields_constant(node):
    if isinstance(node, (ast.Constant, ast.JoinedStr)):
        return True
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        return node.func.attr == "format" and isinstance(node.func.value, ast.Constant)
    return False


def check_h3(path, text, lines, tree):
    hits = []
    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        body = ast.dump(fn)
        if not (FINGERPRINT_FN.search(fn.name) or "hashlib" in body or "sha1" in body
                or "md5" in body or "sha256" in body):
            continue
        for node in ast.walk(fn):
            if isinstance(node, ast.IfExp) and _yields_constant(node.orelse):
                hits.append(Hazard("H3", path, node.lineno,
                                   f"constant fallback inside `{fn.name}` -- a sentinel on "
                                   f"a path that feeds a comparison makes the comparison "
                                   f"always-equal. Return None (and let the caller treat "
                                   f"that as the interesting verdict) instead"))
            if isinstance(node, ast.ExceptHandler):
                for st in node.body:
                    if isinstance(st, ast.Return) and st.value is not None \
                            and _yields_constant(st.value):
                        hits.append(Hazard("H3", path, st.lineno,
                                           f"`except:` in `{fn.name}` returns a constant -- "
                                           f"a failure that hashes to a fixed value is "
                                           f"indistinguishable from an unchanged input"))
    return hits


# --------------------------------------------------------------------------- H4
# RECEIPT: the same emit_fingerprint() searched for "// Generated by the Zebra compiler."
# while running the SELFHOST, which emits "// Generated by zebra-selfhost." (plus
# "-selfhost (node-addon)" and "-selfhost (single-file)" variants).  Two compilers, two
# headers, and the literal was checked against neither emitter.
#
# `// Generated by` is the common prefix.  Use it unless you specifically intend to tell
# the two compilers apart -- and if you do, suppress with a reason saying so.
FULL_HEADERS = re.compile(
    r"//\s*Generated by (?:the Zebra compiler|zebra-selfhost)")


def check_h4(path, text, lines, tree=None):
    hits = []
    for i, ln in enumerate(lines, 1):
        if ln.lstrip().startswith("#"):
            continue      # a comment EXPLAINING the two headers is the fix, not the bug
        if FULL_HEADERS.search(ln):
            hits.append(Hazard("H4", path, i,
                               "compiler-SPECIFIC emit header. The bootstrap writes "
                               "'// Generated by the Zebra compiler.', the selfhost "
                               "'// Generated by zebra-selfhost.'. Match the common prefix "
                               "'// Generated by' unless distinguishing them is the point"))
    return hits


# --------------------------------------------------------------------------- H5
# RECEIPT: recorded as a standing hazard before this tool existed -- an `--emit-zig`
# corpus sweep pollutes the tree with generated files, and `git checkout -- .` next to
# uncommitted work destroys it.  Safe inside a throwaway worktree, which is what the
# suppression reason is for.
GIT_NUKE = re.compile(r"""git["'\s,\]]+checkout["'\s,\]]+--["'\s,\]]+\.""")


def check_h5(path, text, lines, tree=None):
    return [Hazard("H5", path, i,
                   "`git checkout -- .` discards ALL uncommitted work in the tree. Scope it "
                   "to explicit paths, or suppress with a reason if this runs in a "
                   "throwaway worktree")
            for i, ln in enumerate(lines, 1) if GIT_NUKE.search(ln)]



# --------------------------------------------------------------------------- H6
# RECEIPT: mutation_check.py chose mutation sites with candidate_sites(REPO / rel) and
# then applied the resulting (line, col_start, col_end) to wt / rel -- the WORKTREE copy.
# Two different files: the worktree sits at the commit it was created from, the main
# checkout carries uncommitted work, and this repo regularly has a parallel session
# editing selfhost/*.zbr. CodeGen.zbr was 16,539 lines in one and 16,521 in the other;
# line 14831 was `if args.len > 0` here and `else` there. Mutations landed on unrelated
# lines, corrupted the source, and the bootstrap's refusal was scored as a RESULT --
# 18 of the first 43 mutants, all fabricated.
#
# The class: the SAME relative path resolved against TWO different roots in one module is
# almost always a mistake, and it is a silent one, because both paths exist and both open
# successfully. Nothing errors; you just read A and write B.
ROOT_HINT = re.compile(r"^(repo|root|wt|worktree|base|src_?dir|dest|target)", re.I)


def check_h6(path, text, lines, tree):
    joins = {}          # rel-name -> {root-name: lineno}
    for node in ast.walk(tree):
        if not (isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div)):
            continue
        if not (isinstance(node.left, ast.Name) and isinstance(node.right, ast.Name)):
            continue
        root, rel = node.left.id, node.right.id
        if not ROOT_HINT.match(root):
            continue
        joins.setdefault(rel, {}).setdefault(root, node.lineno)
    hits = []
    for rel, roots in joins.items():
        if len(roots) < 2:
            continue
        where = ", ".join(f"{r} (line {ln})" for r, ln in sorted(roots.items(),
                                                                key=lambda kv: kv[1]))
        hits.append(Hazard("H6", path, min(roots.values()),
                           f"`{rel}` is resolved against {len(roots)} different roots -- "
                           f"{where}. Reading one and writing the other is silent: both "
                           f"paths exist and both open fine. If deliberate, suppress with "
                           f"a reason saying which is authoritative"))
    return hits


PY_CHECKS = [check_h1, check_h2, check_h3, check_h4, check_h5, check_h6]
SH_CHECKS = [check_h2, check_h4, check_h5]


def scan_text(path, text):
    lines = text.splitlines()
    hits = []
    if path.endswith(".py"):
        try:
            tree = ast.parse(text)
        except SyntaxError as e:
            return [Hazard("H0", path, e.lineno or 1, f"cannot parse: {e.msg}")]
        for chk in PY_CHECKS:
            hits.extend(chk(path, text, lines, tree))
    else:
        for chk in SH_CHECKS:
            hits.extend(chk(path, text, lines))
    out = []
    for h in hits:
        if suppressed(lines, h.line, h.code):
            continue
        out.append(h)
    for i, ln in enumerate(lines, 1):
        if bare_suppression(lines, i):
            out.append(Hazard("H9", path, i,
                              "`# hazard-ok` with no reason -- an unexplained suppression "
                              "is how a gate goes quiet. State why it is safe"))
    return out


# ------------------------------------------------------------------ positive controls
# One planted defect per check.  If a check stops firing on its own control, the scan is
# not allowed to report "clean" -- see docs/testing_strategy.md 3b rule 1.
CONTROLS = {
    "H1": ("ctl_h1.py", 'import pathlib\n'
                        'p = pathlib.Path("selfhost/CodeGen.zbr")\n'
                        'p.write_text("x", encoding="utf-8")\n'),
    "H1open": ("ctl_h1open.py", 'f = open("selfhost/Parser.zbr", "w")\n'
                                'f.write("x")\n'),
    "H2": ("ctl_h2.py", 'import subprocess\n'
                        'subprocess.run(["bash", "tools/gates.sh"])\n'),
    "H3": ("ctl_h3.py", 'import hashlib\n'
                        'def fingerprint(out, rc):\n'
                        '    h = hashlib.sha1()\n'
                        '    h.update((out if "M" in out else "<FAIL>").encode())\n'
                        '    return h.hexdigest()\n'),
    "H4": ("ctl_h4.py", 'MARKER = "// Generated by the Zebra compiler."\n'),
    "H5": ("ctl_h5.sh", 'git checkout -- .\n'),
    "H6": ("ctl_h6.py", 'REPO = 1\nwt = 2\nrel = "a.zbr"\n'
                        'a = REPO / rel\nb = wt / rel\n'),
    "H9": ("ctl_h9.py", 'import pathlib  # hazard-ok\n'),
}


def selftest(verbose=False):
    """Returns the set of codes that FAILED to fire on their own planted defect."""
    dead = set()
    for code, (name, src) in CONTROLS.items():
        fired = {h.code for h in scan_text(name, src)}
        # Some controls exercise a distinct ARM of a check and share its code.
        want = code.rstrip("open") if code.endswith("open") else code
        if want not in fired:
            dead.add(code)
        if verbose:
            mark = "ok  " if code not in dead else "DEAD"
            print(f"  [{mark}] {code} control -> fired {sorted(fired) or 'nothing'}")
    return dead


def main():
    argv = sys.argv[1:]
    if "--selftest" in argv:
        print("hazard_lint self-test (each check against its own planted defect):")
        dead = selftest(verbose=True)
        if dead:
            print(f"\n[hazard-lint] SELF-TEST FAILED: {sorted(dead)} did not fire")
            return 2
        print(f"\n[hazard-lint] self-test OK: {len(CONTROLS)} controls all fired")
        return 0

    dead = selftest()
    if dead:
        print(f"[hazard-lint] REFUSING TO REPORT: checks {sorted(dead)} no longer fire on "
              f"their own controls. A scan now would look clean because the checker is "
              f"broken, not because the tree is. Run --selftest.")
        return 2

    if "--rev" in argv:
        # Falsifiable historical control: lint a past revision of the tooling and show
        # what this checker would have said on the day the bug shipped.
        import subprocess
        rev = argv[argv.index("--rev") + 1]
        paths = [a for a in argv if not a.startswith("-") and a != rev] or \
                ["tools/mutation_check.py"]
        total = 0
        for rel in paths:
            try:
                src = subprocess.run(["git", "show", f"{rev}:{rel}"], cwd=str(REPO),
                                     capture_output=True, check=True).stdout.decode(
                                         "utf-8", "replace")
            except subprocess.CalledProcessError:
                print(f"{rel}: not present at {rev}")
                continue
            hits = scan_text(f"{rev}:{rel}", src)
            for h in hits:
                print(h)
            total += len(hits)
        print(f"\n[hazard-lint] {total} hazard(s) at revision {rev}")
        return 0

    pats = [a for a in argv if not a.startswith("-")]
    files = []
    for pat in (pats or SCAN_GLOBS):
        files.extend(sorted(REPO.glob(pat)))

    hits = []
    for f in files:
        if f.name == "hazard_lint.py":
            continue           # the controls above are deliberate known-bad text
        try:
            text = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        hits.extend(scan_text(f.relative_to(REPO).as_posix(), text))

    for h in sorted(hits, key=lambda h: (h.code, h.path, h.line)):
        print(h)
    print(f"\n[hazard-lint] {len(hits)} hazard(s) across {len(files)} file(s); "
          f"{len(CONTROLS)} controls fired")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
