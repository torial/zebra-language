#!/usr/bin/env python3
"""gui_surface_drift.py -- the three GUI regions must agree (2026-09-23).

The GUI region of selfhost/stdlib_preamble.zig (between the STDLIB_PREAMBLE_GUI markers;
the stub backend) is REPLACED wholesale by selfhost/gui_tui_section.zig or
selfhost/gui_libui_ng_section.zig when a program is built for those backends. Three
hand-maintained copies of `_GuiBackend`, `GuiContext` and the `_gui_*` helpers that
CodeGen emits calls to -- and they drift: a verb added to one section and not another
fails inside zig for the backend that lacks it, which is the shape of BUG-355's cousins
(`_gui_set_clipboard_text` missing from the scaffold, 2026-09-23; `beginTabs` missing
from the stub, found by this script's first run). Static: no compiler needed.

Checks, each a numbered line so a red is one fix:
  1. GuiContext `pub fn` names: identical in all three (the stub may IMPLEMENT a verb as a
     print instead of a table call, but the set of verbs a program can write is one set).
  2. `_GuiBackend` field names: identical between the tui and libui sections (the stub
     routes some verbs straight to print and is allowed a smaller table).
  3. Top-level `_gui_*` fns: identical in all three, and every `_gui_*` symbol CodeGen.zbr
     emits is among them.
  4. TypeChecker.guiMethodKnown lists exactly the GuiContext verbs a program may call
     (the checker refuses names outside the list, so a verb missing there is invisible,
     and a name there without a method fails inside zig).
Exit 0 with `all checks pass`, 1 otherwise.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRE = ROOT / "selfhost/stdlib_preamble.zig"
TUI = ROOT / "selfhost/gui_tui_section.zig"
LUI = ROOT / "selfhost/gui_libui_ng_section.zig"
TC = ROOT / "selfhost/TypeChecker.zbr"
CG = ROOT / "selfhost/CodeGen.zbr"

# GuiContext methods that exist for the runtime, not for programs -- none today; a verb
# reached only by generated code would be listed here to keep it out of check 4.
RUNTIME_ONLY = set()


def region(text):
    a = text.index("// === STDLIB_PREAMBLE_GUI_START ===")
    b = text.index("// === STDLIB_PREAMBLE_GUI_END ===")
    return text[a:b]


def struct_body(text, head):
    i = text.index(head)
    j = text.index("\n};", i)
    return text[i:j]


def methods(text):
    return set(re.findall(r"^\s+pub fn (\w+)\(", struct_body(text, "GuiContext = struct"), re.M))


def fields(text):
    return set(re.findall(r"^\s+(\w+):\s", struct_body(text, "_GuiBackend = struct"), re.M))


def helpers(text):
    return set(re.findall(r"^(?:pub )?fn (_gui_\w+)\(", text, re.M))


def main():
    pre = region(PRE.read_text(encoding="utf-8"))
    tui = TUI.read_text(encoding="utf-8")
    lui = LUI.read_text(encoding="utf-8")
    tc = TC.read_text(encoding="utf-8")
    cg = CG.read_text(encoding="utf-8")
    red = 0

    def report(n, label, ok, detail=""):
        nonlocal red
        print(f"  {n}. {label}: {'ok' if ok else 'DRIFT'}{('  ' + detail) if detail and not ok else ''}")
        if not ok:
            red += 1

    m = {"stub": methods(pre), "tui": methods(tui), "libui": methods(lui)}
    allm = m["stub"] | m["tui"] | m["libui"]
    missing = {k: sorted(allm - v) for k, v in m.items() if allm - v}
    report(1, "GuiContext verbs identical (stub/tui/libui)", not missing,
           "missing " + "; ".join(f"{k}: {v}" for k, v in missing.items()))

    f = {"tui": fields(tui), "libui": fields(lui)}
    allf = f["tui"] | f["libui"]
    fmissing = {k: sorted(allf - v) for k, v in f.items() if allf - v}
    report(2, "_GuiBackend fields identical (tui/libui)", not fmissing,
           "missing " + "; ".join(f"{k}: {v}" for k, v in fmissing.items()))

    h = {"stub": helpers(pre), "tui": helpers(tui), "libui": helpers(lui)}
    allh = h["stub"] | h["tui"] | h["libui"]
    emitted = set(re.findall(r"(_gui_[a-z_]+)\(", cg))
    hmissing = {k: sorted((allh | emitted) - v) for k, v in h.items() if (allh | emitted) - v}
    report(3, "_gui_* helpers identical and cover CodeGen's emits", not hmissing,
           "missing " + "; ".join(f"{k}: {v}" for k, v in hmissing.items()))

    i = tc.index("def guiMethodKnown(")
    body = tc[i:tc.index("\ndef ", i + 1)]
    known = set(re.findall(r'name == "(\w+)"', body))
    program_verbs = allm - RUNTIME_ONLY
    not_known = sorted(program_verbs - known)
    not_method = sorted(known - allm)
    report(4, "TypeChecker.guiMethodKnown == GuiContext verbs", not (not_known or not_method),
           (f"verbs the checker refuses: {not_known}; " if not_known else "")
           + (f"names with no method: {not_method}" if not_method else ""))

    print("all checks pass" if red == 0 else f"{red} check(s) red")
    return 0 if red == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
