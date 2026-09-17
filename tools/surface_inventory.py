#!/usr/bin/env python3
"""surface_inventory.py -- THE STABLE SURFACE, derived from the compiler, diffed by a gate.

WHY. NEXT_STEPS_to_1.0 §15 says 1.0 "locks the API surface with a stability promise" and
lists milestones, not a surface. A promise about a set nobody has written down cannot be
kept or broken, only argued about. This tool writes the set down -- DERIVED from the
compiler's own tables, the way str_ownership_extract derives the ownership table from the
emit and grammar_export derives grammar.txt from the rule table -- and `--check` fails when
the derived set no longer matches the committed docs/SURFACE.md. Before 1.0 that diff is
review; after 1.0 it IS the stability promise, mechanically: nothing enters or leaves the
surface without a deliberate `--write` in the same commit.

WHAT IT DERIVES, and from where (each an oracle the compiler already runs on):
  keywords            tools/zbr_vocab.py -- the reconciled union of both compilers' tables
  cues                selfhost/Parser.zbr -- CUE_NAMES, the closed set the parser accepts after
                      `cue` (2026-09-16); the compiler calls these methods for you
  CLI                 selfhost/main.zbr  -- the usageLine("...") text (BUG-321: ONE usage text)
  namespaces+members  selfhost/CodeGen.zbr -- the `if id.name == "NS"` dispatch names its
                      generator (genXxxCall); every `mname == "m"` in that generator's body
                      is a member the compiler will emit. `List` there is the generic-ctor
                      arm (List/HashMap/Set/Chan/...), reported under its own heading.
  receiver methods    selfhost/TypeChecker.zbr -- the *MethodKnown predicates (BUG-369):
                      str, List, HashMap, Set, JsonValue. Since 2026-09-09 an unknown
                      method on these is REFUSED, so the predicate IS the surface.

WHAT IT DOES NOT SEE (say it, or a clean run gets over-read): instance methods on the
runtime object types that have NO Type_ variant of their own (DateTime, File handles,
HttpResponse, the GUI widget structs) -- those still dispatch by name inside per-type
generators; the 16 that do have a variant were closed 2026-09-15 and are derived above;
argument arities and types; semantics. The heading counts print every
run so a section that silently collapsed reads as a drop, not as a clean pass.

REFUSES (exit 2) rather than reporting a match when a section falls under its floor: an
extractor whose pattern stopped matching would otherwise produce a SMALLER surface, and a
smaller surface diffed against a smaller file is still "matches".

Usage:
    python tools/surface_inventory.py            # print the inventory
    python tools/surface_inventory.py --write    # write docs/SURFACE.md
    python tools/surface_inventory.py --check    # gate: docs/SURFACE.md must equal the derivation
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
OUT = REPO / "docs" / "SURFACE.md"
CODEGEN = REPO / "selfhost" / "CodeGen.zbr"
CHECKER = REPO / "selfhost" / "TypeChecker.zbr"
MAIN = REPO / "selfhost" / "main.zbr"

FLOORS = dict(keywords=60, cues=5, namespaces=25, members=150, receivers=20, receiver_methods=220,
              cli_lines=30, flags=15)
PARSER = REPO / "selfhost" / "Parser.zbr"


def refuse(msg):
    print("surface-inventory: REFUSING -- " + msg, file=sys.stderr)
    sys.exit(2)


def read(p):
    return p.read_text(encoding="utf-8").splitlines()


# ---- keywords ---------------------------------------------------------------------------
def keywords():
    import zbr_vocab
    return zbr_vocab.vocabulary()


# ---- cues -------------------------------------------------------------------------------
def cues():
    m = re.search(r'var CUE_NAMES: str = "\|((?:[A-Za-z]+\|)+)"', PARSER.read_text(encoding="utf-8"))
    if not m:
        refuse("CUE_NAMES not found in selfhost/Parser.zbr (extractor pattern stopped matching)")
    names = [n for n in m.group(1).split("|") if n]
    if len(names) < FLOORS["cues"]:
        refuse("only %d cues derived (floor %d)" % (len(names), FLOORS["cues"]))
    return names


# ---- CLI --------------------------------------------------------------------------------
def cli():
    lines = [m.group(1) for m in re.finditer(r'usageLine\("((?:[^"\\]|\\.)*)"', MAIN.read_text(encoding="utf-8"))]
    forms, flags = [], set()
    for ln in lines:
        ln = ln.replace('\\"', '"')
        if ln.startswith("  zebra "):
            # The form ends where the description begins. Three usage lines separate the
            # two with ONE space, so a 2+-space split is not enough: walk the tokens and
            # stop at the first that is neither a subcommand (position 1), a flag, nor a
            # placeholder (<x>, ALLCAPS, or carrying , or .).
            toks = ln.split()
            keep = ["zebra"]
            for k, t in enumerate(toks[1:], 1):
                if t.startswith("-") or t.startswith("<") or t.isupper() or "," in t or "." in t \
                        or (k == 1 and t.islower()):
                    keep.append(t)
                else:
                    break
            forms.append(" ".join(keep))
        flags.update(re.findall(r"(?<![\w-])(--?[a-zA-Z][\w-]*)", ln))
    if len(lines) < FLOORS["cli_lines"]:
        refuse("only %d usageLine(...) strings found in main.zbr (floor %d)" % (len(lines), FLOORS["cli_lines"]))
    if len(flags) < FLOORS["flags"]:
        refuse("only %d CLI flags extracted (floor %d)" % (len(flags), FLOORS["flags"]))
    return forms, sorted(flags)


# ---- namespaces + static members --------------------------------------------------------
def _body(lines, fn):
    start = next((i for i, l in enumerate(lines) if re.match(r"\s*def " + re.escape(fn) + r"\(", l)), None)
    if start is None:
        return None
    ind = len(lines[start]) - len(lines[start].lstrip())
    out = []
    for l in lines[start + 1:]:
        if l.strip() and (len(l) - len(l.lstrip())) <= ind:
            break
        out.append(l)
    return out


def namespaces():
    lines = read(CODEGEN)
    disp = {}
    for i, ln in enumerate(lines):
        m = re.search(r'id\.name == "([A-Za-z]+)"', ln)
        if not m:
            continue
        for j in range(i + 1, min(i + 4, len(lines))):
            c = re.search(r"\b(gen[A-Za-z]+Call)\(", lines[j])
            if c:
                disp.setdefault(m.group(1), c.group(1))
                break
    res = {}
    for ns, fn in disp.items():
        body = _body(lines, fn)
        if body is None:
            refuse("dispatch names %s for namespace %s but no such def exists" % (fn, ns))
        mem = set()
        for l in body:
            mem.update(re.findall(r'(?:mname|method|name)\s*==\s*"([A-Za-z_][A-Za-z0-9_]*)"', l))
        # OPEN or CLOSED. A generator that emits `mname` verbatim outside a @compileError
        # arm passes UNKNOWN members through to Zig (Math: `std.math.<name>(...)`), so its
        # surface is "the names above plus whatever the Zig target has" -- a promise the
        # compiler cannot make alone. Most generators refuse instead. Say which.
        open_to = None
        for k, l in enumerate(body):
            if re.search(r"emit\(\s*mname\s*\)", l) and not any("compileError" in body[j] for j in range(max(0, k - 2), k + 1)):
                prev = next((m.group(1) for j in range(k - 1, max(-1, k - 3), -1)
                             for m in [re.search(r'emit\("([^"]*)"\)', body[j])] if m), "")
                open_to = prev + "<name>"
        res[ns] = (fn, sorted(mem), open_to)
    generic = res.pop("List", None)  # the generic-ctor arm, not a namespace
    if len(res) < FLOORS["namespaces"]:
        refuse("only %d namespaces derived (floor %d)" % (len(res), FLOORS["namespaces"]))
    total = sum(len(v[1]) for v in res.values())
    if total < FLOORS["members"]:
        refuse("only %d static members derived (floor %d)" % (total, FLOORS["members"]))
    return res, (generic[1] if generic else [])


# ---- builtin receiver methods -----------------------------------------------------------
RECEIVERS = [("str", "strMethodKnown"), ("List(T)", "listMethodKnown"),
             ("HashMap(K, V)", "hashmapMethodKnown"), ("Set(T)", "setMethodKnown"),
             ("JsonValue", "jsonMethodKnown"),
             # 2026-09-15: the runtime object receivers, closed the same way.
             ("Regex", "regexMethodKnown"), ("Timer", "timerMethodKnown"),
             ("StringBuilder", "stringBuilderMethodKnown"), ("SysProcess", "sysProcessMethodKnown"),
             ("Build", "buildMethodKnown"), ("BuildTarget", "buildTargetMethodKnown"),
             ("WsConn", "wsConnMethodKnown"), ("TcpConn", "tcpConnMethodKnown"),
             ("UdpSocket", "udpSocketMethodKnown"), ("SqliteDb", "sqliteDbMethodKnown"),
             ("SqliteRow", "sqliteRowMethodKnown"), ("SqliteRowList", "sqliteRowListMethodKnown"),
             ("CodeEditor", "codeEditorMethodKnown"), ("Gui", "guiMethodKnown"),
             ("HttpRequest (no methods; fields)", "httpRequestMethodKnown"), ("Chan(T)", "chanMethodKnown"),
             ("SIMD vector / boolxN mask (QUICKSTART §32)", "simdMethodKnown")]


def receivers():
    lines = read(CHECKER)
    res = {}
    for label, fn in RECEIVERS:
        body = _body(lines, fn)
        if body is None:
            refuse("predicate %s not found in TypeChecker.zbr" % fn)
        names = []
        for l in body:
            names += re.findall(r'name == "([A-Za-z_][A-Za-z0-9_]*)"', l)
        res[label] = sorted(set(names))
    if len(res) < FLOORS["receivers"]:
        refuse("only %d receiver predicates (floor %d)" % (len(res), FLOORS["receivers"]))
    total = sum(len(v) for v in res.values())
    if total < FLOORS["receiver_methods"]:
        refuse("only %d receiver methods derived (floor %d)" % (total, FLOORS["receiver_methods"]))
    return res


# ---- render -----------------------------------------------------------------------------
def render():
    kw = keywords()
    cu = cues()
    forms, flags = cli()
    ns, generic = namespaces()
    rc = receivers()
    o = []
    o.append("<!-- doc-status: generated -->")
    o.append("# The Zebra surface (derived; do not edit)")
    o.append("")
    o.append("Generated by `tools/surface_inventory.py --write` from the compiler's own tables. The")
    o.append("`surface-freeze` gate fails when this file and the derivation disagree, so a change to")
    o.append("any list below is a deliberate act with a diff, not drift. Sections and their oracles are")
    o.append("named in the tool's header; what it cannot see is listed there too.")
    o.append("")
    o.append("## Keywords (%d)" % len(kw))
    o.append("")
    o.append(" ".join("`%s`" % k for k in kw))
    o.append("")
    o.append("## Cues (%d)" % len(cu))
    o.append("")
    o.append(" ".join("`cue %s`" % c for c in cu))
    o.append("")
    o.append("## Command forms (%d)" % len(forms))
    o.append("")
    for f in forms:
        o.append("- `%s`" % f)
    o.append("")
    o.append("## Flags (%d)" % len(flags))
    o.append("")
    o.append(" ".join("`%s`" % f for f in flags))
    o.append("")
    o.append("## Generic constructors (%d)" % len(generic))
    o.append("")
    o.append(" ".join("`%s`" % g for g in generic))
    o.append("")
    o.append("## Builtin receiver methods")
    o.append("")
    for label, _ in RECEIVERS:
        o.append("### %s (%d)" % (label, len(rc[label])))
        o.append("")
        o.append(" ".join("`%s`" % m for m in rc[label]))
        o.append("")
    total = sum(len(v[1]) for v in ns.values())
    opened = sorted(n for n, v in ns.items() if v[2])
    o.append("## Namespaces (%d) and static members (%d; %d namespace(s) OPEN: %s)"
             % (len(ns), total, len(opened), ", ".join(opened) or "none"))
    o.append("")
    for name in sorted(ns, key=str.lower):
        fn, mem, open_to = ns[name]
        o.append("### %s (%d%s) <!-- %s -->" % (name, len(mem), ", OPEN" if open_to else "", fn))
        o.append("")
        o.append(" ".join("`%s`" % m for m in mem) if mem else "*(no members named in the generator)*")
        if open_to:
            o.append("")
            o.append("*OPEN: an unlisted member is passed through as `%s` and judged by Zig, not by Zebra.*" % open_to)
        o.append("")
    return "\n".join(o) + "\n"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    text = render()
    if mode == "--write":
        OUT.write_text(text, encoding="utf-8", newline="\n")
        print("surface-inventory: wrote %s" % OUT.relative_to(REPO))
        return
    if mode == "--check":
        if not OUT.exists():
            print("surface-inventory: %s missing -- run --write" % OUT.relative_to(REPO))
            sys.exit(1)
        cur = OUT.read_text(encoding="utf-8").replace("\r\n", "\n")
        if cur == text:
            heads = [l for l in text.splitlines() if l.startswith("## ")]
            print("surface-inventory: docs/SURFACE.md matches the derivation (%s)" % "; ".join(h[3:] for h in heads))
            return
        # Token-level under each heading: a member added to a 54-name line must be
        # NAMED, not shown as two 800-character lines that differ somewhere.
        def toks(t):
            out, head = {}, "(top)"
            for l in t.splitlines():
                if l.startswith("#"):
                    head = re.sub(r" \(\d+[^)]*\)", "", l.strip("# ").split(" <!--")[0])
                elif l.startswith("`") or l.startswith("- `"):
                    out.setdefault(head, set()).update(re.findall(r"`([^`]+)`", l))
                else:
                    out.setdefault(head, set()).add(l) if l.strip() else None
            return out
        A, B = toks(cur), toks(text)
        for head in sorted(set(A) | set(B)):
            added, gone = B.get(head, set()) - A.get(head, set()), A.get(head, set()) - B.get(head, set())
            if added or gone:
                print("  %s:%s%s" % (head, "".join("  +%s" % x for x in sorted(added)), "".join("  -%s" % x for x in sorted(gone))))
        print("surface-inventory: docs/SURFACE.md DIFFERS from the derivation -- a surface change. "
              "If intended, run --write and say so in CHANGELOG.md; if not, this is drift.")
        sys.exit(1)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
