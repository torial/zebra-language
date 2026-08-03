#!/usr/bin/env python3
"""stdlib_run_coverage.py -- which stdlib namespaces have a RUN-AND-COMPARE fixture?

WHY
---
B1's mutation testing produced four survivors in four different stdlib emitters
(`genWsCall`, `genTerminalCall`, `genUriCall`, `genSqliteParams`). Four hits in one
subsystem out of a random sample is not a coincidence -- it says the subsystem is
systematically unwatched, and the four are only the ones the sampler happened to land on.
There are 38 `gen<Thing>Call` emitters. This answers "how many of them does anything
actually RUN and check the output of?"

WHAT "COVERED" MEANS HERE, precisely, because the word does a lot of work:
a namespace is COVERED if some test registered with `smoke_run`, `smoke_run_bounded` or
`smoke_test` (i.e. one whose OUTPUT is compared, not merely compiled) mentions
`Namespace.` in its source. That is a generous definition -- mentioning `Sqlite.` once does
not exercise every branch of `genSqliteCall`. So this tool gives an UPPER BOUND on
coverage; the real figure is worse.

HOW MUCH WORSE, with a receipt (2026-08-03): `Tcp` and `Http` are counted as covered on
the strength of `tcp_serve_test.zbr` / `http_serve_test.zbr`, whose `main` only prints a
string -- the `Tcp.serve` / `Http.serve` calls sit in a `startServer()` that NOTHING EVER
CALLS. Both fixtures pass; neither binds a socket. The fixtures are honest (their comments
say "compile smoke"); this tool cannot tell a compile smoke from a run fixture. Read every
figure below with that in mind.
It is still the right first cut, because a namespace with ZERO run-fixtures cannot have
any of its emitter's branches checked, and that set is what to work through first.

Blind by construction: `--emit-zig`-only gates (compile_check, full_sweep, divergence)
prove the emitted Zig COMPILES. Every survivor in this family produced compiling Zig that
did the wrong thing.

Exit 0 always -- this is a map, not a gate.
"""
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CODEGEN = REPO / "selfhost" / "CodeGen.zbr"
SMOKE = REPO / "tools" / "selfhost_smoke.sh"

DISPATCH = re.compile(
    r'if\s+id\.name\s*==\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*\n\s*(gen[A-Za-z]*Call)\(')
# ORDER IS LOAD-BEARING: `smoke_run_bounded` must precede `smoke_run`. Alternation is
# first-match-wins, so `smoke_run` would match the prefix and then the `\s+` would fail
# against `_bounded`, silently dropping every bounded registration. That is exactly what
# happened when smoke_run_bounded was added on 2026-08-03: the meter kept reporting 28/30
# while the two new fixtures sat registered and passing. A meter that misses a whole
# REGISTRATION HELPER under-reports without any error, which is the failure mode this
# repo cares about most -- so any new smoke_* helper whose output is compared must be
# added here in the same change that introduces it.
RUN_REG = re.compile(r'^(?:smoke_run_bounded|smoke_run|smoke_test)\s+(\S+)', re.M)


def namespaces():
    """namespace -> emitter, read from the dispatcher rather than guessed from names."""
    text = CODEGEN.read_text(encoding="utf-8")
    out = {}
    for ns, fn in DISPATCH.findall(text):
        out.setdefault(ns, fn)
    return out


def run_fixtures():
    """Tests whose OUTPUT is compared, not merely compiled."""
    text = SMOKE.read_text(encoding="utf-8")
    files = []
    for rel in RUN_REG.findall(text):
        p = REPO / rel
        if p.is_file():
            files.append(p)
    return files


def main():
    ns_map = namespaces()
    fixtures = run_fixtures()
    if not ns_map or not fixtures:
        print(f"REFUSING: parsed {len(ns_map)} namespaces and {len(fixtures)} run-fixtures; "
              f"one of the two parsers has stopped working and any coverage number would "
              f"be fiction.")
        return 2

    blobs = [(f, f.read_text(encoding="utf-8", errors="replace")) for f in fixtures]
    covered, uncovered = {}, {}
    for ns, fn in sorted(ns_map.items()):
        hits = [f.name for f, t in blobs if re.search(rf"\b{re.escape(ns)}\.", t)]
        (covered if hits else uncovered)[ns] = (fn, hits)

    # CONTROLS -- they test the MECHANISM, not a particular answer.
    #
    # The first version asserted `Terminal` must report UNCOVERED, citing mutation survivor
    # 15635. That was true when written and FIRED THE DAY Terminal was covered -- correct
    # tripwire behaviour, and the same shape as an `@boundary-pending` probe going red when
    # its bug is fixed. But a control pinned to a specific gap rots every time the gap is
    # closed, which is precisely when you least want to be editing your instrument.
    #
    # So: a namespace no fixture could possibly mention must classify UNCOVERED, and a
    # token that demonstrably appears in a fixture must classify COVERED. Both are derived
    # from the corpus at runtime, so they stay valid however coverage moves.
    def classify(token):
        return any(re.search(rf"\b{re.escape(token)}\.", t) for _, t in blobs)

    if classify("ZzNoSuchNamespaceZz"):
        print("CONTROL FAILED: a namespace that appears nowhere classified as COVERED. "
              "The matcher is matching everything; refusing to report.")
        return 2
    witness = next((m.group(1) for _, t in blobs
                    for m in [re.search(r"\b([A-Z][A-Za-z0-9_]{2,})\.", t)] if m), None)
    if witness is None or not classify(witness):
        print(f"CONTROL FAILED: could not find a namespace-shaped token in the fixtures, "
              f"or failed to match one that is there ({witness!r}). The matcher is not "
              f"working; refusing to report.")
        return 2

    print(f"stdlib run-and-compare coverage — {len(covered)}/{len(ns_map)} namespaces "
          f"have ANY output-checked fixture\n")
    print(f"UNCOVERED ({len(uncovered)}) — nothing runs these and reads what they printed:")
    for ns, (fn, _) in sorted(uncovered.items()):
        print(f"    {ns:<16} {fn}")
    print(f"\ncovered ({len(covered)}) — at least one run-fixture mentions the namespace:")
    for ns, (fn, hits) in sorted(covered.items()):
        print(f"    {ns:<16} {fn:<26} {len(hits)} fixture(s), e.g. {hits[0]}")
    print("\nUPPER BOUND: 'covered' means a fixture MENTIONS the namespace, not that it "
          "exercises every branch of the emitter. The real figure is worse than this.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
