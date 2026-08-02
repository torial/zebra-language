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
  D6  a number carrying a `<!-- doc-gen: N = <command> -->` oracle still equals N
  D7  every document declares `<!-- doc-status: live|historical|design|generated -->`

Suppress a deliberate reference to something that does not exist -- a PROPOSED tool, a
historical note -- with `<!-- doc-lint-ok: <reason> -->` on the same line. A reason is
required.

WHAT IT DELIBERATELY DOES NOT CHECK
-----------------------------------
Prose claims about behaviour and "blind to" statements. Counts USED to be uncheckable
too; D6 fixes that for any count you can express as a command, and a count you cannot
express as a command probably should not be in the document — name the list instead.
The rest:  Those need a
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
# The character class MUST include '_'. It did not, so D3 silently skipped every gate
# whose name has an underscore -- compile_check, compile_check-inline, output_sweep,
# full_sweep, examples_sweep. Five of eighteen registered gates were exempt from the
# "is this documented?" check, and D3 reported clean the whole time. Found 2026-08-01 by
# a D6 count oracle disagreeing with D3's own parse (12 vs 13), which is the entire
# argument for pinning counts: the discrepancy is the signal.
GATE_REG = re.compile(r'^\s*run\s+"([a-z0-9_\-]+)"', re.M)

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

# EVERY DOCUMENT DECLARES WHAT IT IS, on line 1:
#
#     <!-- doc-status: live | historical | design | generated -->
#
#   live       describes CURRENT state; trust it, and keep it true
#   historical append-only record or dated snapshot; accurate as of its entries. A March
#              bug entry citing a tool deleted in June is not stale -- "fixing" it would
#              falsify the record. Findings are reported as INFO, not gated.
#   design     a design/decision note; may describe INTENT that is not built. Each
#              carries its own Status: line saying where it got to.
#   generated  produced by a tool -- edit the tool, not the file.
#
# This replaced a hardcoded list of four filenames. That list was itself the hazard it was
# guarding against: it would have gone silently wrong the first time someone added an
# append-only document, and nothing would have said so. A declaration cannot drift out of
# sync with the file it is written in.
#
# The point for a reader arriving cold: `historical` and `generated` can be SKIPPED with
# confidence rather than by guess -- roughly a quarter of this repo's documentation.
DOC_STATUS = re.compile(r"<!--\s*doc-status:\s*(live|historical|design|generated)\s*-->")
VALID_STATUS = ("live", "historical", "design", "generated")


def status_of(text):
    m = DOC_STATUS.search(text[:400])
    return m.group(1) if m else None


def check_status(path, text):
    """D7 -- every scanned document declares what it is."""
    rel = path.relative_to(REPO).as_posix()
    if status_of(text) is None:
        return [Finding("D7", rel, 1,
                        "no `<!-- doc-status: ... -->` on line 1. A reader arriving cold "
                        f"cannot tell whether to trust this file. One of: "
                        f"{', '.join(VALID_STATUS)}")]
    return []


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



# --------------------------------------------------------------------------- D6
# RECEIPT: three in one day, 2026-08-01. gates.sh's header said "seven gates" against
# twelve registered; its boundary comment said "Twelve probes" against twenty; and
# TOOLING_COMMISSION.md opened with "five bugs" above a six-row table and "six checks"
# above seven -- written within an hour of a paragraph explaining that counts rot.
#
# Trying harder does not work. A bare number has no referent, so nothing can check it and
# nobody notices when the thing it counted grew. Give it a referent:
#
#     There are 12 gates <!-- doc-gen: 12 = grep -c '^run "' tools/gates.sh -->
#
# and this check runs the command and compares. The number stays in readable prose; the
# oracle sits beside it. If you cannot express the count as a command, that is a signal
# the number should not be in the document at all -- prefer naming the list.
def _bash():
    """Git Bash by absolute path, never a bare `bash`.

    Caught by tools/hazard_lint.py H2 minutes after this function was written -- a bare
    "bash" resolves to WSL on this machine, which translates paths to /mnt/c and would run
    these oracles against a different view of the filesystem. It happened to work while
    being developed, because the PATH inherited from Git Bash resolved it correctly; from
    PowerShell or a scheduled task it would not have. That is the whole reason H2 exists,
    and the lint found it in the tool written to find stale claims.
    """
    for c in (r"C:\Program Files\Git\bin\bash.exe",
              r"C:\Program Files (x86)\Git\bin\bash.exe"):
        if pathlib.Path(c).exists():
            return c
    return "bash"      # hazard-ok:H2 last-resort fallback on a non-Windows host, where a bare `bash` is correct and WSL does not exist


