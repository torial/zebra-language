#!/usr/bin/env python3
"""
mutation_check.py — B1 of docs/testing_strategy.md: mutation testing of the compiler.

THE QUESTION THIS ANSWERS, WHICH NOTHING ELSE HERE DOES
--------------------------------------------------------
Every other gate asks "is the compiler correct?". This asks **"would we notice if it
weren't?"** It perturbs the compiler's own source one edit at a time — invert a
condition, drop an emit, change a constant — rebuilds, and records whether ANY gate
complains. Over enough mutants that yields a number with real content:

    our gates catch N% of changes to the compiler

That is the honest substitute for a coverage percentage, and it is `gate_selfcheck.sh`
aimed one level deeper: that file proves a gate CAN fail on a defect chosen to trip it;
this one plants defects nobody chose and counts what gets through.

**The product is not the percentage. It is the SURVIVOR LIST** — each survivor is a
place the compiler can be changed with no gate noticing, which is a coverage hole with
an address.

WHY THIS IS AFFORDABLE, CONTRA THE PLAN
---------------------------------------
testing_strategy.md budgeted "each mutant needs a rebuild" as the blocker. Measured
2026-07-31, that is wrong by an order of magnitude:

    regen ONE module via the bootstrap   ~22 s   (not the full 12-module regen)
    zig build with one module changed     ~3 s   (self-hosted backend, content-hashed)

~25 s per mutant plus detection. Mutating a single module and regenerating only that
module is what makes it cheap; the full `rebuild.sh` cycle is unnecessary here.

ISOLATION IS NOT OPTIONAL
-------------------------
A run leaves the compiler broken for seconds at a time, hundreds of times over. Another
session sharing this checkout would be handed a compiler that is not what it thinks it
is — the exact hazard recorded in BUG-238. So everything happens in a **git worktree**,
and the live tree is never touched. Tracked files are ~42 MB, so this is cheap.

USAGE
    python tools/mutation_check.py --list                 # what would be mutated
    python tools/mutation_check.py --limit 10             # a short validation run
    python tools/mutation_check.py --limit 200 --seed 7   # an overnight run
"""
import argparse, json, os, pathlib, random, re, shutil, subprocess, sys, time

REPO = pathlib.Path(__file__).resolve().parent.parent
ZIG = r"C:\Users\Sean\.zvm\bin\zig.exe"
# GIT BASH, spelled out. A bare "bash" launched from Python resolves to WSL's bash on
# this machine, which rewrites C:\ as /mnt/c/ — and the Windows zebra.exe then reports
# "source file not found: '/mnt/c/...'" for every probe. The boundary detector went RED
# for that reason alone while passing 20/20 when run by hand, which would have scored
# every mutant DETECTED-by-boundary: a harness reporting perfect gates because its own
# detector was broken. (CLAUDE.md/memory already records "Bash tool = Git Bash, never
# WSL" — the trap is that Python does not inherit that choice.)
BASH = r"C:\Program Files\Git\bin\bash.exe"
# MUST be a SIBLING of the repo: build.zig declares a path dependency on `../earley`,
# so a worktree anywhere else fails with "unable to open '.../../earley': FileNotFound".
# Caught by the baseline check on the very first run — without that assertion every
# mutant would have reported DETECTED(build) and this harness would have scored a
# confident, meaningless 100%. A mutation tool that cannot build is not measuring gates.
WORKTREE = pathlib.Path(r"C:\Projects\zebra-mutants")

# Modules to mutate. CodeGen and TypeChecker are named in the plan: they are where a
# wrong belief turns into wrong output, and between them they produced BUG-215/218/222/
# 223/226/230/232/236.
TARGETS = ["selfhost/CodeGen.zbr", "selfhost/TypeChecker.zbr"]


