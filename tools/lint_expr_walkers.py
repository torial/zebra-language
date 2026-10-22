"""lint_expr_walkers.py — THE WALKER-DRIFT GATE.

A function that walks the Expr tree looking for something (a name, a mutation, an
escape) is only correct if it descends into every Expr variant that CONTAINS
expressions. Miss one and the walker silently answers "not found" for a whole
construct -- and because these walkers drive `_ = x;` discards, the symptom lands in
the EMITTED ZIG as a "pointless discard" or "unused variable" error pointing at code
the user wrote correctly.

WHY A LINT RATHER THAN CARE. This exact class was declared retired once already.
`mightUseNameInExpr` carries the note "BUG-169 retirement: model every remaining
ident-bearing expr ... Retires the walker-drift class (F2/F6/F11)". It drifted anyway:

    BUG-267  zig_lit   was listed among "genuinely ident-free forms". It is not.
    BUG-260  list_lit  and array_lit were listed the same way in the SIBLING walker.

Note what those two have in common: the variant was not FORGOTTEN, it was
MISCLASSIFIED -- somebody wrote down that it holds no expressions. Modelling
everything by hand does not prevent that, and neither does a habit. A machine
comparison against the AST does.

THE ORACLE IS THE AST ITSELF. `selfhost/Ast.zbr` declares each Expr variant's payload
struct, and each struct's field types. "Does this variant contain expressions" is
therefore derivable, not a judgement call -- including through one level of
indirection (`List(DictPair)` -> `DictPair.key: Expr`).

WHAT IT CANNOT SEE, stated because a clean run must not be over-read:
  * `zig_lit` holds its identifiers in a STRING, not in child nodes. No structural
    check can see them; that is exactly how BUG-267 survived. It is therefore added
    to the required set BY HAND below, and it is the only such variant.
  * Whether a walker's per-variant logic is CORRECT. This checks that a variant is
    handled at all, never that it is handled properly.
  * Walkers that do not opt in (see below). The count of those is printed every run.

OPT-IN, NOT BLANKET. 53 functions in this tree branch over Expr and most of them are
supposed to care about two or three forms -- `getVariantKey` wants `member` and
nothing else. Demanding full coverage from all of them would be ~90% noise, and a
gate at that ratio gets suppressed wholesale (the lesson doc_example_check records).
So a walker declares its intent:

    # expr-walker: exhaustive
    def nameUsedInExpr(name: str, expr: Expr): bool

and only those are checked. A deliberate omission is spelled:

    # expr-walker-ok: lambda bodies are visited by the caller instead

TWO TREES (2026-10-13, BUG-571). The compiler walks expressions in TWO representations:
the typed AST (`Expr`, Ast.zbr) and the parse tree (`PNode`, Parser.zbr) that the Resolver
walks. This gate originally knew only the first, so `Resolver.resolveExpr` -- which visited
13 of the parse tree's expression kinds and skipped ten that hold expressions -- was
invisible to it, and an undefined name inside a list literal, `orelse`, `catch`, a pipeline
or a lambda passed the front end. The PNode tree is checked the same way, under its own
marker, oracle and controls:

    # pnode-walker: exhaustive            # opt-in, as above
    # pnode-walker-ok: expr_zig_lit <reason>

PNode is ONE union for declarations, statements and expressions, so only its `expr_*`
variants are in the required set: a statement walker is a different contract.

    python tools/lint_expr_walkers.py           # report
    python tools/lint_expr_walkers.py --gate    # exit 1 on any finding
"""
import io
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
# DERIVED, not listed. This was a hardcoded list of six files until 2026-08-17, and it
# failed the exact way this gate exists to prevent: `collectOldNodesInto` was moved to a
# NEW module (selfhost/AstWalk.zbr, for BUG-292) and silently left coverage -- opted-in
# walkers went 7 -> 6 while the marker count in the tree stayed 7. Nothing failed; the
# gate just checked less. A hand-maintained oracle guarding against drift is rule 1b, and
# the fix is to stop maintaining it by hand.
#
# Globbing is safe BECAUSE the gate is opt-in: only functions carrying
# `# expr-walker: exhaustive` are checked, so widening the search cannot add noise -- it
# can only stop losing walkers. Ast.zbr is excluded as the ORACLE (it declares the
# variants; it does not walk them).
SEARCH = sorted(
    p.relative_to(REPO).as_posix()
    for p in (REPO / "selfhost").glob("*.zbr")
    if p.name != "Ast.zbr"
)
# The parse-tree walkers live beside the parser (and Parser.zbr is its own oracle file, so
# nothing is excluded for the PNode tree).
ALL_SELFHOST = sorted(p.relative_to(REPO).as_posix() for p in (REPO / "selfhost").glob("*.zbr"))

