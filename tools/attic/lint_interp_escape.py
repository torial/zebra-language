#!/usr/bin/env python3
"""lint_interp_escape.py — BUG-216 gate (static, instant, no build).

Flags a Zebra string literal that is BOTH interpolated (contains `${`) and
contains an escaped double quote (`\\"`).

Why this is a hazard and not a style nit
----------------------------------------
The two compilers disagree on this one construct:

    var s = "say \\"hi\\" n=${n}"

  * selfhost  emits  std.fmt.allocPrint(_allocator, "say \\"hi\\" n={}", ...)   CORRECT
  * bootstrap emits  std.fmt.allocPrint(_allocator, "say \\\\\\"hi\\\\\\" n={}", ...) WRONG

The bootstrap keeps the RAW source text for an interpolated string's literal
parts and then escapes it again on the way out (src/CodeGen.zig, the
`if (c == '"')` / `if (c == '\\\\')` pass in genStringInterp), so `\\"` becomes
`\\\\\\"`.  A plain (non-interpolated) string is unescaped correctly by both.

Normally a bootstrap-only bug is "don't chase — the bootstrap sunsets".  This
one is different: the bootstrap is the REGEN AUTHORITY for `selfhost/*.zig`, so
the corruption is baked into the shipping compiler whenever the pattern appears
in the compiler's own source.  It did: all three `genCopyOut` `<<-` / `<-`
diagnostics emitted `@compileError(\\"...` — a Zig *parse* error rather than the
message they were written to give — from the day they were added until 2026-07-27.
Nobody noticed because you only see those diagnostics by making that mistake.

Fix at a flagged site: emit the interpolated value as its own piece so every
string stays plain.

    w.emit("@compileError(\\"line ")
    w.emit(co.span.line.toString())
    w.emit(": message here\\");\\n")

Retire this lint if the bootstrap is fixed or removed.

Exit status: 0 = clean, 1 = at least one hazard.
"""
import re
import sys
import pathlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# A double-quoted Zebra string, honouring backslash escapes.
STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"')


def hazards_in(path: Path):
    """Yield (line_no, literal) for every interpolated literal containing \\"."""
    out = []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        for lit in STRING_RE.findall(line):
            if "${" in lit and '\\"' in lit:
                out.append((n, lit))
    return out


def main() -> int:
    # Optional path patterns, matching lint_fallthrough.py. Not for normal use — it
    # exists so tools/gate_selfcheck.sh can point the lint at a fixture containing a
    # KNOWN hazard and confirm it still reports one. A lint that cannot be shown to
    # fire is indistinguishable from a lint that has stopped firing.
    pats = sys.argv[1:] or ["selfhost/*.zbr", "IDE/*.zbr"]
    targets = []
    for pat in pats:
        # An existing path is used directly; anything else is globbed relative to the
        # repo. Checking existence FIRST matters on Windows, where a POSIX-style
        # "/tmp/x.zbr" is not `is_absolute()` and would fall through to REPO.glob(),
        # which raises NotImplementedError on a leading slash.
        direct = pathlib.Path(pat)
        if direct.exists():
            # resolve(): the report line does `relative_to(REPO)`, which raises on a
            # relative path. Absolute-ise here so a caller may pass either form.
            targets.append(direct.resolve())
        else:
            targets.extend(sorted(REPO.glob(pat)))
    total = 0
    for path in targets:
        for n, lit in hazards_in(path):
            total += 1
            rel = path.relative_to(REPO).as_posix()
            print(f"{rel}:{n}: escaped quote inside an interpolated string")
            print(f"    {lit}")
    print(f"[interp-escape-lint] {total} hazard(s) across {len(targets)} file(s)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
