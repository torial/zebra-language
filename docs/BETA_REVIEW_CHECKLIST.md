<!-- doc-status: live -->
# 0.9-beta review checklist — what a human has to confirm

**Status:** live. Written 2026-08-05 for the formal beta review pass.
**Audience:** Sean, doing the review. Secondary: any instance asked to close items on it.

---

## What this list is, and why it is not a wish list

Every item here exists because **something in this repo cannot see it**. The list was
derived, not brainstormed:

- `bash tools/gates.sh --list` prints its own honest limits — the GUI section comes from there.
- Each gate's header in `CLAUDE.md` states what it is blind to; those became items.
- The CLI surface came from `zebra --help`, cross-referenced against every `tools/*.sh`,
  `tools/*.py` and `fuzz/*.py` to find which subcommands **no gate ever invokes**.
- The stdlib section came from every capitalised name in `src/Builtins.zig` checked against
  the whole corpus for any mention at all (with a positive control, so a broken search
  could not report a comfortable zero).

Where a count appears, the command that produced it is given, so you can re-derive rather
than trust me.

**How to use it.** Items are `[ ]` unchecked. Each says what to do, what *pass* looks
like, and **why automation cannot do it** — that last part matters, because if you find
an item that *could* be automated, the right outcome is a new gate, not a tick.

**Tick honestly.** A half-checked item is worse than an unchecked one: it converts "nobody
looked" into "someone looked and it was fine", which is the exact failure this repo spends
most of its instrument budget preventing.

---

## A. GUI — the largest uncovered surface

**Why this section exists.** No gate clicks anything. Four GUI crashes have shipped under
fully green boards. `tools/gui_scaffold_check.sh` now covers *startup* (BUG-229), because a
startup crash needs neither a human nor a terminal. **Rendering, input, layout, resize and
colour are covered by nothing but you.**

Backends: `stub`, `glfw`, `tui` (per `zebra --help`). `--gui-backend=*` **delegates to
`zebra-bootstrap`**, so every item here exercises the *bootstrap's* codegen, not the
selfhost's — a path most of the FULL tier never touches.

### A1. Per-backend smoke — `examples/counter.zbr`

- [ ] `--gui-backend=tui` — renders, increments, decrements, quits cleanly
- [ ] `--gui-backend=glfw` — same
- [ ] `--gui-backend=stub` — builds and exits without a window (the CI-shaped path)
- [ ] libui-ng backend — same, via its own build path
- [ ] The count **displayed** matches the count in the model after 10+ clicks
      *(no gate reads a rendered number)*

### A2. Widget coverage — the `*_smoke.zbr` examples

Each of these exists to exercise a widget family and **is only ever proven by running it**:

- [ ] `examples/widget_smoke.zbr` — every widget draws; **note: this shipped broken on
      BUG-230 and `zebra -c` exits 0 on it**, so a spot-check cannot clear it
- [ ] `examples/panel_smoke.zbr` — panels nest and clip correctly
- [ ] `examples/hbox_smoke.zbr` — horizontal layout, spacing, alignment
- [ ] `examples/file_dialog_smoke.zbr` — dialog opens, cancel returns cleanly, chosen path
      is correct **including a path with spaces and a non-ASCII path**
- [ ] `examples/editor_min.zbr` — text entry, cursor, selection, backspace at position 0
- [ ] `examples/tears_of_the_tuon.zbr` — the largest real GUI program we have

### A3. The things only a human notices

- [ ] **Resize** — shrink below minimum, maximise, restore. Nothing clips or crashes
- [ ] **Colours** — correct in light and dark desktop themes
- [ ] **DPI** — a non-100% display scale (125% / 150% / 200%). Text is not blurry or clipped
- [ ] **Focus/tab order** — keyboard-only navigation reaches every control in a sane order
- [ ] **Repaint** — dragging another window across ours leaves no artefacts
- [ ] **Close** — window X, Alt-F4, and in-app quit all exit with status 0 and no hang
- [ ] **Second run** — launching twice in a row works (no stale lock/handle)
- [ ] Known-remaining libui-ng gaps still absent and acceptable: `uiScrollingArea`, DPI,
      `DrawBitmap`, dark mode

