#!/usr/bin/env python3
"""doc_lint.py -- check the CHECKABLE claims in this repo's documentation.

Most of what the docs assert ("this gate is blind to X") cannot be verified mechanically.
A useful minority can be, and it is the minority that rots fastest, because it is exactly
what changes when a tool is renamed, split, retired, or never written in the first place.

RECEIPT
-------
On 2026-07-31 a claim -- "no corpus file uses this form" -- appeared in FOUR documents at
once.  It was inferred from a gate's silence rather than checked, and one `grep` refuted
it.  That specific claim is not machine-checkable, but its FAMILY is: a document referring
to something that does not exist, or failing to refer to something that does.  Every check
below is of that family, and every one of them has been wrong in this repo at some point.

WHAT IT CHECKS
--------------
  D1  a `tools/x.sh` or `tools/x.py` named in a .md actually exists
  D2  a `docs/x.md` (or other repo path) linked from a .md actually exists
  D3  every gate registered in tools/gates.sh is described in CLAUDE.md
  D4  a BUG-NNN cited in the docs exists in BUGS.md
  D5  a fenced `bash`/`sh` block invoking `tools/...` names a script that exists

Suppress a deliberate reference to something that does not exist -- a PROPOSED tool, a
historical note -- with `<!-- doc-lint-ok: <reason> -->` on the same line. A reason is
required.

WHAT IT DELIBERATELY DOES NOT CHECK
-----------------------------------
Prose claims about behaviour, coverage numbers, and "blind to" statements.  Those need a
human or an experiment; pretending otherwise would make this tool a source of false
assurance, which is the failure mode the rest of the tooling work this week was about.
The uncovered set is printed on every run so it cannot quietly be forgotten.

Exit status: 0 = clean, 1 = at least one stale reference, 2 = the checker is not working.
"""
import re
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent

DOC_GLOBS = ["*.md", "docs/*.md"]

# `tools/foo.sh`, tools/foo.py, bash tools/foo.sh -- in prose, backticks or code fences.
TOOL_REF = re.compile(r"\btools/([A-Za-z0-9_.\-]+\.(?:sh|py))")
# A markdown link or bare mention of a repo-relative doc path.
DOC_REF = re.compile(r"\b((?:docs|test|selfhost|src|fuzz|examples|IDE)/[A-Za-z0-9_./\-]+\.[a-z]{2,4})\b")
BUG_REF = re.compile(r"\bBUG-(\d{2,4})\b")
GATE_REG = re.compile(r'^\s*run\s+"([a-z0-9\-]+)"', re.M)

# Same suppression discipline as tools/hazard_lint.py: an HTML comment on the flagged
# line, and a REASON is required. The commonest legitimate case is a PROPOSED tool
# ("proposed lint tool (tools/zbr_dead_code.py)") or a historical note inside an
# otherwise-live document -- neither is a stale reference, but neither is detectable
# from the path alone.
DOC_SUPPRESS = re.compile(r"<!--\s*doc-lint-ok:\s*(.+?)\s*-->")

# Paths that legitimately do not exist: illustrative, generated, or user-supplied.
IGNORE_PATHS = {
    "path/to/file.zbr",
}
IGNORE_PREFIX = ("test/boundary/bv_",)   # probes are enumerated by the runner, not listed

# Metasyntactic stand-ins. `selfhost/foo.zbr` in a worked example is not a stale
# reference, and flagging it teaches people to ignore the tool.
PLACEHOLDER_STEMS = {"foo", "bar", "baz", "qux", "x", "y", "n", "name", "file", "module"}

# APPEND-ONLY RECORDS. A bug entry from March that cites a tool deleted in June is not
# stale -- it is an accurate record of what was true when it was written, and "fixing" it
# would be falsifying history. Findings here are reported as INFO and do not fail the
# gate. Everything else is a LIVE document, where a dangling reference is a defect.
HISTORICAL = {"BUGS.md", "BUGS_FIXED.md", "SELFHOST_JOURNAL.md", "CHANGELOG.md"}


