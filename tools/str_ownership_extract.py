"""str_ownership_extract.py — derive the §28e borrows-vs-owns table from real emit.

WHY A TOOL AND NOT A READING OF CodeGen.zbr
-------------------------------------------
Whether `s.trim()` hands back a slice INTO the receiver or a freshly allocated copy
is a property of the Zig that codegen actually emits. Reading the ~500 lines of
`genStdlibMethod` and classifying by eye is exactly the repetitive judgement that
drifts: 30 near-identical decisions, any one of which is a documentation lie that
outlives the session. So: emit one program that calls every str-returning method,
then classify each emitted right-hand side mechanically.

The table this produces is EVIDENCE-BEARING — every row carries the emitted
expression it was classified from, so a future reader can check the claim without
re-deriving it, and a codegen change that flips an ownership will show up as a diff
in the snippet rather than as silently stale prose.

FALSIFICATION (this tool must be able to be wrong out loud)
-----------------------------------------------------------
A classifier that answers "borrow" for everything would produce a clean, plausible,
entirely useless table. So four CONTROLS with known-opposite answers are asserted
before any output is trusted (`upper`/`concat` must own, `trim`/`substring` must
borrow), and both classes must be non-empty. A method codegen does not intercept is
reported as UNKNOWN, never defaulted into a class — an unrecognised method emits as
a bare `recv.name()` call, which would otherwise look exactly like a borrow.

Usage:
    python tools/str_ownership_extract.py                 # print the table
    python tools/str_ownership_extract.py --write         # also write docs/str_ownership.md
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
ZEBRA = REPO / "zig-out" / "bin" / "zebra.exe"

# (label, receiver-var, call-source, note). Receivers are declared once below.
# Only str-RETURNING operations belong here; predicates and int-returning queries
# have no ownership to document.
CASES = [
    ("upper",        "s.upper()",              ""),
    ("lower",        "s.lower()",              ""),
    ("trim",         "s.trim()",               ""),
    ("trimLeft",     "s.trimLeft()",           ""),
    ("trimRight",    "s.trimRight()",          ""),
    ("reverse",      "s.reverse()",            ""),
    ("replace",      's.replace("l", "L")',    ""),
    ("replaceAll",   's.replaceAll("l", "L")', ""),
    ("repeat",       "s.repeat(2)",            ""),
    ("padLeft",      's.padLeft(20, " ")',     ""),
    ("padRight",     's.padRight(20, " ")',    ""),
    ("center",       's.center(20, " ")',      ""),
    ("concat",       's.concat("!")',          ""),
    ("substring",    "s.substring(0, 3)",      ""),
    ("toString",     "s.toString()",           "str receiver (identity-ish)"),
    ("toHex",        "s.toHex()",              ""),
    ("fromHex",      "h.fromHex()",            "receiver must be hex digits"),
    ("encodeBase64", "s.encodeBase64()",       ""),
    ("decodeBase64", "b.decodeBase64()",       "receiver must be base64"),
    ("charAt",       "s.charAt(0)",            "BUG-223: typed str, emits u8"),
    ("slice_expr",   "s[1..4]",                "slicing syntax, not a method"),
    ("join",         'parts.join(", ")',       "called on List(str)"),
    ("format",       "f.format(1)",            "variadic; see BUG-224 for 2+ args"),
    ("lines",        "s.lines()",              ""),
    ("split",        's.split(",")',           ""),
    ("tokenize",     's.tokenize(",")',        ""),
    ("chars",        "s.chars()",              "for-only; binding emits invalid Zig"),
    ("bytes",        "s.bytes()",              "for-only; binding emits invalid Zig"),
]

# The `for` forms of the two iterators that cannot be bound. Their yielded ownership is
# not derivable from a binding (there is no valid binding), so these rows are stated by
# hand from the loop codegen and marked as such — an underived row must never be
# presented with the same authority as a derived one.
HAND_STATED = [
    ("for c in s.chars()", "VALUE", "decoded u21 codepoint — aliases nothing"),
    ("for byte in s.bytes()", "VALUE", "single u8 — aliases nothing"),
]

RECEIVERS = [
    'var s = "Hello World"',
    'var h = "48656c6c6f"',
    'var b = "SGVsbG8="',
    'var f = "{} and {}"',
    'var parts: List(str) = ["a", "b"]',
]
RECV_NAMES = ("s", "h", "b", "f", "parts")

# An emitted RHS is OWNING if it allocates. `_allocator` (however qualified — the
# runtime-module default emits `_zbr_rt._allocator`) is the program arena; the
# alloc* / dupe / join / concat helpers all allocate through it.
OWN_MARKERS = (
    "_allocator", ".dupe(", "allocPrint", "allocUpperString", "allocLowerString",
    "std.mem.join", "std.mem.concat", "ArrayList",
)

# Controls: known answers that must come out opposite. If these ever agree, the
# classifier has stopped discriminating and every other row is worthless.
#
# `encodeBase64` and `charAt` are here because each caught a real defect in this
# tool. encodeBase64 emits `_base64_encode(s)` — no allocator at the CALL SITE, so
# the first version reported BORROW for a buffer that is freshly allocated inside
# the helper. charAt emits `s[i]`, a u8 VALUE that aliases nothing, and was being
# forced into the borrow/own dichotomy where it does not belong. Both stay as
# controls so neither blind spot can silently return.
#
# `chars` is a control for the UNKNOWN branch itself: it is a for-only iterator, so a
# bound `s.chars()` emits a verbatim `s.chars()` call that no Zig type provides. If that
# ever classifies as a borrow or an own, the unintercepted-call detector has stopped
# working and unrecognised methods are being quietly absorbed into a class.
CONTROLS = {
    "upper": "OWN", "concat": "OWN", "encodeBase64": "OWN",
    "trim": "BORROW", "substring": "BORROW",
    "charAt": "VALUE",
    "chars": "UNKNOWN",
}


def build_program():
    lines = ["def main()"]
    for decl in RECEIVERS:
        lines.append(f"    {decl}")
    for label, call, _ in CASES:
        lines.append(f"    var r_{label} = {call}")
    # Printing keeps every result live, so codegen cannot elide a call we came to
    # measure. charAt's print emits a `{s}` against a u8 — that malformed emit IS
    # the BUG-223 evidence, and it is harmless here because we never compile.
    for label, _, _ in CASES:
        lines.append(f"    print(r_{label})")
    return "\n".join(lines) + "\n"


def emit(tmp: pathlib.Path) -> str:
    src = tmp / "ownprobe.zbr"
    src.write_text(build_program(), encoding="utf-8", newline="\n")
    out = tmp / "out"
    out.mkdir(parents=True, exist_ok=True)  # --output-dir panics if absent (see docs)
    proc = subprocess.run(
        [str(ZEBRA), "--emit-zig", "--output-dir", str(out), str(src)],
        capture_output=True, text=True,
    )
    zig = out / "ownprobe.zig"
    if not zig.exists():
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit("emit produced no ownprobe.zig — cannot classify anything")
    return zig.read_text(encoding="utf-8")


def preamble_bodies() -> dict:
    """name -> body text, for every top-level fn in the runtime preamble.

    Needed because ownership is not always visible at the call site: `_base64_encode(s)`
    takes no allocator yet allocates from the global `_allocator` inside. Without this
    resolution the tool reports a fresh buffer as a borrow.
    """
    text = (REPO / "selfhost" / "stdlib_preamble.zig").read_text(encoding="utf-8")
    bodies, cur, buf = {}, None, []
    for line in text.splitlines():
        m = re.match(r"(?:pub )?fn (_[A-Za-z_0-9]+)\(", line)
        if m:
            cur, buf = m.group(1), [line]
        elif cur is not None:
            buf.append(line)
            if line == "}":                      # top-level fn close, column 0
                bodies[cur] = "\n".join(buf)
                cur = None
    return bodies


BODIES = preamble_bodies()
# What counts as allocation inside a helper body. Narrower than OWN_MARKERS: a body
# mentioning `ArrayList` may only be iterating one.
BODY_ALLOC = ("_allocator.alloc", "_allocator.dupe", "allocPrint", ".toOwnedSlice(")


SPLIT_HELPERS = ("splitSequence(u8, ", "splitScalar(u8, ", "splitAny(u8, ",
                 "tokenizeSequence(u8, ", "tokenizeScalar(u8, ", "tokenizeAny(u8, ")


def element_class(rhs: str, declared: str) -> str:
    """Ownership of the ELEMENTS, for operations returning a container.

    This is the distinction §28e exists for and the one a single column hides:
    `s.split(",")` hands back a `List(str)` that the caller OWNS, whose elements are
    subslices BORROWED from the receiver. Under the program arena nobody notices. Inside
    an `allocate` scope that owns the receiver, keeping that list past the scope is a
    use-after-free with an owned container wrapped around it.
    """
    # Prefer the DECLARED type over the expression. `repeat()` returns a `[]const u8` but
    # uses an ArrayList as internal scratch, so testing the expression reported a phantom
    # element class for a result that has no elements. Codegen does not annotate every
    # binding, though — `tokenize()` emits a bare `const r = (blk: {...})` — so fall back
    # to the expression when there is no annotation to gate on.
    container = ("ArrayList" in declared) if declared else ("ArrayList" in rhs)
    if not container:
        return "—"
    if any(h in rhs for h in SPLIT_HELPERS):
        return "BORROW"
    if any(m in rhs for m in ("_allocator.dupe", "_allocator.alloc", "allocPrint")):
        return "OWN"
    return "?"


def classify(rhs: str, label: str) -> str:
    # A method codegen never intercepted comes out as a call on the RECEIVER VARIABLE
    # itself (`s.foo()`). That is NOT a borrow; it is an unknown, and must be reported
    # as one. The receiver name is load-bearing here: an earlier version matched any
    # dotted call, so `std.mem.trim(...)` — a genuine, correct borrow — was reported as
    # UNKNOWN. The controls caught it on the first run, which is what they are for.
    if re.search(r"\b(?:" + "|".join(RECV_NAMES) + r")\." + re.escape(label) + r"\(", rhs):
        return "UNKNOWN"

    # Element access (`s[i]`, no `..`) yields a BYTE, not a slice. It aliases nothing,
    # so neither "borrow" nor "own" applies — forcing it into one of them is the same
    # category error BUG-223 makes in the type itself.
    if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*\[[^\]]*\]", rhs) and ".." not in rhs:
        return "VALUE"

    if any(m in rhs for m in OWN_MARKERS):
        return "OWN"

    # Follow one level into a preamble helper: the allocation may be in its body.
    for callee in re.findall(r"\b(_[A-Za-z_0-9]+)\s*\(", rhs):
        body = BODIES.get(callee)
        if body and any(m in body for m in BODY_ALLOC):
            return "OWN"
    return "BORROW"


def main() -> int:
    if not ZEBRA.exists():
        raise SystemExit(f"no compiler at {ZEBRA} — run `zig build` first")
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="zbr-own-"))
    try:
        text = emit(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    rows, missing = [], []
    for label, call, note in CASES:
        # The type annotation is OPTIONAL: an unintercepted method (`s.chars()`) emits a
        # bare `const r = s.chars();` with no annotation at all. Requiring one made the
        # UNKNOWN control look merely unbindable, hiding the branch it exists to test.
        m = re.search(r"^\s*(?:const|var) r_" + re.escape(label) +
                      r"\s*(?::\s*([^=]*?))?\s*=\s*(.+?);\s*$", text, re.M)
        if not m:
            # No emitted binding. For a control that is fatal; otherwise it is a real
            # finding about the operation (typically an iterator that cannot be bound),
            # and belongs in the output rather than being dropped on the floor.
            missing.append(label)
            rows.append((label, call, "UNBINDABLE", "—", note, "—"))
            continue
        declared = (m.group(1) or "").strip()
        rhs = m.group(2).strip()
        rows.append((label, call, classify(rhs, label), rhs, note,
                     element_class(rhs, declared)))

    # ── controls, before anything is believed ────────────────────────────────
    got = {label: cls for label, _, cls, _, _, _ in rows}
    errs = [f"control {k}: expected {v}, got {got.get(k, 'MISSING')}"
            for k, v in CONTROLS.items() if got.get(k) != v]
    classes = {c for c in got.values() if c not in ("UNKNOWN", "UNBINDABLE")}
    if len(classes) < 2:
        errs.append(f"classifier did not discriminate — every row came out {classes}")
    unbindable_controls = [k for k in CONTROLS if k in missing]
    if unbindable_controls:
        errs.append("no emitted binding for control(s): " + ", ".join(unbindable_controls))
    if errs:
        sys.stderr.write("CLASSIFIER FAILED ITS OWN CONTROLS:\n")
        for e in errs:
            sys.stderr.write(f"  - {e}\n")
        sys.stderr.write("Refusing to print a table that cannot be trusted.\n")
        return 2

    lines = [
        "| operation | result | elements | emitted Zig | note |",
        "|---|---|---|---|---|",
    ]
    for label, call, cls, rhs, note, elem in sorted(rows, key=lambda r: (r[2], r[0])):
        snippet = rhs if len(rhs) <= 70 else rhs[:67] + "..."
        elem_cell = f"**{elem}**" if elem not in ("—", "?") else elem
        lines.append(f"| `{call}` | **{cls}** | {elem_cell} | `{snippet}` | {note} |")
    table = "\n".join(lines)

    hand = ["| iteration form | ownership of what it yields | why |", "|---|---|---|"]
    for form, cls, why in HAND_STATED:
        hand.append(f"| `{form}` | **{cls}** | {why} |")
    hand_table = "\n".join(hand)

    print(table)
    print("\nfor-only iterators (hand-stated, NOT derived — cannot be bound):\n")
    print(hand_table)

    counts = {}
    for _, _, c, _, _, _ in rows:
        counts[c] = counts.get(c, 0) + 1
    summary = ", ".join(f"{n} {c.lower()}" for c, n in sorted(counts.items()))
    print(f"\n{len(rows)} derived operations: {summary}  (controls passed)"
          f"\n{len(HAND_STATED)} hand-stated iterator forms")

    if "--write" in sys.argv or "--check" in sys.argv:
        dest = REPO / "docs" / "str_ownership.md"
        body = (
            "# `str` ownership per operation (§28e)\n\n"
            "**GENERATED** by `tools/str_ownership_extract.py` from real compiler emit — "
            "do not hand-edit. Regenerate after any change to string codegen; a flipped "
            "ownership shows up as a changed snippet.\n\n"
            "**BORROW** = the result aliases the receiver's bytes; it dies when the "
            "receiver does, and it is not safe to keep past an `allocate` scope that "
            "owns the receiver.\n\n"
            "**OWN** = freshly allocated in the program arena (`_allocator`); "
            "independent of the receiver's lifetime.\n\n"
            "**VALUE** = a byte or codepoint, not a slice. Aliases nothing, so neither "
            "borrow nor own applies.\n\n"
            + table + "\n\n"
            "## for-only iterators\n\n"
            "These cannot be bound to a variable, so no emitted binding exists to "
            "classify. The rows below are **hand-stated from the iterator codegen, not "
            "derived** — treat them with less authority than the table above.\n\n"
            + hand_table + "\n")
        if "--check" in sys.argv:
            # A generated doc that drifts from the compiler is a documentation lie with a
            # "GENERATED" banner vouching for it — worse than no table. Gate it.
            current = dest.read_text(encoding="utf-8") if dest.exists() else ""
            if current != body:
                sys.stderr.write(
                    f"{dest.relative_to(REPO)} is STALE — string codegen changed an "
                    f"ownership since it was generated.\n"
                    f"Regenerate with: python tools/str_ownership_extract.py --write\n"
                    f"then read the diff: an ownership FLIP is a semantic change, not a "
                    f"doc chore.\n")
                return 1
            print(f"{dest.relative_to(REPO)} is current")
            return 0
        dest.write_text(body, encoding="utf-8", newline="\n")
        print(f"wrote {dest.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