### A4. TUI-specific

- [ ] Terminal resize mid-run reflows rather than corrupting
- [ ] Ctrl-C exits cleanly and **restores the terminal** (no invisible cursor, no raw mode)
- [ ] Runs in Windows Terminal, and in at least one other (conhost / VS Code terminal)
- [ ] Non-tty invocation refuses cleanly rather than crashing *(gui_scaffold_check asserts
      rc=3 here — confirm it is a readable message, not just a code)*

---

## B. CLI surfaces no gate invokes

**Derivation:** every `zebra <sub>` in `--help`, grepped across `tools/*.sh`, `tools/*.py`,
`fuzz/*.py`. These came back with **zero invocations**. They ship; nothing exercises them.

### B1. Subcommands with no automated coverage at all

- [ ] `zebra repl` — starts, evaluates, keeps state across lines, handles a syntax error
      without dying, exits on Ctrl-D and on `:quit`/equivalent. **Multi-line input** (a
      `def` spanning lines) is the part most likely broken
- [ ] `zebra types <file>` — prints inferred types; spot-check against what you expect,
      especially somewhere §28a is weak (an unresolved type should say so, not lie)
- [ ] `zebra debug <file>` — needs `lldb-dap`. Breakpoint hits, locals readable, step
      over/in/out, continue to exit
- [ ] `zebra debug --listen PORT` — a real IDE attaches
- [ ] `zebra check <file>` — dead-code detection. Confirm it finds a deliberately
      unreachable fn **and does not** flag a live one

### B2. Flags with no automated coverage at all

- [ ] `--warn-non-exhaustive` — warns on a `branch…else` that silently swallows variants,
      and stays quiet on an exhaustive one
- [ ] `--zig-backend` — delegates to the bootstrap and produces a working binary
- [ ] `--version` — prints something correct *(trivially automatable — if it is wrong,
      file it as a gate, not a fix)*
- [ ] `--library-mode` — produces a library artefact that something can actually link
- [ ] `--single-threaded` — a program that spawns no threads works; **and** confirm the
      documented UB (using threads under it) is at least documented at the call site

### B3. Thinly covered (1–3 references, worth a human pass)

- [ ] `zebra build` — `build.zbr`, `--build-file`, `--list-targets` JSON is valid and
      describes the real graph
- [ ] `zebra test` — including `--tag` filtering, and a *failing* test reporting usefully
- [ ] `zebra fmt` — `--check` and `--print`; **round-trip on the whole corpus** (fmt twice
      = same bytes) is the property most likely to be violated
- [ ] `typecheck-merge` — on a real conflicted file
- [ ] `--single-file` — emitted single-file output compiles and runs

---

## C. First contact — the 0.9 bar is "ready for others"

**Why this matters more than it looks.** Newcomers meet the docs before the compiler, and
this repo's most consistent recent finding is that **the compiler is in better shape than
its description of itself**. Three of the last four investigations found the docs wrong and
the code right (BUG-257; the `--release`/`--turbo` conflation; a stale coverage figure).

- [ ] **Follow QUICKSTART start to finish on a clean machine**, typing what it says. Note
      every place it does not work. *(This is how BUG-245 was found: `sys.go(lambda …)` in
      five blocks, and `lambda` is not a Zebra keyword — none had ever compiled.)*
- [ ] **27 known-broken doc examples** — `python tools/doc_example_check.py` baseline.
      Three families: `print` without parens, the removed `to!`, assorted stale forms.
      Decide: fix them, or delete them. Do not ship them
- [ ] **README** — does it tell a stranger what Zebra is, why, and how to run hello-world?
- [ ] **Install story** — how does someone who is not you get a working `zebra`? Is Zig a
      prerequisite? Is that stated?