# ── mutation operators ───────────────────────────────────────────────────────
# Deliberately SMALL and semantic. A mutant that cannot possibly compile teaches
# nothing about the gates — it only measures the Zig compiler. These each produce
# code that still parses and still type-checks, so the question stays "does any gate
# notice the BEHAVIOUR change", which is the one worth asking.
OPERATORS = [
    # comparison flips — the classic off-by-one / inverted-guard family
    ("cmp", re.compile(r"(?<![<>=!])==(?!=)"), "<>"),
    ("cmp", re.compile(r"<>"), "=="),
    ("cmp", re.compile(r"(?<![<>=])>(?![=>])"), ">="),
    ("cmp", re.compile(r"(?<![<>=])<(?![=<>])"), "<="),
    # boolean connective — swaps the strength of a guard without breaking parsing
    ("bool", re.compile(r"\band\b"), "or"),
    ("bool", re.compile(r"\bor\b"), "and"),
    # constants — the +1 that a boundary test should catch
    ("const", re.compile(r"(?<![\w.])0(?![\w.])"), "1"),
    ("const", re.compile(r"(?<![\w.])1(?![\w.])"), "0"),
    # returned truth — inverts a predicate's answer
    ("ret", re.compile(r"\breturn true\b"), "return false"),
    ("ret", re.compile(r"\breturn false\b"), "return true"),
]

# Lines that must never be mutated: mutating a comment changes nothing (a wasted
# ~25 s), and mutating an emit STRING changes generated text in ways that are really
# testing Zig, not us.
SKIP_LINE = re.compile(r"^\s*#")


def candidate_sites(path: pathlib.Path):
    """Every (line_no, col, op_name, old, new) this file admits."""
    out = []
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
        if SKIP_LINE.match(line) or not line.strip():
            continue
        # Ignore anything inside a string literal: those are emitted Zig text, and
        # perturbing them measures Zig's parser rather than our gates.
        masked = re.sub(r'"(?:[^"\\]|\\.)*"', lambda m: " " * len(m.group(0)), line)
        for op_name, pat, repl in OPERATORS:
            for m in pat.finditer(masked):
                out.append((i, m.start(), m.end(), op_name, m.group(0), repl))
    return out


def run(cmd, cwd, timeout=900, env=None):
    try:
        p = subprocess.run(cmd, cwd=str(cwd), capture_output=True, timeout=timeout,
                           env=env, shell=isinstance(cmd, str))
        return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return 124, "<<TIMEOUT>>"


def ensure_worktree():
    """Isolated checkout. The live tree is never mutated — see the header."""
    if WORKTREE.exists() and (WORKTREE / "build.zig").exists():
        return
    WORKTREE.parent.mkdir(parents=True, exist_ok=True)
    if WORKTREE.exists():
        shutil.rmtree(WORKTREE, ignore_errors=True)
    rc, out = run(["git", "worktree", "add", "--detach", str(WORKTREE), "HEAD"], REPO)
    if rc != 0:
        sys.exit(f"could not create worktree:\n{out}")


def build(wt):
    """Rebuild the mutant compiler. Returns (ok, log)."""
    env = dict(os.environ)
    env["PATH"] = str(pathlib.Path(ZIG).parent) + os.pathsep + env.get("PATH", "")
    return run([ZIG, "build"], wt, timeout=900, env=env)


def regen(wt, rel):
    """
    Regenerate ONE module's .zig via the bootstrap — the cheap half of a rebuild.

    REDIRECTS TO A FILE, NEVER A PIPE. The bootstrap writes ~1.4 MB of emitted Zig to
    stdout, and on Windows a large stdout into a PIPE can come back EMPTY with rc=0.
    The first version captured through a pipe and read that emptiness as "the bootstrap
    refused this mutant", reporting DETECTED(regen) for 241 of 300 mutants — a
    fabricated result: running those same mutants by hand shows the bootstrap emitting
    them perfectly well.

    The repo's own memory records this hazard ("Windows stdout-to-PIPE writes nothing;
    redirect/file fine") and I walked into it anyway, because the failure mode looks
    exactly like a detection. A harness that cannot distinguish "the compiler rejected
    this" from "I failed to read the output" will confidently report a wrong number —
    and 80% of a headline result came from that confusion.

    The bootstrap has no --output-dir, so a file redirect is the only option.
    """
    boot = wt / "zig-out" / "bin" / "zebra-bootstrap.exe"
    tmp = wt / "_mut_emit.zig"
    try:
        with open(tmp, "wb") as fh:
            pr = subprocess.run([str(boot), "--emit-zig", rel], cwd=str(wt),
                                stdout=fh, stderr=subprocess.PIPE, timeout=300)
    except subprocess.TimeoutExpired:
        return False, "regen TIMEOUT"
    if pr.returncode != 0:
        return False, pr.stderr.decode("utf-8", "replace")[-1500:]
    out = tmp.read_text(encoding="utf-8", errors="replace")
    marker = "// Generated by the Zebra compiler."
    if marker not in out:
        return False, "bootstrap emitted no source (rc=0)"
    (wt / rel.replace(".zbr", ".zig")).write_text(
        out[out.index(marker):], encoding="utf-8", newline="\n")
    return True, ""


