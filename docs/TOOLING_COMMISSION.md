# Tooling commission — making this environment trustworthy to work in

*Started 2026-08-01, at Sean's standing invitation to "rework all the tools /
documentation / strategies we're using for Zebra to make it as reliable and useful
going forward". This is the README for that work: what changed, why, the decisions
worth knowing about, and what is still open.*

Companion reading: [`testing_strategy.md`](testing_strategy.md) §3b *Instrument
discipline* is the argument; this file is the inventory.

---

## 1. Why this, and why now

The commission was proposed after a week of QA work that produced, alongside the real
results, **six bugs in a single measurement harness in two days** — the sixth found while
this file was being written:

| # | bug | what it reported |
|---|---|---|
| 1 | worktree could not build (`../earley` sibling dep) | a clean run |
| 2 | `bash` resolved to WSL, breaking the boundary detector | detections |
| 3 | restore wrote CRLF, corrupting the source after mutant 1 | 241 "regen refusals" |
| 4 | NO-EFFECT described as "unreachable"; it covered 3 canaries | 78% unreachable |
| 5 | fingerprint matched the wrong compiler's header, then hashed a sentinel | 0 survivors |
| 6 | mutation sites read from `REPO/rel`, applied to `wt/rel` | 18 of 43 "regen refusals" |

**None of them crashed, warned, timed out, or exited non-zero.** Every one produced a
confident, plausible, wrong number, and two were published before being caught.

That is the shape of the problem this commission addresses. It is not missing coverage —
this repo has twelve QUICK gates and four heavy witnesses. It is **coverage that reports
itself as present**. A red gate gets investigated; a green one does not.

So the organising rule for everything below is:

> **Prose is not a control.** CLAUDE.md documents the CRLF trap in a section of its own,
> and that did not stop the author who had read it that week from writing it. A hazard
> with a receipt should stop being a paragraph and start being a check that fails.

A second rule follows from it, and is the one to apply to any new tool here:

> **A hazard with no receipt does not get a check.** Speculative rules train people to
> suppress the tool, and a suppressed tool is worse than no tool, because it still looks
> like coverage.

---

## 2. What was built

### `tools/hazard_lint.py` — a gate pointed at our own tooling

Every other lint in `tools/` reads Zebra code. This one reads the scripts we measure
Zebra *with*. Each check cites the incident that earned it:

| code | hazard | receipt |
|---|---|---|
| H1 | a `.zbr` text-write without `newline="\n"` | bug 3 — 241 fabricated detections |
| H2 | bare `bash` (resolves to WSL here) or a `wsl`-prefixed command | bug 2 |
| H3 | a constant sentinel on a path that feeds a comparison | bug 5 — the "0 survivors" headline |
| H4 | a compiler-**specific** emit header — two compilers, two headers | bug 5's root cause |
| H5 | `git checkout -- .` | the standing sweep-WIP hazard |
| H6 | the same relative path resolved against **two different roots** | bug 6 — 18 fabricated refusals |
| H9 | a `# hazard-ok` with **no reason** | an unexplained suppression is how a gate goes quiet |

H3 is the one worth internalising beyond this repo. A silent constant fallback on a
comparison path always biases toward *"nothing changed"* — the answer that ends the
investigation. A function that cannot compute its answer must return `None` or raise, and
the caller must treat that as the **interesting** verdict.

**It carries the discipline it enforces.** Positive controls run before every scan, and it
exits **2 — not 0** — if any check stops firing on its own control.

**Self-tests are circular**, so `--rev <sha>` supplies the non-circular control: lint a
past revision and see what the tool *would have said* on the day the bug shipped. On
`7156d3e` it reports H1 at :301, H3 at :185, H4 at :184 — three of the then-five real
bugs, statically, in milliseconds, on the commit that published them. H6 was added hours
later and passes the same test: on `0d5494d` it reports *"`rel` is resolved against 2
different roots — REPO (line 251), wt (line 283)"*, which is bug 6 exactly.

