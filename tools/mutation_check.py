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
import argparse
import atexit, json, os, pathlib, random, re, shutil, subprocess, sys, time

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
    marker = "// Generated by the Zebra compiler."  # hazard-ok:H4 this path runs the BOOTSTRAP, whose header this is; distinguishing it from the selfhost's is the point
    if marker not in out:
        return False, "bootstrap emitted no source (rc=0)"
    (wt / rel.replace(".zbr", ".zig")).write_text(
        out[out.index(marker):], encoding="utf-8", newline="\n")
    return True, ""


# Programs whose EMITTED Zig is fingerprinted before and after each mutation. Chosen to
# span the common paths rather than to be clever: a struct/branch/except program, a
# string+interpolation program, and a collections program.
#
# WIDENED 2026-08-01. Three small probes were far too narrow: across three runs, EVERY
# mutant that reached the fingerprint hashed identical and was filed NO-EFFECT, so the
# SURVIVED verdict -- the one this tool exists to produce -- never executed once. Three
# hand-written probes simply do not exercise enough of a 16,000-line code generator.
#
# selfhost/CodeGen.zbr is the largest and most demanding Zebra program in the repo, and
# emitting it with the MUTATED compiler costs ~20s -- against the ~6s the three probes
# cost, and against the ~200s of smoke that a false NO-EFFECT was skipping. The small
# probes stay because they are cheap and they localise a difference when one appears.
CANARIES = ["test/boundary/bv_nil_positions.zbr",
            "test/boundary/bv_empty_string.zbr",
            "test/boundary/bv_empty_list.zbr",
            "selfhost/CodeGen.zbr"]


def _restore_once(src, original):
    """Idempotent restore, safe to call from both the loop and atexit.

    Idempotence comes from comparing content rather than from a flag: if the file already
    matches, there is nothing to do. The explicit newline is load-bearing here for the
    same reason it is at every other write site in this file -- see the note in the loop.
    """
    try:
        if src.read_text(encoding="utf-8") == original:
            return
    except OSError:
        pass
    src.write_text(original, encoding="utf-8", newline="\n")


