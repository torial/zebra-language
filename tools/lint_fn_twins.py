"""lint_fn_twins.py — THE SECTION-DRIFT LINT: every `.@"fn"` dispatch line in a GUI
section file must have a byte-identical twin in stdlib_preamble.zig.

WHY (refuter, 2026-09-09). The two GUI sections (gui_tui_section.zig,
gui_libui_ng_section.zig) each carry a copy of the preamble's MVU message-type
derivation — the `@typeInfo(@TypeOf(_mvu_update)).@"fn".params[N].type.?` pair. Three
copies of one dispatch is the cleanroom charter's named hazard, and it was found drifted
TWICE by accident: ten `.@"fn"` sites in the sections had diverged from the preamble's
`_zbr_is_fnlike` form, and the refuter spent an hour trying to reach the five divergent
ones before reporting that he could not. His ask was one line: "every `.@\"fn\"` in a
section file must have a preamble twin". This is that line, with controls.

THE RULE. For each section file, each source line containing `.@"fn"` (comments
stripped, whitespace-normalised) must occur verbatim in the preamble. A line that is in
the section and not in the preamble is DRIFT — either the section grew a private
dispatch (move it into the preamble and share it), or the preamble's copy was edited
and the section's was not (the bug this exists to catch).

Only sections are checked against the preamble, not the reverse: the preamble legitimately
has fn-shaped dispatch the sections never need (`_zbr_is_fnlike` itself, the sys.go
thunks). And a MISSING preamble twin fails; an EXTRA preamble line is nothing.

CONTROLS. A synthetic section carrying one line the preamble has and one it does not
must produce exactly one finding; a section with only twins must produce none. The lint
refuses (exit 2) if the preamble cannot be read, if it contains no `.@"fn"` at all (the
oracle collapsed), or if a control stops discriminating.

    python tools/lint_fn_twins.py        # 0 = clean, 1 = drift, 2 = refused
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
PREAMBLE = REPO / "selfhost" / "stdlib_preamble.zig"
SECTIONS = ["selfhost/gui_tui_section.zig", "selfhost/gui_libui_ng_section.zig"]
NEEDLE = '.@"fn"'


def normalise(line: str) -> str:
    # strip a trailing `// comment`, collapse whitespace
    line = re.sub(r"//.*$", "", line)
    return " ".join(line.split())


def fn_lines(text: str):
    out = []
    for n, raw in enumerate(text.splitlines(), 1):
        if NEEDLE in raw:
            norm = normalise(raw)
            if NEEDLE in norm:
                out.append((n, norm))
    return out


def drift(section_text: str, preamble_norms: set):
    return [(n, l) for n, l in fn_lines(section_text) if l not in preamble_norms]


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    if not PREAMBLE.exists():
        sys.stderr.write("[fn-twins] REFUSING: preamble not found\n")
        return 2
    preamble = PREAMBLE.read_text(encoding="utf-8")
    pre_norms = set(l for _, l in fn_lines(preamble))
    if not pre_norms:
        sys.stderr.write("[fn-twins] REFUSING: the preamble has no `.@\"fn\"` line at all -- the oracle collapsed\n")
        return 2

    # controls: the lint must fire on a foreign line and stay quiet on a twin
    twin = next(iter(pre_norms))
    foreign = '    const _x = @typeInfo(T).@"fn".params[9].type.?; // planted'
    ctl_hit = drift(twin + "\n" + foreign + "\n", pre_norms)
    ctl_quiet = drift(twin + "\n", pre_norms)
    if len(ctl_hit) != 1 or ctl_quiet:
        sys.stderr.write(f"[fn-twins] REFUSING: controls stopped discriminating (hit={len(ctl_hit)}, quiet={len(ctl_quiet)})\n")
        return 2

    findings, checked, scanned = [], 0, 0
    for rel in SECTIONS:
        p = REPO / rel
        if not p.exists():
            continue
        scanned += 1
        text = p.read_text(encoding="utf-8")
        checked += len(fn_lines(text))
        for n, l in drift(text, pre_norms):
            findings.append((rel, n, l))
    if scanned == 0:
        sys.stderr.write("[fn-twins] REFUSING: no section file found -- the paths moved\n")
        return 2
    for rel, n, l in findings:
        print(f"{rel}:{n}: `.@\"fn\"` line has no twin in stdlib_preamble.zig")
        print(f"    {l[:110]}")
    print(f"[fn-twins] {len(findings)} drift(s) across {checked} section line(s) in {scanned} file(s); "
          f"{len(pre_norms)} preamble twin(s); controls fired")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