# Two variants bear identifiers WITHOUT holding child expressions, so no structural
# derivation can find them. Both are hardcoded, and both are named:
#   zig_lit — its identifiers live in a STRING. Exactly how BUG-267 survived: a
#             structural check looks at this and sees a leaf.
#   ident   — it IS the identifier. Structurally `span + name: str`, so the oracle
#             calls it a leaf, yet a usage walker that skips it is broken by
#             definition. Included so the gate cannot bless a walker that lost the
#             one case it exists to have.
SEMANTIC_BEARING = {"zig_lit", "ident"}

# One entry per expression tree. `prefix` filters the union's variants (PNode mixes
# declarations, statements and expressions); the two controls are pinned to the mechanism:
# a list literal holds a list of the root type, an integer literal holds text.
TREES = [
    dict(name="Expr", oracle="selfhost/Ast.zbr", root="Expr", prefix="", tag="Expr",
         marker="expr-walker", min_variants=25, semantic=SEMANTIC_BEARING,
         bearing_ctl="list_lit", leaf_ctl="int_lit"),
    dict(name="PNode", oracle="selfhost/Parser.zbr", root="PNode", prefix="expr_",
         tag="PNode", marker="pnode-walker", min_variants=30,
         # the parse-tree spellings of the same two: an identifier, and zig"..." text
         semantic={"expr_id", "expr_zig_lit"},
         bearing_ctl="expr_list_lit", leaf_ctl="expr_int"),
    # BUG-593 (2026-10-16): the STATEMENT half of the parse tree. The Resolver's statement
    # walker ended in `else pass` and skipped seven kinds -- a numeric `for`, `allocate`,
    # `in`, `require`, `ensure`, `<<-`, and the `for ... if` filter -- so an undefined name
    # inside any of them passed `zebra -c`. BUG-571 had found the expression half; this one
    # was invisible because the gate looked only at `expr_*`. A statement is "bearing" when
    # it holds an expression or a statement list; `pass` / `break` / `continue` are leaves.
    dict(name="PNode-stmt", oracle="selfhost/Parser.zbr", root="PNode", prefix="stmt_",
         tag="PNode", marker="pnode-stmt-walker", min_variants=18,
         semantic=set(), bearing_ctl="stmt_for_num", leaf_ctl="stmt_pass"),
]


def parse_blocks(src, kind):
    """{name: body} for every `union X` / `struct X` block in a .zbr source."""
    out, cur, buf = {}, None, []
    for line in src.split("\n"):
        m = re.match(r"^(union|struct)\s+(\w+)", line)
        if m:
            if cur:
                out[cur] = "\n".join(buf)
            cur, buf = (m.group(2) if m.group(1) == kind else None), []
            continue
        if cur is not None:
            # a block ends at the next top-level construct
            if line and not line.startswith((" ", "\t", "#")):
                out[cur] = "\n".join(buf)
                cur, buf = None, []
            else:
                buf.append(line)
    if cur:
        out[cur] = "\n".join(buf)
    return out


def type_names(t):
    return set(re.findall(r"\b([A-Z]\w*)\b", t))


def bearing(payload, structs, unions, root, depth=0, seen=None):
    """True when `payload` reaches `root` through its fields (one+ level)."""
    if payload == root:
        return True
    seen = seen or set()
    if payload in seen or depth > 3:
        return False
    seen.add(payload)
    body = structs.get(payload, unions.get(payload))
    if body is None:
        return False
    for line in body.split("\n"):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        # `var name: Type` (struct field) or `variant: Type` (union arm)
        m = re.match(r"^(?:var\s+)?\w+\s*:\s*(.+?)\s*$", s)
        if not m:
            continue
        for n in type_names(m.group(1)):
            if n == root:
                return True
            if bearing(n, structs, unions, root, depth + 1, seen):
                return True
    return False


def refuse(msg):
    print(f"[expr-walker] REFUSING: {msg}", file=sys.stderr)
    return 2