def emit_fingerprint(wt, files=None):
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
    for c in (files or CANARIES):
        rc, out = run([str(zebra), "--emit-zig", c], wt, timeout=180)
        # MATCH BOTH COMPILERS' HEADERS. The bootstrap writes "// Generated by the Zebra
        # compiler."; the selfhost writes "// Generated by zebra-selfhost." (and two
        # variants for node-addon / single-file). This function runs the SELFHOST, and
        # for one full run it searched for the BOOTSTRAP's string only -- see the note
        # in the failure log below.
        i = out.find("// Generated by")
        if i < 0:
            # DO NOT substitute a sentinel here. The original code hashed f"<FAIL {rc}>"
            # when the marker was missing, which made the fingerprint a CONSTANT: every
            # mutant compared equal to the baseline and was filed NO-EFFECT, and the run
            # reported "0 survivors" while never once looking at emitted code. A
            # fingerprint that cannot see must say so, not return a value.
            return None
        h.update(out[i:].encode())
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
    ap.add_argument("--site", default=None,
                    help="re-run ONE mutation, as FILE:LINE (e.g. "
                         "selfhost/CodeGen.zbr:9714). The point of this is to close the "
                         "loop on a survivor: add a test, then prove it KILLS the mutant "
                         "rather than assuming it would.")
    args = ap.parse_args()

    # THE WORKTREE MUST EXIST BEFORE SITES ARE CHOSEN.
    #
    # This block used to read candidate_sites(REPO / rel) -- the MAIN checkout -- and then
    # apply the resulting (line, col_start, col_end) to the WORKTREE copy. Those are two
    # different files. The worktree sits at whatever commit it was created from; the main
    # checkout carries uncommitted work, and this repo regularly has a parallel session
    # editing selfhost/*.zbr.
    #
    # Observed 2026-08-01: CodeGen.zbr was 16,539 lines here and 16,521 there. Line 14831
    # was `if args.len > 0` in one and `else` in the other, so a mutation described as
    # "cmp '>' -> '>='" was applied at those columns to a completely unrelated line --
    # corrupting the source. The bootstrap then refused it, and the harness scored that as
    # "the bootstrap refused this mutant". 18 of the first 43 mutants were fabricated that
    # way, and hand-checking three of them at the worktree's own commit found all three
    # emit cleanly.
    #
    # This is the SECOND time this harness has manufactured "regen refusals" by corrupting
    # the source it was supposed to be mutating (the first was a CRLF restore). Both times
    # the fabricated verdict was the reassuring-looking one.
    ensure_worktree()
    wt = WORKTREE

    sites = []
    for rel in TARGETS:
        if args.module and args.module.lower() not in rel.lower():
            continue
        for st in candidate_sites(wt / rel):
            sites.append((rel,) + st)
    print(f"mutable sites: {len(sites)} across {len(TARGETS)} modules (read from {wt})")
    if args.list:
        from collections import Counter
        for rel in TARGETS:
            c = Counter(s[4] for s in sites if s[0] == rel)
            print(f"  {rel}: {sum(c.values())}  {dict(c)}")
        return 0

    if args.site:
        want_file, _, want_line = args.site.rpartition(":")
        want_line = int(want_line)
        want_file = want_file.replace("\\", "/")
        sites = [st for st in sites
                 if st[0].replace("\\", "/").endswith(want_file.split("/")[-1])
                 and st[1] + 1 == want_line]
        if not sites:
            # DON'T just say no. Line numbers drift -- that is the normal case, not an
            # error, since a survivor is recorded against whatever the worktree looked
            # like on the day it ran. Show the neighbourhood so the caller can re-aim in
            # one step instead of hand-diffing two trees.
            src = (wt / want_file).read_text(encoding="utf-8").splitlines() \
                if (wt / want_file).exists() else []
            near = {}
            for st in candidate_sites(wt / want_file) if src else []:
                near.setdefault(st[0] + 1, []).append(f"{st[3]} {st[4]!r}->{st[5]!r}")
            lo, hi = max(1, want_line - 6), min(len(src), want_line + 6)
            print(f"--site {args.site}: no mutable site on that line of the WORKTREE copy "
                  f"({wt}).", file=sys.stderr)
            print(f"Line numbers belong to a TREE, and this one has moved since the "
                  f"survivor was recorded. Nearby lines:\n", file=sys.stderr)
            for i in range(lo, hi + 1):
                mark = "  <-- you asked for this" if i == want_line else ""
                muts = ("   [" + "; ".join(near[i]) + "]") if i in near else ""
                # ASCII-fold the source line. These are Zebra sources with box-drawing
                # characters in their section banners, and this console is cp1252: a
                # UnicodeEncodeError here would crash the tool at the exact moment it is
                # trying to help someone recover from a miss. (A stray checkmark in a
                # print killed a 68-minute run earlier the same day.)
                safe = src[i-1].rstrip()[:64].encode("ascii", "replace").decode("ascii")
                print(f"  {i:>6}  {safe:<64}{muts}{mark}", file=sys.stderr)
            print(f"\nRe-run --site with a line above that carries a [mutation].",
                  file=sys.stderr)
            sys.exit(2)
        print(f"--site: {len(sites)} mutation(s) on {args.site}")
    else:
        random.Random(args.seed).shuffle(sites)
        sites = sites[: args.limit]
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
    if base_fp is None:
        sys.exit("baseline emit-fingerprint is BLIND (no '// Generated by' marker). "
                 "Every mutant would be filed NO-EFFECT and the run would report "
                 "'0 survivors' without looking at anything.")
    # POSITIVE CONTROL: the fingerprint must DISTINGUISH two different programs. A
    # fingerprint that returns the same value for everything passes the check above and
    # still classifies every mutant NO-EFFECT. This is the check that would have caught
    # the 2026-08-01 run on its first mutant instead of after 68 minutes.
    ctl_src = wt / "_mut_fpctl.zbr"
    ctl_src.write_text('def main()\n    print("fingerprint control")\n',
                       encoding="utf-8", newline="\n")
    ctl_fp = emit_fingerprint(wt, ["_mut_fpctl.zbr"])
    if ctl_fp is None or ctl_fp == base_fp:
        sys.exit(f"emit-fingerprint CONTROL FAILED: a different program hashed to "
                 f"{ctl_fp}, the canaries to {base_fp}. The fingerprint is not "
                 f"distinguishing anything, so NO-EFFECT would be meaningless.")
    print(f"baseline green.  emit-fingerprint {base_fp[:12]} "
          f"(control {ctl_fp[:12]}, distinct - fingerprint is live)\n", flush=True)

    results, t_start = [], time.time()
    for n, (rel, ln, c0, c1, op, old, new) in enumerate(sites, 1):
        src = wt / rel
        original = src.read_text(encoding="utf-8")
        # RESTORE ON THE WAY OUT, WHATEVER HAPPENS. Observed 2026-08-01: a run stopped
        # mid-mutant (deliberately, once its results were shown to be fabricated) left the
        # mutation in selfhost/TypeChecker.zbr plus .zig files regenerated from a mutated
        # compiler. The next run's baseline detector correctly went red and it refused to
        # start -- the control worked -- but a harness that poisons its own worktree when
        # interrupted is a trap for whoever runs it next, and an interrupted run is the
        # normal case, not the exception.
        atexit.register(_restore_once, src, original)
        lines = original.splitlines(keepends=True)
        line = lines[ln]
        # PER-MUTANT POSITIVE CONTROL. Cheap, and it is the check that would have caught
        # the repo-vs-worktree coordinate drift on the FIRST mutant instead of after 43.
        # If the text at (line, col) is not what the site said it was, we are about to
        # corrupt the file and score the resulting refusal as a result.
        if line[c0:c1] != old:
            sys.exit(f"SITE CONTROL FAILED at {rel}:{ln+1} cols {c0}:{c1} -- expected "
                     f"{old!r}, found {line[c0:c1]!r}. The mutation coordinates do not "
                     f"match the file being mutated; every verdict from here would be a "
                     f"lie about a corrupted source.")
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
                    fp = emit_fingerprint(wt)
                    if fp is None:
                        # The mutant compiler produced no emit at all for a canary. That
                        # is a detection, not an absence of one.
                        verdict, by = "DETECTED", "emit-blank"
                    elif fp == base_fp:
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
        _restore_once(src, original)
        atexit.unregister(_restore_once)
        results.append(dict(file=rel, line=ln + 1, op=op, old=old, new=new,
                            verdict=verdict, by=by, why=why,
                            secs=round(time.time() - t0, 1)))
        print(f"  [{n}/{len(sites)}] {verdict:9s} by {by:9s} "
              f"{pathlib.Path(rel).name}:{ln+1} {op} {old!r}->{new!r} "
              f"({results[-1]['secs']}s)", flush=True)

    # restore the worktree to pristine, whatever happened above
    run(["git", "checkout", "--", "."], wt)  # hazard-ok:H5 `wt` is the throwaway mutant worktree, never the working tree

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

    # ONE FILE PER RUN. This was a single mutable `mutation_report.json`, so each run
    # DESTROYED the previous run's evidence. Two runs were aggregated on 2026-08-01
    # ("25 mutants, 21 live, 12 survivors") and by then only the second report existed on
    # disk -- the first survived solely in a scrollback buffer. Whether any site had been
    # double-counted could not be answered from anything durable.
    #
    # It turned out clean (zero overlap between the two site sets), which is luck, not
    # method: both runs shuffle the SAME ~4,300-site pool independently and nothing
    # dedups across runs. Aggregating runs is the normal way to use this tool, so the
    # evidence for an aggregate has to outlive the run that produced it.
    tag = args.site.replace("/", "_").replace(":", "-") if args.site \
        else f"seed{args.seed}_n{args.limit}"
    out = REPO / "tools" / f"mutation_report_{tag}.json"
    out.write_text(json.dumps(results, indent=1), encoding="utf-8", newline="\n")
    print(f"\nreport: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