# Programs whose EMITTED Zig is fingerprinted before and after each mutation. Chosen to
# span the common paths rather than to be clever: a struct/branch/except program, a
# string+interpolation program, and a collections program.
CANARIES = ["test/boundary/bv_nil_positions.zbr",
            "test/boundary/bv_empty_string.zbr",
            "test/boundary/bv_empty_list.zbr"]


def emit_fingerprint(wt):
    """
    Hash what the compiler EMITS for the canaries.

    This is what separates the two very different things a bare "SURVIVED" conflates:

      * the mutant emits IDENTICAL code  -> the mutation is unreachable from anything we
        compile. Nothing to catch. Reporting that as a gate hole would be a lie, and
        with 3,559 mutable sites in CodeGen — much of it GUI backends, node-addon and
        rarely-used stdlib methods — this is expected to be the common case.
      * the mutant emits DIFFERENT code and every gate still passes -> a REAL hole: we
        compile differently and nothing notices.

    Only the second is a finding. Without this split the headline number is dominated by
    dead code and means nothing.
    """
    import hashlib
    h = hashlib.sha1()
    zebra = wt / "zig-out" / "bin" / "zebra.exe"
    for c in CANARIES:
        rc, out = run([str(zebra), "--emit-zig", c], wt, timeout=180)
        marker = "// Generated by the Zebra compiler."
        h.update((out[out.index(marker):] if marker in out else f"<FAIL {rc}>").encode())
    return h.hexdigest()


