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

    python tools/lint_expr_walkers.py           # report
    python tools/lint_expr_walkers.py --gate    # exit 1 on any finding
"""
import io
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
AST = REPO / "selfhost" / "Ast.zbr"
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

# Two variants bear identifiers WITHOUT holding child expressions, so no structural
# derivation can find them. Both are hardcoded, and both are named:
#   zig_lit — its identifiers live in a STRING. Exactly how BUG-267 survived: a
#             structural check looks at this and sees a leaf.
#   ident   — it IS the identifier. Structurally `span + name: str`, so the oracle
#             calls it a leaf, yet a usage walker that skips it is broken by
#             definition. Included so the gate cannot bless a walker that lost the
#             one case it exists to have.
SEMANTIC_BEARING = {"zig_lit", "ident"}


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


def bearing(payload, structs, unions, depth=0, seen=None):
    """True when `payload` reaches an Expr through its fields (one+ level)."""
    if payload == "Expr":
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
            if n == "Expr":
                return True
            if bearing(n, structs, unions, depth + 1, seen):
                return True
    return False


def main():
    src = io.open(AST, encoding="utf-8").read()
    unions = parse_blocks(src, "union")
    structs = parse_blocks(src, "struct")
    expr = unions.get("Expr")
    if not expr:
        print("[expr-walker] REFUSING: could not find `union Expr` in Ast.zbr", file=sys.stderr)
        return 2

    variants = {}
    for line in expr.split("\n"):
        m = re.match(r"^\s+(\w+)\s*:\s*\^?(\w+)", line)
        if m:
            variants[m.group(1)] = m.group(2)

    required = {v for v, p in variants.items() if bearing(p, structs, unions)} | SEMANTIC_BEARING
    leaves = set(variants) - required

    # ── Controls, run before reporting ────────────────────────────────────────
    # Pinned to the MECHANISM, not to a known gap: `list_lit` must classify as
    # ident-bearing (it holds `elems: List(Expr)`) and `int_lit` as a leaf. If the
    # extractor stops resolving field types, both flip and this refuses to report --
    # rather than announcing that every walker is clean.
    if len(variants) < 25:
        print(f"[expr-walker] REFUSING: only {len(variants)} Expr variants extracted "
              f"(expected 30+); the extractor is broken, not the code", file=sys.stderr)
        return 2
    if "list_lit" not in required:
        print("[expr-walker] REFUSING: control failed — list_lit did not classify as "
              "ident-bearing", file=sys.stderr)
        return 2
    if "int_lit" in required:
        print("[expr-walker] REFUSING: control failed — int_lit classified as "
              "ident-bearing", file=sys.stderr)
        return 2

    findings, checked, total_walkers = [], 0, 0
    for rel in SEARCH:
        p = REPO / rel
        if not p.exists():
            continue
        lines = io.open(p, encoding="utf-8").read().split("\n")
        for i, line in enumerate(lines):
            m = re.match(r"^\s*def\s+(\w+)", line)
            if not m:
                continue
            # gather the function body (until the next def at the same-or-lower indent)
            indent = len(line) - len(line.lstrip())
            body = []
            for j in range(i + 1, len(lines)):
                nxt = lines[j]
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent and \
                        re.match(r"^\s*(def|class|struct|union)\b", nxt):
                    break
                body.append(nxt)
            body_txt = "\n".join(body)
            if "on Expr." not in body_txt:
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
            if "expr-walker: exhaustive" not in head:
                continue
            checked += 1
            handled = set(re.findall(r"on\s+Expr\.(\w+)", body_txt))
            waived = set(re.findall(r"expr-walker-ok:\s*(\w+)", body_txt + "\n" + head))
            missing = sorted(required - handled - waived)
            for v in missing:
                findings.append((rel, i + 1, m.group(1), v))

    if checked == 0:
        print("[expr-walker] REFUSING: no walker opted in with `# expr-walker: exhaustive` "
              "— the gate would pass vacuously", file=sys.stderr)
        return 2

    for rel, ln, fn, v in findings:
        print(f"  {rel}:{ln}: [walker-drift] {fn}() does not handle Expr.{v}, "
              f"which the AST says contains expressions")

    if checked < total_walkers:
        print(f"              NOT checked: {total_walkers - checked} walker(s) without "
              f"`# expr-walker: exhaustive`. Most legitimately care about a few forms; "
              f"add the marker to any that should be complete.")
    print("              NOT checked: whether a handled variant is handled CORRECTLY, "
          "and any name embedded in a zig\"…\" string (BUG-267 — structurally invisible).")
    # The verdict prints LAST on purpose: gates.sh shows a gate's final non-empty line on
    # the board, so a trailing caveat would display in place of the result.
    print(f"[expr-walker] {len(variants)} Expr variants ({len(required)} ident-bearing, "
          f"{len(leaves)} leaf); {checked}/{total_walkers} walkers opted in; "
          f"{len(findings)} finding(s)")

    if "--gate" in sys.argv and findings:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