def check_tree(t):
    """(findings, summary) for one expression tree, or an int exit code on refusal."""
    src = io.open(REPO / t["oracle"], encoding="utf-8").read()
    unions = parse_blocks(src, "union")
    structs = parse_blocks(src, "struct")
    body = unions.get(t["root"])
    if not body:
        return refuse(f"could not find `union {t['root']}` in {t['oracle']}")

    # The variant's WHOLE payload type: `stmt_require: List(PNode)` must reach the root
    # through its type argument. Reading only the first word (`List`) classified it as a
    # leaf -- harmless while every checked variant was `^PSomething`, wrong the day the
    # statement half was added.
    # A variant with NO payload (`stmt_pass`) is a leaf, and it must be extracted as one:
    # skipping it made the leaf control pass vacuously (the control was not IN the set).
    variants = {}
    for line in body.split("\n"):
        m = re.match(r"^\s+(\w+)\s*(?::\s*(.+?))?\s*(?:#.*)?$", line)
        if m and not line.strip().startswith("#") and m.group(1).startswith(t["prefix"]):
            variants[m.group(1)] = m.group(2) or ""

    def reaches(ptext):
        return any(n == t["root"] or bearing(n, structs, unions, t["root"])
                   for n in type_names(ptext))

    required = {v for v, p in variants.items() if reaches(p)} | t["semantic"]
    leaves = set(variants) - required

    # ── Controls, run before reporting ────────────────────────────────────────
    # Pinned to the MECHANISM, not to a known gap: a list literal must classify as
    # bearing (it holds a list of the root type) and an integer literal as a leaf. If the
    # extractor stops resolving field types, both flip and this refuses to report --
    # rather than announcing that every walker is clean.
    if len(variants) < t["min_variants"]:
        return refuse(f"only {len(variants)} {t['name']} variants extracted (expected "
                      f"{t['min_variants']}+); the extractor is broken, not the code")
    for ctl in (t["bearing_ctl"], t["leaf_ctl"]):
        if ctl not in variants:
            return refuse(f"control variant {ctl} was not extracted from {t['root']} -- "
                          f"a control that is not in the set cannot fail")
    if t["bearing_ctl"] not in required:
        return refuse(f"control failed — {t['bearing_ctl']} did not classify as "
                      f"expression-bearing")
    if t["leaf_ctl"] in required:
        return refuse(f"control failed — {t['leaf_ctl']} classified as expression-bearing")
    if not t["semantic"] <= set(variants):
        return refuse(f"a hardcoded {t['name']} variant no longer exists: "
                      f"{sorted(t['semantic'] - set(variants))}")

    arm = re.compile(r"on\s+" + t["tag"] + r"\.(\w+)")
    marker = t["marker"] + ": exhaustive"
    findings, checked, total_walkers = [], 0, 0
    checked_defs = set()      # (file, def line) of every walker a marker attached to
    marker_lines = []         # (file, line) of every marker comment
    marker_re = re.compile(r"^\s*#\s*" + re.escape(marker) + r"\s*$")
    for rel in SEARCH if t["name"] == "Expr" else ALL_SELFHOST:
        p = REPO / rel
        if not p.exists():
            continue
        lines = io.open(p, encoding="utf-8").read().split("\n")
        for i, line in enumerate(lines):
            if marker_re.match(line):
                marker_lines.append((rel, i))
            m = re.match(r"^\s*def\s+(\w+)", line)
            if not m:
                continue
            # gather the function body (until the next def at the same-or-lower indent)
            indent = len(line) - len(line.lstrip())
            fbody = []
            for j in range(i + 1, len(lines)):
                nxt = lines[j]
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent and \
                        re.match(r"^\s*(def|class|struct|union)\b", nxt):
                    break
                fbody.append(nxt)
            body_txt = "\n".join(fbody)
            handled = set(arm.findall(body_txt))
            # a walker of THIS tree's expressions: it names at least one of its variants
            if not handled & set(variants):
                continue
            total_walkers += 1
            # Opt-in marker: scan the WHOLE contiguous comment block above the def, not a
            # fixed number of lines. A fixed window (4) silently stopped seeing a walker
            # the moment a waiver comment was added above it -- coverage dropped 2 -> 1
            # and the only reason it was noticed is that this tool prints the opted-in
            # count. A gate whose reach depends on how much prose someone wrote is a gate
            # that quietly shrinks.
            k = i - 1
            while k >= 0 and (lines[k].strip().startswith("#") or not lines[k].strip()):
                if not lines[k].strip() and k < i - 1:
                    break  # blank line ends the block (but allow one directly above)
                k -= 1
            head = "\n".join(lines[k + 1:i])
            if marker not in head:
                continue
            checked += 1
            checked_defs.add((rel, i))
            waived = set(re.findall(t["marker"] + r"-ok:\s*(\w+)", body_txt + "\n" + head))
            for v in sorted(required - handled - waived):
                findings.append((rel, i + 1, m.group(1), v))

    # A marker must attach to a walker of THIS tree. 2026-10-21: two helpers inserted
    # between checkCallsInExpr's marker block and its `def` (BUG-551/609) left the marker
    # above a non-walker, so checkCallsInExpr dropped out of the gate -- opted-in 13 -> 12
    # while the marker count stayed 13 and every run printed clean. A marker that
    # attaches to nothing is now a FINDING, named by line, not a smaller number.
    for rel in sorted({r for r, _ in marker_lines}):
        flines = io.open(REPO / rel, encoding="utf-8").read().split("\n")
        here = {ln for r, ln in checked_defs if r == rel}
        for ml, nxt in stranded_markers(flines, marker_re, here):
            print(f"  {rel}:{ml + 1}: [stranded-marker] `# {marker}` attaches to `{nxt}`, "
                  f"which is not a walker of {t['tag']} -- move the marker to the def it "
                  f"describes")
            findings.append((rel, ml + 1, "<stranded marker>", "-"))
    for rel, ln, fn, v in findings:
        if fn == "<stranded marker>":
            continue
        print(f"  {rel}:{ln}: [walker-drift] {fn}() does not handle {t['tag']}.{v}, "
              f"which {t['oracle']} says contains expressions")
    if checked < total_walkers:
        print(f"              NOT checked ({t['name']}): {total_walkers - checked} walker(s) "
              f"without `# {marker}`. Most legitimately care about a few forms; add the "
              f"marker to any that should be complete.")
    summary = (f"{t['name']}: {len(variants)} variants ({len(required)} bearing, "
               f"{len(leaves)} leaf), {checked}/{total_walkers} walkers opted in")
    return findings, checked, summary