### `tools/doc_lint.py` — the docs' checkable claims

Most doc assertions ("this gate is blind to X") need a human or an experiment. The
machine-checkable minority is what rots fastest, because it is exactly what changes when a
tool is renamed, split, or retired.

D1 a `tools/x.sh` named in a `.md` exists · D2 a repo path linked from a `.md` exists ·
D3 **every gate registered in `gates.sh` is described in CLAUDE.md** · D4 a cited
`BUG-NNN` exists in one of the two ledgers.

D3 found three on its first run — `bug-fixture`, `check-mode` and `oom-unreachable` had
been running in the QUICK tier undocumented. Documenting them was the fix: an undocumented
gate is how a tier's meaning drifts.

It prints its own **uncovered set** on every run, so a clean result cannot be misread as
"the docs are accurate".

### `tools/kill_orphans.sh` — stop killing other people's compilers

`rebuild.sh` and `doctor.sh --fix` ran `taskkill //F //IM zebra.exe` — **machine-wide**.
On 2026-08-01 that killed a mutation run's bootstrap in a sibling worktree, mid-mutant,
fired from a `rebuild.sh` in the main checkout. `doctor.sh --fix` was worse: its list
includes `zig.exe`, so it would take out the shared zvm toolchain other work is using.

The victim never sees *"someone killed me."* It sees a regeneration that failed for no
visible reason — and a harness scores that as a **result**. This repo regularly has two
agents working in it at once, plus isolated worktrees whose entire purpose is not to be
affected from outside.

The lock being cleared (`AccessDenied` on `zig-out/bin`) is only ever held by a process
running from *this* tree, so filtering on `ExecutablePath` loses nothing. The tool
**prints what it leaves alone**, because the silence is what made the old behaviour look
like an unrelated failure.

### `rebuild.sh --module NAME` — the ~10 s inner loop

Extraction, not construction: `mutation_check.py`'s `regen()` had already run this path
thousands of times. Two of its details carried over deliberately — redirect to a **file**,
never a pipe, and **verify the emit header is present** rather than trusting `rc=0`.

Sound because the regeneration is done by the **bootstrap**, whose output for other modules
a selfhost `.zbr` edit cannot change. Verified by regenerating an untouched module and
getting a byte-identical file.

It **refuses** if a `selfhost/*.zbr` is modified and not named (`--force` overrides).
Regenerating a subset leaves the tree half-updated and every downstream gate then measures
a compiler that is partly old. That, not speed, is the footgun.

### `gate_selfcheck.sh` — three new legs

The new gates are not taken on trust:

* hazard-lint fires on a planted `.zbr` CRLF write (clean 0 → planted 1);
* hazard-lint **REFUSES (rc=2) when a check is blinded** — the refusal path is the entire
  reason to trust a clean report from it, and it had never been exercised;
* doc-lint catches a planted dangling tool reference.

---

## 3. Decisions a maintainer should know about

**False positives were designed out, not tuned away.** Two classes in `doc_lint` would
each have trained people to ignore the tool:

* **Append-only records** (`BUGS.md`, `BUGS_FIXED.md`, the journal, `CHANGELOG.md`, dated
  audits) are reported but **not gated**. A March bug entry citing a tool deleted in June
  is accurate history; "fixing" it would falsify the record.
* **Placeholders** (`selfhost/foo.zbr`, `tools/x.sh`) are skipped, as are repo-shaped
  paths inside code fences — there, QUICKSTART is illustrating a *user's* project layout,
  not claiming something about this tree. D1 still checks inside fences, because a fenced
  block is usually a command meant to be run.

**Suppressions require a reason.** `# hazard-ok:<code> <reason>` and
`<!-- doc-lint-ok: <reason> -->`. A bare marker is itself reported (H9). This is not
pedantry: an unexplained suppression is indistinguishable from a check that was silently
switched off.