- [ ] **Hello-world time-to-first-success** on a machine that has never built this
- [ ] **Licence** present and intended
- [ ] Pick three sections of QUICKSTART at random and check the claims against the compiler

---

## D. Error message quality — no gate reads them for helpfulness

Gates assert an error *fires* and sometimes that its text *matches*. **Nothing asserts a
message is any good.** With 31 selfhost diagnostics now (up from 19), this is the moment to
read them as a user would.

- [ ] Write ten realistic beginner mistakes; for each: is the message accurate, does it
      point at the right span, and does it say what to do?
- [ ] **Column numbers.** Known shortfall: the two destructuring diagnostics report column
      **0**, because `AstBuilder` builds `StmtDestruct` with `Span(line, 0, …)`. Same class
      as BUG-249. Confirm how much this bothers you
- [ ] **Leaked Zig errors.** `tools/frontend_gap.py` measured `-c` missing **43%** of what
      `zig` rejects. Every miss surfaces as a message in *Zig's* vocabulary about code the
      user never wrote. Sample a few and judge whether that is beta-acceptable
- [ ] Multi-error output: is it ordered, deduplicated, and does it stop at a sane count?
- [ ] A parse error deep in a file: does it blame the right line?
- [ ] Compare a few messages against the bootstrap's — the selfhost is deliberately
      **narrower** on the new checks (`isConcretePrimitive`); confirm the misses are
      acceptable rather than surprising

---

## E. Stdlib surfaces with no corpus coverage

**The governing law, established three times this session:** *code that nothing executes
does not survive a toolchain upgrade, and nothing tells you.* `Progress`, `Csv` and `Shell`
were the last three unexercised stdlib namespaces and **all three had broken Zig 0.16
migrations**, found only by running them.

These capitalised names appear in `src/Builtins.zig` and **nowhere in any test or example**
(control: `List` was found, so the search works):

- [ ] `BuildTarget`
- [ ] `Dictionary`
- [ ] `GuiContext`
- [ ] `IList`
- [ ] `ProgressBar`
- [ ] `SqliteRow`
- [ ] `SysProcess`

For each: is it real and reachable, or vestigial? **Anything real needs one running
fixture** — that is the whole lesson of Progress/Csv/Shell. Anything vestigial should be
deleted, because a name in `Builtins` is a promise.

Also worth a human pass (advertised, thinly exercised):

- [ ] SQLite — a real schema, transaction, rollback
- [ ] TCP/UDP/WebSocket/HTTP `serve` — under an actual client, not a fixture.
      **BUG-154 is open**: `Tcp.serve` per-connection state has no lock
- [ ] Threads / `ThreadPool` / `Chan(T)` / `sys.go` — under contention, not a smoke test
- [ ] IANA timezone data — a DST boundary, a leap year
- [ ] `DynLib` — loading a real shared library
- [ ] SIMD — **`f32x4` is documented in QUICKSTART and the bootstrap calls it "not
      defined"**; the selfhost is untested at that width

---

## F. Environment and distribution

- [ ] **There is no CI.** Every gate runs only when a human remembers. Decide whether
      0.9-beta ships without it. *(This is the single highest-leverage automation item on
      the list — everything else here is genuinely human work; this is not.)*
- [ ] **Windows is the only tested platform.** Does 0.9-beta claim any other? If yes, build
      and run the corpus there. If no, say so in the README
- [ ] A path with **spaces**, and a **non-ASCII** path, for input, `--output-dir`, and
      module resolution
- [ ] Behaviour when `zig` is absent from PATH — clear message, not a stack trace
- [ ] Behaviour when disk is full mid-emit *(we have hit low-disk conditions twice)*
- [ ] `zebra --release --turbo` output runs on a machine without the dev toolchain
- [ ] Binary size is acceptable to you *(830 KB release vs 20 MB debug, measured)*

---

## G. Performance — nothing measures it

No gate is a benchmark. Timings in this repo are explicitly *observations, not benchmarks*,
because the machine is usually loaded.

