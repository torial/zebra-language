"""lint_bug_numbers.py — THE BUG-NUMBER COLLISION GATE.

Two agents work in this tree, and both allocate a bug number the same way: read
`BUGS.md`, take the next one. Between one reading it and committing, the other can
file twice. It happened TWICE on 2026-08-06 alone:

  * BUG-260 — Fable's query-bind-list bug and a C-linking bug, filed hours apart.
    Untangling it needed `git log -S` archaeology to establish which was first.
  * BUG-269 — Fable's extern-C-ABI bug and an `old p` walker bug. Caught only
    because a `grep` happened to print two identical headings next to each other.

NO EXISTING GATE CAN SEE THIS. `doc_lint` D4 checks that a cited `BUG-NNN`
*resolves* to an entry — and a duplicated number resolves twice over, so a collision
makes D4 *more* satisfied, not less. The failure is invisible precisely because the
thing that would notice it is looking for presence.

WHAT IS AND IS NOT A COLLISION. Some numbers are shared on purpose: `BUG-009 (a)` /
`BUG-009 (b)` and `BUG-060a` / `BUG-060b` are sub-lettered parts of one bug, which is
a reasonable convention and not an error. So the check is not "is this number used
twice" but "does this number carry two entries that are not sub-lettered apart" --
and even that has pre-existing instances, so it is BASELINED and fails only on NEW
debt, the same shape as bug_fixture_check and registration_check.

The second leg has no baseline because it is never legitimately wrong: the
"Last bug number generated" line must be >= the highest heading. That line is what
the next person reads to pick a number, so when it lags, the NEXT collision is
already scheduled.

    python tools/lint_bug_numbers.py                    # report
    python tools/lint_bug_numbers.py --gate             # exit 1 on NEW debt
    python tools/lint_bug_numbers.py --update-baseline  # accept current debt
"""
import io
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
LEDGERS = ["BUGS.md", "BUGS_FIXED.md"]
BASELINE = REPO / "tools" / "bug_number_baseline.txt"

HEADING = re.compile(r"^###\s+BUG-(\d+)\s*(\(?([a-z])\)?)?", re.M)


def collect():
    """slot -> [(file, heading text)], where slot is number + optional sub-letter."""
    slots = {}
    for rel in LEDGERS:
        p = REPO / rel
        if not p.exists():
            continue
        for line in io.open(p, encoding="utf-8").read().split("\n"):
            m = HEADING.match(line)
            if not m:
                continue
            slot = m.group(1) + (m.group(3) or "")
            slots.setdefault(slot, []).append((rel, line.strip()))
    return slots


def last_declared():
    p = REPO / "BUGS.md"
    m = re.search(r"Last bug number generated:\s*BUG-(\d+)", io.open(p, encoding="utf-8").read())
    return int(m.group(1)) if m else None


def main():
    slots = collect()

    # ── Controls, before reporting anything ──────────────────────────────────
    # A regex that has stopped matching would report a pristine ledger. Pinned to the
    # mechanism: the ledgers are large, so a tiny count means the extractor broke.
    if len(slots) < 150:
        print(f"[bug-numbers] REFUSING: only {len(slots)} bug headings extracted "
              f"(expected 150+) — the extractor is broken, not the ledger", file=sys.stderr)
        return 2
    # A synthetic collision must be detectable, derived at runtime rather than pinned
    # to a known-bad entry (which would break on the day someone fixes it).
    probe = dict(slots)
    probe.setdefault("999999", []).extend([("x", "### BUG-999999: a"), ("x", "### BUG-999999: b")])
    if len([s for s, v in probe.items() if len(v) > 1]) <= len([s for s, v in slots.items() if len(v) > 1]):
        print("[bug-numbers] REFUSING: control failed — a planted duplicate was not "
              "detected as one", file=sys.stderr)
        return 2

    dupes = {s: v for s, v in slots.items() if len(v) > 1}

    if "--update-baseline" in sys.argv:
        io.open(BASELINE, "w", encoding="utf-8", newline="\n").write(
            "# DERIVED by tools/lint_bug_numbers.py --update-baseline.\n"
            "# Bug-number slots carrying more than one heading. This is DEBT: each is a\n"
            "# number a reader cannot resolve to one bug. Shrink it, never grow it.\n"
            + "".join(f"{s}\n" for s in sorted(dupes, key=lambda x: (len(x), x))))
        print(f"[bug-numbers] baseline written: {len(dupes)} slot(s)")
        return 0

    known = set()
    if BASELINE.exists():
        known = {ln.strip() for ln in io.open(BASELINE, encoding="utf-8")
                 if ln.strip() and not ln.startswith("#")}

    new = sorted(set(dupes) - known, key=lambda x: (len(x), x))
    for s in new:
        print(f"  BUG-{s}: {len(dupes[s])} headings share this number —")
        for rel, txt in dupes[s]:
            print(f"      {rel}: {txt[:96]}")

    # ── Leg 2: the allocator line must not lag ───────────────────────────────
    last = last_declared()
    highest = max(int(re.sub(r"[a-z]", "", s)) for s in slots)
    lag = last is not None and last < highest
    if lag:
        print(f"  BUGS.md: 'Last bug number generated: BUG-{last}' is BELOW the highest "
              f"heading (BUG-{highest}) — the next person to read it will collide")
    if last is None:
        print("  BUGS.md: no 'Last bug number generated' line found")

    print("              NOT checked: whether two entries sharing a number are actually "
          "the same bug — only that a reader cannot tell them apart by number.")
    # Verdict LAST — gates.sh displays the final non-empty line.
    print(f"[bug-numbers] {len(slots)} slots across {len(LEDGERS)} ledger(s); "
          f"{len(dupes)} shared ({len(known)} known debt), {len(new)} NEW; "
          f"allocator line {'LAGS' if lag else 'ok'}")

    if "--gate" in sys.argv and (new or lag or last is None):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