**Scope claims are written from the code, not the intent.** Bug 4 was a caption
("unreachable from anything the corpus compiles") describing three files. Where a tool's
reach is narrower than the sentence, the sentence loses.

**Prose counts are known-unfixable by these tools and are corrected by hand.** `gates.sh`
claimed "seven gates" against twelve registered, and "Twelve probes" against twenty. A
bare number has no referent to resolve, so `doc_lint` lists this in its uncovered set;
the header now names the oracle (`grep -c '^run "' tools/gates.sh`) beside the number.

This document did it too, within an hour of saying so: it opened with "five bugs" above a
six-row table and "six checks" above seven. The practical lesson is not to try harder —
it is to **avoid writing the count at all** where the list is right there, which is why the
hazard table no longer announces its own length.

---

## 4. Isolation tactics used

* **Positive controls as an isolation boundary.** Each checker's controls are embedded
  known-bad snippets scanned in memory, not files on disk — so the control cannot be
  broken by a change to the corpus, and running the checker never mutates the tree.
* **`--rev` reads history through `git show`**, never checking anything out, so the
  historical control cannot disturb a working tree that a parallel session is using.
* **Path-scoped process control** (`kill_orphans.sh`) replaces a global side effect with
  one bounded by the repo root — the boundary is the tree, and it is stated in one place
  rather than assumed at each call site.
* **The mutation harness runs in a sibling git worktree**, which must be a sibling
  because `build.zig` has a path dependency on `../earley`.

When would these change? The controls become a liability if a check's *shape* changes
without its control being updated — that is what `gate_selfcheck`'s blinding leg exists to
notice. `kill_orphans.sh` would need revisiting if the build ever legitimately spawns
compilers outside the repo root.

---

## 5. Concerns, honestly

* **The QUICK tier has not been run end-to-end since `hazard-lint` and `doc-lint` were
  registered.** Both gates pass individually and `gates.sh --list` parses, but the tier
  composition is unverified: `doctor.sh` refuses to preflight because a parallel session
  has `selfhost/CodeGen.zbr` mid-edit, and `gates.sh` correctly declines to report on an
  untrustworthy tree. This needs one clean run when the tree settles.
* **`hazard_lint` is pattern-based and will miss the next hazard class** until that class
  has produced a receipt. That is deliberate, but it means a green run says "none of the
  five known hazards", not "no hazards".
* **`doc_lint`'s reach is small on purpose.** It cannot check the claims most likely to
  mislead — the behavioural ones. Its uncovered list is printed every run specifically so
  this cannot be quietly forgotten.
* **B1's survivor path still has never executed.** Across three mutation runs, no mutant
  has ever reached `smoke`. With a *working* fingerprint, three canaries still absorb
  every non-detected mutant into NO-EFFECT — so widening the fingerprint is **required**,
  not optional. Recorded in NEXT_STEPS as B1 v2.
* **This harness has now been fixed three times and has never produced a valid full run.**
  That is worth sitting with rather than explaining away. Every fix was correct and every
  one revealed the next layer, which is what a tool measuring something genuinely hard
  looks like — but it also means B1's headline is not "0 survivors", it is *"the verdict
  this tool exists to produce has never been reached."* The gates are not what has been
  measured so far; the harness is.

---

## 6. Still open

* One clean `gates.sh` QUICK run once the tree settles.
* B1 v2: sample until *N live* mutants rather than N total; bias site selection toward
  code the corpus executes; widen the emit fingerprint (regenerating `selfhost/*.zig` with
  the mutated compiler would fingerprint the largest Zebra program we have).
* An "existing idioms — grep here first" index. Three receipts so far, all of the same
  kind: re-implementing something the codebase already had (`parenDepth` in the lexer, the
  labeled-block emit idiom, `boxed_variants`).
* Documentation **consolidation** rather than addition — 33 files in `docs/` and ~14k
  lines across five root docs is the surface area that let one wrong claim live in four
  documents at once.
