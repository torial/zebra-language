#!/usr/bin/env python3
"""Find OPEN bugs that look already-fixed.

Why this and not the existing gate: lint_bug_numbers' third leg is HEADING-ONLY by design
(bodies routinely say FIXED about other bugs, which scored 30 of 53 and got the check
ignored). So an entry whose heading never gained a FIXED marker is invisible to it -- and
that is exactly how BUG-283 and BUG-270 each sat stale for days and were rediscovered by
someone picking them up to work on.

This looks at EVIDENCE OUTSIDE the ledger instead: commits that claim to have landed the
number, and regression fixtures that exist and pass. Neither is proof, so this ranks
suspicion and names the evidence; it does not close anything.
"""
import re
import subprocess
import sys
import pathlib

REPO = pathlib.Path(r"C:\Projects\zebra-language")


def git(*args):
    r = subprocess.run(["git"] + list(args), cwd=str(REPO), capture_output=True,
                       text=True, errors="replace")
    return r.stdout


bugs_md = (REPO / "BUGS.md").read_text(encoding="utf-8", errors="replace")
open_nums = re.findall(r'^#+\s*BUG-(\d+)', bugs_md, re.M)
open_nums = sorted(set(int(n) for n in open_nums))
if len(open_nums) < 20:
    sys.exit("REFUSING: parsed only %d open bugs; the heading regex has stopped matching"
             % len(open_nums))

# positive control: a number known to be FIXED must show landing commits
control = git("log", "--oneline", "--all", "--grep", "BUG-288")
if "BUG-288" not in control:
    sys.exit("REFUSING: control failed — git log finds no BUG-288 commits, so a clean "
             "result here would mean nothing")

tracked = set(git("ls-files").split())

# boundary control: the exact matcher must reject a longer number that merely starts the same
_probe = re.compile(r'BUG-0*14(?!\d)')
if _probe.search("abc BUG-142 def") or not _probe.search("abc BUG-14 def"):
    sys.exit("REFUSING: boundary matcher is broken (BUG-14 vs BUG-142)")

print("open bugs parsed: %d   (controls: BUG-288 commits found; BUG-14 does not match BUG-142)"
      % len(open_nums))
print()

FIXWORDS = re.compile(r'\b(fix|fixed|fixes|closed?|land(ed)?|resolve[sd]?)\b', re.I)

rows = []
for n in open_nums:
    tag = "BUG-%d" % n
    log = git("log", "--oneline", "--all", "--grep", tag)
    # BUG-14 must not match BUG-142. `git --grep` is a substring match, so the boundary has
    # to be enforced here -- without it BUG-14 collected 24 "fixes" that belonged to
    # BUG-140..149, which is a wrong ANSWER rather than an error, the failure mode this
    # repo has the most receipts for.
    exact = re.compile(r'BUG-0*%d(?!\d)' % n)
    lines = [l for l in log.splitlines() if l.strip() and exact.search(l)]
    # commits whose SUBJECT claims a fix for this bug
    fixish = [l for l in lines if FIXWORDS.search(l.split(" ", 1)[-1] if " " in l else "")]
    # regression fixtures
    fixtures = sorted(f for f in tracked
                      if re.search(r'test/bug0*%d[_.]' % n, f))
    score = 0
    why = []
    if fixish:
        score += 2
        why.append("%d commit(s) claim a fix" % len(fixish))
    if fixtures:
        score += 1
        why.append("%d fixture(s)" % len(fixtures))
    if score:
        rows.append((score, n, why, fixish[:2], fixtures[:2]))

rows.sort(key=lambda r: (-r[0], r[1]))
print("OPEN entries with outside evidence of being done (ranked; NOT proof):")
print()
for score, n, why, fixish, fixtures in rows:
    print("  BUG-%-4d  score %d  — %s" % (n, score, "; ".join(why)))
    for f in fixish:
        print("      commit: %s" % f[:96])
    for f in fixtures:
        print("      fixture: %s" % f)
print()
print("%d of %d open entries carry some outside evidence." % (len(rows), len(open_nums)))
print("A fixture existing is NOT a fix: registration_check exists because fifteen fixtures")
print("were found that nothing ever ran. Verify by RUNNING the case before closing.")