def is_historical(rel):
    return rel in HISTORICAL or rel.startswith("docs/PROJECT_AUDIT_")


class Finding:
    def __init__(self, code, doc, line, msg):
        self.code, self.doc, self.line, self.msg = code, doc, line, msg

    def __str__(self):
        return f"{self.doc}:{self.line}: [{self.code}] {self.msg}"


def docs():
    out = []
    for g in DOC_GLOBS:
        out.extend(sorted(REPO.glob(g)))
    return out


def check_refs(path, text):
    """D1/D2/D5 -- a referenced repo path must exist."""
    rel = path.relative_to(REPO).as_posix()
    hits = []
    in_fence = False
    for i, ln in enumerate(text.splitlines(), 1):
        if ln.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        m_sup = DOC_SUPPRESS.search(ln)
        if m_sup and m_sup.group(1):
            continue
        # D1 is checked INSIDE fences too: a fenced block is usually a command someone is
        # meant to run, so a tool named there had better exist. D2 is not: inside a fence,
        # a repo-shaped path is far more often an illustration of a user's own project
        # layout (`src/main.zbr` in QUICKSTART) than a claim about this tree.
        for m in TOOL_REF.finditer(ln):
            target = "tools/" + m.group(1)
            # Same placeholder rule as D2: `tools/x.sh` in a description of what the
            # checker looks for is a stand-in, not a claim. (Caught immediately by the
            # tool itself, on the CLAUDE.md paragraph documenting the tool.)
            if pathlib.PurePosixPath(target).stem.lower() in PLACEHOLDER_STEMS:
                continue
            if not (REPO / target).exists():
                hits.append(Finding("D1", rel, i, f"references `{target}`, which does not exist"))
        if in_fence:
            continue
        for m in DOC_REF.finditer(ln):
            target = m.group(1)
            if target in IGNORE_PATHS or target.startswith(IGNORE_PREFIX):
                continue
            if "*" in target or "?" in target:
                continue
            stem = pathlib.PurePosixPath(target).stem.lower()
            if stem in PLACEHOLDER_STEMS:
                continue
            if target.endswith(".cxx"):
                continue      # third-party sources (Scintilla), not paths in this repo
            if not (REPO / target).exists():
                hits.append(Finding("D2", rel, i, f"references `{target}`, which does not exist"))
    return hits


def check_bugs(path, text, known):
    rel = path.relative_to(REPO).as_posix()
    hits = []
    if rel in ("BUGS.md", "BUGS_FIXED.md"):
        return hits      # the ledgers themselves define the known set
    for i, ln in enumerate(text.splitlines(), 1):
        for m in BUG_REF.finditer(ln):
            n = m.group(1).lstrip("0") or "0"
            if n not in known:
                hits.append(Finding("D4", rel, i,
                                    f"cites BUG-{m.group(1)}, which is not in BUGS.md"))
    return hits


def check_gates(claude_text):
    """D3 -- a gate that runs but is undocumented is how a tier's meaning drifts."""
    gates_sh = REPO / "tools/gates.sh"
    if not gates_sh.exists() or claude_text is None:
        return []
    registered = set(GATE_REG.findall(gates_sh.read_text(encoding="utf-8")))
    hits = []
    for g in sorted(registered):
        # The gate's own name, or the script it runs, should appear in CLAUDE.md.
        if g not in claude_text and g.replace("-", "_") not in claude_text:
            hits.append(Finding("D3", "CLAUDE.md", 1,
                                f"gate `{g}` runs in tools/gates.sh but is not described "
                                f"in CLAUDE.md -- an undocumented gate is how a tier's "
                                f"meaning drifts"))
    return hits


# --------------------------------------------------------------- positive controls
# Same discipline as tools/hazard_lint.py: a checker that has stopped checking must not
# look like a checker that found nothing.
CONTROLS = {
    "D1": "see `tools/definitely_not_a_real_tool.sh` for details\n",
    "D2": "described in `docs/definitely_not_a_real_doc.md`\n",
    "D4": "this was fixed in BUG-9997\n",
}


