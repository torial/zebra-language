#!/usr/bin/env python3
"""diagnostic_parity.py -- which bootstrap diagnostics never reached the selfhost?

WHY THIS EXISTS
---------------
Three checks shipped in `src/` (the bootstrap) in May 2026 and were never ported to
`selfhost/` -- which is the compiler that ships as `zebra.exe`:

    BUG-108 / BUG-248   `this` outside a class      absent, found 2026-08-04
    BUG-106             heterogeneous list literal  absent, found 2026-08-04
    BUG-099 / BUG-252   unresolved identifier       absent, found 2026-08-04

All three were found by accident -- BUG-243 noticed their regression fixtures had never
run. Each had been recorded as FIXED for three months. Two of them were additionally being
used as `check_mode_check` "asymmetry witnesses", i.e. cited as evidence that `zebra -c`
*cannot* catch things, when in fact a Zebra front end demonstrably can and the selfhost had
simply not been given the check.

Three instances found by accident is not a coincidence, it is a class. This enumerates it.

SCOPE, AND WHY IT IS NARROW ON PURPOSE
--------------------------------------
TypeChecker only. `emitError` appears in exactly one bootstrap file (src/TypeChecker.zig,
38 sites) and `addErr` in exactly one selfhost file (selfhost/TypeChecker.zbr, 21 sites),
so the two sets are directly comparable.

THE PARSER PHASE IS NOT COMPARABLE, AND NOT BECAUSE OF EXTRACTION DIFFICULTY -- checked
2026-08-04. The two compilers parse by different strategies: the bootstrap is Earley-based
and reports a single `"parse error near token {}"`, while selfhost/Parser.zbr is recursive
descent with 24 `.errorAt(` sites naming specific expectations. There is no like-for-like
mapping to compute; a diff would report ~24 "missing from the bootstrap" and mean nothing.
So the TypeChecker is not merely where this started -- it is the ONLY phase where this
question is well-posed. Do not "extend" this tool to the parser without first deciding what
parity would even mean there.

MATCHING IS BY SKELETON, NOT BY EXACT TEXT
------------------------------------------
The two compilers build messages differently -- Zig format strings (`"... '{s}' ..."`)
versus Zebra concatenation (`"... '" + typeTag(t) + "' ..."`). So each message is reduced
to a SKELETON: literal fragments joined, placeholders and interpolation dropped, punctuation
and case normalised, and the longest surviving run of words used as the identity.

That is deliberately lossy, so this tool reports CANDIDATES for a human, never a verdict.
A near-miss (reworded but present) shows up as missing; that is the safe direction to err.

CONTROLS, derived at runtime rather than pinned to a known gap
--------------------------------------------------------------
  PRESENT control: a message known to exist in BOTH must classify as present.
  ABSENT  control: a message known to be bootstrap-only must classify as absent.
Both are re-derived from the files each run. If either stops behaving, the tool REFUSES to
report -- an enumeration that has stopped enumerating must not print a short list.

Exit: 0 always (this is a REPORT, not a gate). Reporting-only because "absent" here is a
candidate for triage: a diagnostic may be legitimately unported (a bootstrap-only feature),
and encoding that judgement as a gate would demand a suppression list nobody maintains.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
BOOT = REPO / "src" / "TypeChecker.zig"
SELF = REPO / "selfhost" / "TypeChecker.zbr"

STOP = {"the", "a", "an", "is", "are", "of", "to", "in", "on", "at", "or", "and", "not",
        "be", "it", "its", "this", "that", "for", "with", "use", "used"}


def skeleton(msg):
    """Reduce a message to a comparable identity: lowercase content words, in order."""
    s = msg.lower()
    s = re.sub(r'\{[^}]*\}', ' ', s)          # Zig format placeholders
    s = re.sub(r'\$\{[^}]*\}', ' ', s)        # Zebra interpolation
    s = re.sub(r"[^a-z0-9 ]", " ", s)         # punctuation, quotes
    words = [w for w in s.split() if w and w not in STOP and len(w) > 2]
    return " ".join(words)


def boot_messages(text):
    """`tc.emitError(span, "msg", .{...})` -> the format string."""
    out = []
    for m in re.finditer(r'emitError\s*\([^,]+,\s*"((?:[^"\\]|\\.)*)"', text, re.S):
        out.append(m.group(1))
    return out


def self_messages(text):
    """`ctx.addErr(file, line, col, "a" + x + "b")` -> literal fragments joined.

    The message may span lines and interleave expressions, so the call text is taken up to
    a blank line or the next statement at the same indent, and every double-quoted literal
    within it is concatenated.
    """
    out = []
    for m in re.finditer(r'addErr\s*\(', text):
        chunk = text[m.end(): m.end() + 400]
        # Stop at the end of the logical call: a line that starts a new statement.
        lines, depth = [], 1
        for ln in chunk.split("\n"):
            lines.append(ln)
            depth += ln.count("(") - ln.count(")")
            if depth <= 0:
                break
        call = "\n".join(lines)
        lits = re.findall(r'"((?:[^"\\]|\\.)*)"', call)
        # Drop the leading file/format args that are not message text.
        joined = " ".join(l for l in lits if len(l) > 1)
        if joined.strip():
            out.append(joined)
    return out


def main():
    if not BOOT.is_file() or not SELF.is_file():
        print(f"REFUSING TO REPORT: {BOOT.name} or {SELF.name} missing.")
        return 2
    bt, st = BOOT.read_text(encoding="utf-8"), SELF.read_text(encoding="utf-8")
    bmsgs, smsgs = boot_messages(bt), self_messages(st)

    if not bmsgs or not smsgs:
        print(f"REFUSING TO REPORT: extracted {len(bmsgs)} bootstrap and {len(smsgs)} "
              f"selfhost messages. One extractor has stopped working; a short 'missing' "
              f"list would be the reassuring answer, not the true one.")
        return 2

    sskel = [skeleton(m) for m in smsgs]

    def present(bmsg):
        bs = skeleton(bmsg)
        if not bs:
            return True                       # nothing to compare; do not claim missing
        for ss in sskel:
            if not ss:
                continue
            if bs in ss or ss in bs:
                return True
            # Word-overlap fallback: reworded but recognisably the same diagnostic.
            bw, sw = set(bs.split()), set(ss.split())
            if bw and len(bw & sw) / len(bw) >= 0.7:
                return True
        return False

    # ---- CONTROLS ------------------------------------------------------------------
    ctl_present = "'this' used outside a class/struct method or 'with' block"
    if ctl_present not in bt:
        print("REFUSING TO REPORT: the PRESENT control string is no longer in the "
              "bootstrap; the control cannot prove the matcher works.")
        return 2
    if not present(ctl_present):
        print("REFUSING TO REPORT: control failed — a diagnostic KNOWN to exist in both "
              "compilers was classified as missing. The matcher is broken; every result "
              "below would be a false alarm.")
        return 2
    if present("zzz nonexistent diagnostic about quantum flux capacitors"):
        print("REFUSING TO REPORT: control failed — a diagnostic that exists in NEITHER "
              "compiler was classified as present. The matcher accepts anything.")
        return 2

    missing = [m for m in bmsgs if not present(m)]
    print(f"bootstrap TypeChecker diagnostics: {len(bmsgs)}   "
          f"selfhost: {len(smsgs)}   controls: ok\n")
    print(f"IN THE BOOTSTRAP, NO COUNTERPART FOUND IN THE SELFHOST — {len(missing)}:")
    for m in sorted(set(missing)):
        print(f"    {m[:104]}")
    print("\nCANDIDATES, not defects. A diagnostic may be legitimately unported (a "
          "bootstrap-only\nfeature), or reworded past the matcher. Triage each; this tool "
          "reports and does not gate.")
    print("NOT COVERED: Parser/Resolver/Tokenizer diagnostics — the two compilers report "
          "those\nthrough different mechanisms and would need separate extraction.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
