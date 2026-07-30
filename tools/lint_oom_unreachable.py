"""lint_oom_unreachable.py — A4 GUARD: no `catch unreachable` on an allocation.

THE HAZARD
----------
In `ReleaseFast` / `ReleaseSmall`, Zig's `unreachable` is **undefined behaviour**, not a
crash. `zebra --release` builds with `-OReleaseFast`, and that is the artifact a user
ships. So `alloc(...) catch unreachable` in emitted code means an out-of-memory condition
in a user's program is UB — it may corrupt, or continue with garbage, rather than fail.

WHY NO GATE CAN CATCH IT
------------------------
Every gate in this repo runs the DEFAULT build, which is Debug (the self-hosted backend,
no `-O` flag). In Debug and ReleaseSafe, `unreachable` traps cleanly with "reached
unreachable code". So the hazard is invisible in testing and live only in what users
distribute — works in test, undefined in production, which is the definition of a
surprise. A static lint is the only thing that can see it, which is why this file exists
rather than a fixture.

THE RULE
--------
An allocation that can fail must use `catch @panic("OOM")` — a clean, diagnosable abort
in EVERY build mode — which is already what ~148 other sites do. Fixed 2026-07-30
(20 emit sites in CodeGen.zbr + 1 in stdlib_preamble.zig); this keeps it fixed.

ALLOWED: `catch unreachable` where the error is genuinely impossible, e.g.
`std.fmt.bufPrint` into an exactly-sized buffer. Those are recognised by ALLOWED_MARKERS
and must stay narrow — the point of the exemption is "this error cannot occur", not "this
error is unlikely".

    python tools/lint_oom_unreachable.py        # 0 = clean
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
TARGETS = ["selfhost/CodeGen.zbr", "selfhost/stdlib_preamble.zig",
           "selfhost/napi_preamble.zig"]

# Constructs that can fail ONLY on allocation.
ALLOC_PATTERNS = re.compile(
    r"\.alloc\(|\.create\(|\.dupe\(|\.dupeZ\(|allocPrint|allocUpperString|"
    r"allocLowerString|replaceOwned|std\.mem\.concat|std\.mem\.join|\.append\(|"
    r"\.appendSlice\(|toOwnedSlice|\.put\(|\.ensureTotal")

# Narrow, justified exemptions: the error is impossible, not merely unlikely.
ALLOWED_MARKERS = ("bufPrint",)


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    hazards, scanned = [], 0
    for rel in TARGETS:
        p = REPO / rel
        if not p.exists():
            continue
        scanned += 1
        for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if "catch unreachable" not in line:
                continue
            if any(m in line for m in ALLOWED_MARKERS):
                continue
            if ALLOC_PATTERNS.search(line):
                hazards.append((rel, n, line.strip()[:100]))

    if scanned == 0:
        # A linter with nothing to scan is reporting on itself, not on the repo.
        sys.stderr.write("no target files found — the paths moved. Refusing all-clear.\n")
        return 2

    for rel, n, text in hazards:
        print(f"{rel}:{n}: allocation with `catch unreachable` (UB in ReleaseFast)")
        print(f"    {text}")
    print(f"[oom-unreachable-lint] {len(hazards)} hazard(s) across {scanned} file(s)")
    if hazards:
        print('Use `catch @panic("OOM")` — a clean abort in every build mode.')
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