- [ ] Compile time for a large program — acceptable?
- [ ] `zebra -c` stays fast (~60 ms is the documented claim; `check_mode_check` guards that
      it does not start invoking zig, not the number itself)
- [ ] Runtime of something compute-heavy vs your expectation
- [ ] Memory of a long-running server
- [ ] `--release --turbo` is actually faster than debug in a way you can feel
- [ ] Contract overhead: measured at ~15–20% on smoke. **Nobody has measured what contracts
      cost in a real program** — this is the missing number behind BUG-257's design debate

---

## H. Long-running and interactive

Gates run short programs to completion. These are the shapes they cannot hold:

- [ ] A server left running for hours — memory stable, no handle leak
- [ ] REPL session of 50+ interactions — state stays sane
- [ ] LSP under a real editor: diagnostics, hover, go-to-def, completion, format,
      signature help. **Open gap: scope-aware locals** — confirm how much it hurts
- [ ] DAP debugger through a real debugging session, not a smoke test
- [ ] A program producing >4 KB of output through every path *(BUG-208 was a pipe-block
      hang; `zebra run` was fixed, other `sys.run` callers were not)*
- [ ] Ctrl-C during compilation leaves no orphaned process holding a lock

---

## I. Decisions I want your judgement on, not verification

These are not bugs. They are places I made a call that a beta review should ratify.

- [ ] **Narrow diagnostics.** Six ported this week fire only on `int`/`float`/`str`/`bool`,
      where the bootstrap fires on any non-abstract type. Rationale: selfhost inference is
      weaker (§28a), so a wide check rejects correct programs. **Cost: missed diagnostics
      today.** Ratify or widen
- [ ] **`assert` survives `--turbo`.** A contract is a proof obligation on the caller; an
      assert is a check the author wrote to run. Gated now — confirm it is what you want
- [ ] **§28a `strict` stays off by default.** Turning it on rejects 28 corpus files
      including 13 selfhost modules — the compiler cannot compile itself. Confirm the
      worklist ordering (selfhost first)
- [ ] **BUG-254: the selfhost is RIGHT and the bootstrap is wrong** on mixed-type
      arithmetic. `1 + 2.0` works, per your call. Confirm the bootstrap is not "fixed" to
      match
- [ ] **Bootstrap divergence is acceptable and growing.** It rejects `test/simd_test.zbr`,
      has no `--output-dir`, lags on features. It remains the **regen authority**. Confirm
      the endgame and the date you want it gone
- [ ] **21 open bugs / 146 fixed.** Walk the open list and confirm none blocks beta
- [ ] **121 fixed bugs have no regression fixture** (`bug_fixture_check`, known debt 126).
      Confirm this is beta-acceptable debt rather than a release blocker

---

## J. Confirm the triage, not the code

Things deliberately left broken. A beta review should confirm each is *intended*, because
"known" decays into "forgotten" quickly.

- [ ] The **27 exempt** entries in `tools/registration_exempt.txt` — each has a written
      reason; confirm the reasons still hold
- [ ] The **20 unasserted** corpus files (`python tools/registration_check.py`) — down from
      57, but each is a file whose status *nothing* asserts
- [ ] `full_sweep` baseline **337** against **448** tracked. Files outside the baseline
      cannot make the gate red **however broken they are**. BUG-241 and BUG-242 were both
      found sitting in that gap
- [ ] `output_sweep`'s auto-excluded nondeterministic files — the exclusion is *derived*
      (run twice, differ ⇒ excluded) with the reason recorded. Confirm the reasons
- [ ] The `@boundary-pending BUG-NNN` probes — these pin **known-broken** behaviour on
      purpose and **fail when the bug is fixed**. That failure is the signal to rewrite the
      probe, never to re-baseline

---

## The one thing I would most like you to do first

**Section A1 and A2, on `tui` and one desktop backend.** Not because they are the most
likely to be broken, but because they are the only items on this list where *nothing at all*
would tell us. Everywhere else, a gate is watching some fraction. In the GUI, the entire
signal is you.