def selftest(verbose=False):
    dead = set()
    known = {"1"}
    for code, text in CONTROLS.items():
        fake = REPO / "CONTROL.md"
        hits = check_refs(fake, text) + check_bugs(fake, text, known)
        fired = {h.code for h in hits}
        if code not in fired:
            dead.add(code)
        if verbose:
            print(f"  [{'ok  ' if code not in dead else 'DEAD'}] {code} control -> "
                  f"fired {sorted(fired) or 'nothing'}")
    # D3 has no text-snippet control; it is exercised by construction on every run
    # (it reads the real gates.sh), so an empty registered-set is the failure to catch.
    if not GATE_REG.findall((REPO / "tools/gates.sh").read_text(encoding="utf-8")):
        dead.add("D3")
        if verbose:
            print("  [DEAD] D3 control -> parsed ZERO gates out of tools/gates.sh")
    elif verbose:
        print(f"  [ok  ] D3 control -> parsed "
              f"{len(set(GATE_REG.findall((REPO / 'tools/gates.sh').read_text(encoding='utf-8'))))} "
              f"gates out of tools/gates.sh")
    return dead


UNCOVERED = [
    "prose claims about BEHAVIOUR ('this gate is blind to X') -- needs an experiment",
    "coverage counts in prose ('327 of 335 files') -- drift silently, no cheap oracle",
    "whether a described workflow still WORKS -- only running it proves that",
    "claims inferred from a gate's SILENCE -- the 2026-07-31 receipt above was one",
]


def main():
    argv = sys.argv[1:]
    if "--selftest" in argv:
        print("doc_lint self-test (each check against its own planted defect):")
        dead = selftest(verbose=True)
        if dead:
            print(f"\n[doc-lint] SELF-TEST FAILED: {sorted(dead)} did not fire")
            return 2
        print(f"\n[doc-lint] self-test OK")
        return 0

    dead = selftest()
    if dead:
        print(f"[doc-lint] REFUSING TO REPORT: checks {sorted(dead)} no longer fire on "
              f"their own controls. Run --selftest.")
        return 2

    # A ticket is "known" if it appears in EITHER ledger -- fixed bugs move to
    # BUGS_FIXED.md, and a doc citing one is citing something real.
    known = set()
    for ledger in ("BUGS.md", "BUGS_FIXED.md"):
        f = REPO / ledger
        if f.exists():
            known |= {m.lstrip("0") or "0"
                      for m in BUG_REF.findall(f.read_text(encoding="utf-8"))}

    claude = REPO / "CLAUDE.md"
    claude_text = claude.read_text(encoding="utf-8") if claude.exists() else None

    hits = []
    files = docs()
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        hits.extend(check_refs(f, text))
        hits.extend(check_bugs(f, text, known))
    hits.extend(check_gates(claude_text))

    live = [h for h in hits if not is_historical(h.doc)]
    hist = [h for h in hits if is_historical(h.doc)]

    for h in sorted(live, key=lambda h: (h.code, h.doc, h.line)):
        print(h)
    if hist:
        print(f"\n  ({len(hist)} more in append-only records "
              f"({', '.join(sorted(HISTORICAL))}, dated audits) -- NOT counted. A bug entry "
              f"citing a tool deleted months later is accurate history, and rewriting it "
              f"would be falsifying the record. `--all` lists them.)")
        if "--all" in argv:
            for h in sorted(hist, key=lambda h: (h.code, h.doc, h.line)):
                print(f"    info {h}")

    hits = live
    print(f"\n[doc-lint] {len(hits)} stale reference(s) across {len(files)} document(s)")
    if "--quiet" not in argv:
        print("  NOT checked (do not read a clean run as 'the docs are accurate'):")
        for u in UNCOVERED:
            print(f"    - {u}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