def detectors(wt):
    """
    Cheapest-first cascade. Stops at the first detection, so the common case (a mutant
    that breaks everything) costs almost nothing and only SURVIVORS pay for the
    expensive checks — which is the right way round, since survivors are the product.
    """
    zebra = wt / "zig-out" / "bin" / "zebra.exe"
    hello = wt / "_mut_hello.zbr"
    hello.write_text('def main()\n    print("hi ${1 + 1}")\n', encoding="utf-8", newline="\n")

    def d_hello():
        rc, out = run([str(zebra), str(hello)], wt, timeout=180)
        return ("hi 2" in out), "hello-world"

    def d_boundary():
        rc, _ = run([BASH, "tools/boundary_check.sh"], wt, timeout=900)
        return rc == 0, "boundary"

    def d_smoke():
        rc, out = run([BASH, "tools/selfhost_smoke.sh"], wt, timeout=1800)
        return ("passed" in out and rc == 0), "smoke"

    return [d_hello, d_boundary, d_smoke]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=10)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--module", default=None,
                    help="substring filter on the target file (e.g. TypeChecker)")
    args = ap.parse_args()

    sites = []
    for rel in TARGETS:
        if args.module and args.module.lower() not in rel.lower():
            continue
        for st in candidate_sites(REPO / rel):
            sites.append((rel,) + st)
    print(f"mutable sites: {len(sites)} across {len(TARGETS)} modules")
    if args.list:
        from collections import Counter
        for rel in TARGETS:
            c = Counter(s[4] for s in sites if s[0] == rel)
            print(f"  {rel}: {sum(c.values())}  {dict(c)}")
        return 0

    random.Random(args.seed).shuffle(sites)
    sites = sites[: args.limit]

    ensure_worktree()
    wt = WORKTREE
    print(f"worktree: {wt}")

    print("baseline build...", flush=True)
    ok, log = build(wt)
    if ok != 0:
        sys.exit("baseline build FAILED — a mutation run on a red baseline is meaningless:\n"
                 + log[-2000:])
    for d in detectors(wt):
        good, name = d()
        if not good:
            sys.exit(f"baseline detector '{name}' is RED. Every 'detected' result would be "
                     f"a lie about the mutant. Fix the tree first.")
    base_fp = emit_fingerprint(wt)
    print(f"baseline green.  emit-fingerprint {base_fp[:12]}\n", flush=True)

    results, t_start = [], time.time()
    for n, (rel, ln, c0, c1, op, old, new) in enumerate(sites, 1):
        src = wt / rel
        original = src.read_text(encoding="utf-8")
        lines = original.splitlines(keepends=True)
        line = lines[ln]
        lines[ln] = line[:c0] + new + line[c1:]
        src.write_text("".join(lines), encoding="utf-8", newline="\n")

        t0 = time.time()
        verdict, by, why = "SURVIVED", "-", ""
        ok, msg = regen(wt, rel)
        if not ok:
            verdict, by, why = "DETECTED", "regen", msg[:300]      # the bootstrap refused it
        else:
            rc, blog = build(wt)
            if rc != 0:
                verdict, by = "DETECTED", "build"  # zig refused the emitted compiler
            else:
                cheap, expensive = detectors(wt)[:2], detectors(wt)[2:]
                for d in cheap:
                    good, name = d()
                    if not good:
                        verdict, by = "DETECTED", name
                        break
                if verdict == "SURVIVED":
                    # FINGERPRINT BEFORE THE EXPENSIVE DETECTOR. NO-EFFECT is the common
                    # case (5/5 in the first sample) and was paying ~200s for smoke to
                    # learn nothing. Checking emit first takes those from ~275s to ~40s.
                    #
                    # LIMIT, stated because it is a real one: the fingerprint covers the
                    # CANARIES, while smoke compiles 263 fixtures. A mutation that leaves
                    # every canary byte-identical, passes boundary, and changes only some
                    # other fixture will be filed NO-EFFECT when it was arguably live.
                    # Widening CANARIES narrows that gap; it does not close it.
                    if emit_fingerprint(wt) == base_fp:
                        verdict, by = "NO-EFFECT", "identical-emit"
                    else:
                        for d in expensive:
                            good, name = d()
                            if not good:
                                verdict, by = "DETECTED", name
                                break

        # The explicit newline is LOAD-BEARING ON THE RESTORE, not only on the apply.
        # Without it Python rewrites the file with CRLF on Windows, and the Zebra
        # tokenizer treats a lone CR as an unexpected character - "internal compiler
        # error: error.UnexpectedCharacter". The apply site above had it; this one did
        # not. CLAUDE.md documents this exact trap in a section of its own, which did
        # not stop me walking into it.
        src.write_text(original, encoding="utf-8", newline="\n")
        results.append(dict(file=rel, line=ln + 1, op=op, old=old, new=new,
                            verdict=verdict, by=by, why=why,
                            secs=round(time.time() - t0, 1)))
        print(f"  [{n}/{len(sites)}] {verdict:9s} by {by:9s} "
              f"{pathlib.Path(rel).name}:{ln+1} {op} {old!r}->{new!r} "
              f"({results[-1]['secs']}s)", flush=True)

    # restore the worktree to pristine, whatever happened above
    run(["git", "checkout", "--", "."], wt)

    det = sum(1 for r in results if r["verdict"] == "DETECTED")
    noeff = sum(1 for r in results if r["verdict"] == "NO-EFFECT")
    sur = [r for r in results if r["verdict"] == "SURVIVED"]
    live = det + len(sur)
    print(f"\n{'='*70}\nmutants: {len(results)}   detected: {det}   "
          f"survived: {len(sur)}   no-effect: {noeff}")
    if live:
        print(f"gates caught {100*det/live:.0f}% of mutations that CHANGED EMITTED CODE "
              f"({det}/{live}); {noeff} more changed nothing we compile.")
    print(f"({round(time.time()-t_start)}s total)")
    print("\nSURVIVORS — each is a place the compiler can change with NO gate noticing.")
    print("This list, not the percentage, is the product:")
    for r in sur:
        print(f"  {r['file']}:{r['line']}  {r['op']}  {r['old']!r} -> {r['new']!r}")
    if not sur:
        print("  (none in this sample)")

    out = REPO / "tools" / "mutation_report.json"
    out.write_text(json.dumps(results, indent=1), encoding="utf-8", newline="\n")
    print(f"\nreport: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