DOC_GEN = re.compile(r"<!--\s*doc-gen:\s*(.+?)\s*=\s*(.+?)\s*-->")


def check_gen(path, text):
    """D6 -- a number carrying a doc-gen oracle must equal what the oracle returns."""
    import subprocess
    rel = path.relative_to(REPO).as_posix()
    hits = []
    for i, ln in enumerate(text.splitlines(), 1):
        m = DOC_GEN.search(ln)
        if not m:
            continue
        claimed, cmd = m.group(1).strip(), m.group(2).strip()
        try:
            got = subprocess.run([_bash(), "-c", cmd], cwd=str(REPO), capture_output=True,
                                 timeout=60).stdout.decode("utf-8", "replace").strip()
        except (OSError, subprocess.SubprocessError) as e:
            hits.append(Finding("D6", rel, i, f"doc-gen command failed to run ({e}): {cmd}"))
            continue
        if got != claimed:
            hits.append(Finding("D6", rel, i,
                                f"stale count: document says {claimed!r}, "
                                f"`{cmd}` says {got!r}"))
    return hits


# --------------------------------------------------------------- positive controls
# Same discipline as tools/hazard_lint.py: a checker that has stopped checking must not
# look like a checker that found nothing.
# Each control carries a valid doc-status so it exercises ONE check, except D7's, whose
# defect IS the missing marker.
_OK = "<!-- doc-status: live -->\n"
CONTROLS = {
    "D1": _OK + "see `tools/definitely_not_a_real_tool.sh` for details\n",
    "D2": _OK + "described in `docs/definitely_not_a_real_doc.md`\n",
    "D4": _OK + "this was fixed in BUG-9997\n",
    "D6": _OK + "There are 99 gates <!-- doc-gen: 99 = echo 3 -->\n",
    "D7": "# A document with no status marker at all\n",
}


def selftest(verbose=False):
    dead = set()
    known = {"1"}
    for code, text in CONTROLS.items():
        fake = REPO / "CONTROL.md"
        hits = (check_refs(fake, text) + check_bugs(fake, text, known)
                + check_gen(fake, text) + check_status(fake, text))
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
    "coverage counts with NO doc-gen oracle -- add one, or name the list instead (D6)",
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
    archival = {}
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        # `historical` and `generated` are both "accurate for what they are" -- a stale
        # reference in either is a fact about the past or about the generator, not a defect
        # in the document.
        archival[f.relative_to(REPO).as_posix()] = status_of(text) in ("historical",
                                                                       "generated")
        hits.extend(check_status(f, text))
        hits.extend(check_refs(f, text))
        hits.extend(check_bugs(f, text, known))
        hits.extend(check_gen(f, text))

    # D6 ALSO scans the tooling. The three stale counts that motivated it were in
    # tools/gates.sh, not in a document -- a comment describing a script's own contents
    # rots exactly like prose does, and is read exactly as often.
    for f in sorted(REPO.glob("tools/*.sh")) + sorted(REPO.glob("tools/*.py")):
        if f.name == "doc_lint.py":
            continue      # our own docstring example and control data are not claims
        hits.extend(check_gen(f, f.read_text(encoding="utf-8", errors="replace")))
    hits.extend(check_gates(claude_text))

    live = [h for h in hits if not archival.get(h.doc)]
    hist = [h for h in hits if archival.get(h.doc)]

    for h in sorted(live, key=lambda h: (h.code, h.doc, h.line)):
        print(h)
    if hist:
        n_arch = sum(1 for v in archival.values() if v)
        print(f"\n  ({len(hist)} more in the {n_arch} document(s) declaring "
              f"doc-status: historical | generated -- NOT counted. A bug entry citing a "
              f"tool deleted months later is accurate history, and rewriting it would be "
              f"falsifying the record. `--all` lists them.)")
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