def stranded_markers(lines, marker_re, checked_def_lines):
    """Marker comment lines whose comment block does not end at a counted walker's def."""
    out = []
    for ml, line in enumerate(lines):
        if not marker_re.match(line):
            continue
        j = ml + 1
        while j < len(lines) and (lines[j].strip().startswith("#") or not lines[j].strip()):
            j += 1
        if j not in checked_def_lines:
            out.append((ml, lines[j].strip()[:60] if j < len(lines) else "<end of file>"))
    return out


def stranded_control():
    """Both directions, on planted text: a marker over a non-walker must be found, and one
    over a counted walker must not. A detector that cannot see is refused, not trusted."""
    mre = re.compile(r"^\s*#\s*expr-walker: exhaustive\s*$")
    planted = ["# expr-walker: exhaustive", "# expr-walker-ok: ident why", "def helper(): int", "    return 1"]
    if len(stranded_markers(planted, mre, set())) != 1:
        return "a marker above a non-walker was NOT reported"
    if stranded_markers(planted, mre, {2}):
        return "a marker above a counted walker WAS reported"
    return ""


def main():
    ctl = stranded_control()
    if ctl:
        return refuse("stranded-marker control failed: " + ctl)
    results = []
    for t in TREES:
        r = check_tree(t)
        if isinstance(r, int):
            return r
        results.append(r)

    # Each tree must have at least one opted-in walker, or its half of the gate passes
    # vacuously -- the state the PNode half was in for its whole life before 2026-10-13.
    for t, (_, checked, _) in zip(TREES, results):
        if checked == 0:
            return refuse(f"no {t['name']} walker opted in with `# {t['marker']}: "
                          f"exhaustive` — that half of the gate would pass vacuously")

    findings = [f for r in results for f in r[0]]
    print("              NOT checked: whether a handled variant is handled CORRECTLY, "
          "and any name embedded in a zig\"…\" string (BUG-267 — structurally invisible).")
    # The verdict prints LAST on purpose: gates.sh shows a gate's final non-empty line on
    # the board, so a trailing caveat would display in place of the result.
    print(f"[expr-walker] {'; '.join(r[2] for r in results)}; {len(findings)} finding(s)")

    if "--gate" in sys.argv and findings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
