<!-- doc-status: live -->
# Next steps → 0.9 (public release)

**0.9 is ready-for-others, not 1.0.** Judge every item here against
[docs/PRINCIPLES.md](docs/PRINCIPLES.md): four gates first (a failure is a
rejection, not a low score), then the seven ranked axes. Measurements live in
[docs/archive/FINDINGS.md](docs/archive/FINDINGS.md) -- do not re-derive them.

## 0.9 — RETIRE THE IMGUI GUI BACKEND — **DONE 2026-08-29** <!-- doc-lint-ok: the file references below are a record of what was DELETED, not pointers to live work; the paths are dangling BY DESIGN -->

**Landed in two commits.** Compiler: 601 lines out of `src/CodeGen.zig` (the `.glfw` arm,
which was the imgui backend, plus the `.sdl2`/`.dx12` arm, which was never imgui's dependent
-- 178 lines of duplicated stub for backends never built). `GuiBackend` is now
`{ stub, tui, libui_ng }`. Files: 99 tracked, 35,125 lines -- `IDE/` (20),
`vendor/ImGuiColorTextEdit` (43), `vendor/fonts` (36, 15 MB). `vendor/sqlite` untouched.

**THREE THINGS THE PLAN BELOW DID NOT ANTICIPATE, recorded because they are the reusable
part:**

1. **This was exit criterion 3 of the bootstrap sunset, not a separate task.** `glfw` was
   the LAST GUI backend delegating to zebra-bootstrap; `tui` and `libui_ng` are already
   native (`selfhost/main.zbr:2695`). The plan noted imgui code "dies with the bootstrap
   regardless" -- the converse, that retiring imgui is what LETS the bootstrap die, was not
   recorded and is the more useful direction.
2. **The build template was measured as ONE line and is a 65-line PAIR** pinning `zgui`,
   `zglfw` and `zopengl`. After the cull it would have served only `.stub` -- a backend
   whose every widget call is a no-op -- so a GUI app that renders nothing was pulling three
   GUI dependencies. Replaced with a dependency-free template.
3. **Four user-facing surfaces still advertised the dead backends**, one self-contradicting:
   `unknown gui backend 'glfw' (stub|glfw|sdl2|dx12|tui|libui_ng)` refused a value and
   offered it in the same breath. A removal is not finished while the diagnostics still
   promise what was removed.

**AND THE DOCS WERE WRONG IN THE GENEROUS DIRECTION, which a search-and-delete pass would
have propagated.** QUICKSTART said the `CodeEditor` widget and `g.ll.*` were both
"ImGui-only". Reading codegen: `g.ll.*` is indeed gone (0 occurrences, no replacement), but
the CodeEditor is NOT -- `libui_ng` carries a real Scintilla-backed editor and `tui`/`stub`
carry a text-buffer stub. Deleting both claims would have removed a working feature from the
documentation. **Derive capability claims from the code, not from the doc being edited.**

`gui_scaffold_check` passes with both legs running, so `tui` -- the only automated GUI
coverage that exists -- survived intact.

---

**The original plan, kept for its measurements:**

### RETIRE THE IMGUI GUI BACKEND (Sean, 2026-08-25). SURVIVORS: **tui** and **libui-ng**.

Decision: **imgui dies**, along with the imgui IDE and the vendored ImGuiColorTextEdit.
`tui` and `libui_ng` are the two backends going forward.

**MEASURED FIRST, so nobody re-derives the scope.** It is smaller than the 278 textual
mentions suggest, because almost all of it is one contiguous emitted-template block.

| what | where | size |
|---|---|---|
| the `.glfw` arm — THE imgui backend | `src/CodeGen.zig:3252-3674` | **422 lines**, one `writeAll` of a `\\` template |
| `.sdl2, .dx12` arm | `src/CodeGen.zig:3675-3852` | **178 lines** |
| enum members | `GuiBackend = enum { stub, glfw, sdl2, dx12, tui, libui_ng }` | 3 to drop |
| build template line | `src/main.zig:1217` (`exe.linkLibrary(zgui_dep.artifact("imgui"))`) | 1 |
| vendored | `vendor/ImGuiColorTextEdit` (43 tracked files), `vendor/fonts` (36 files, 15 MB) | |
| the IDE | `IDE/ZebraIDE.zbr` + `IDE/ZebraIDE_gui/` | 5 tracked `.zbr` | <!-- doc-lint-ok: deleted 2026-08-29; this row is the record of WHAT was removed, so the path is dangling by design -->

**`sdl2`/`dx12` ARE NOT IMGUI — checked, because the assumption was that they were.** That
arm is 178 lines of DUPLICATED STUB under a single comment:

```
// TODO: sdl2/dx12 GUI backend not yet implemented; using stub.
```

They were never implemented at all, so they are an independent deletion rather than
imgui's dependents. **Same shape as `aspect` in the reserved-words work** (BUG/U4a): an
enum member reserved for something never built, costing real surface area — every
`--gui-backend` value is a promise the CLI appears to make.

**THREE FACTS THAT MAKE THIS CHEAP:**
1. **`selfhost/*.zbr` mentions imgui ZERO times.** The selfhost never implemented it;
   `--gui-backend=glfw` delegates to the bootstrap, and the bootstrap is being retired
   anyway. This is code that dies with it regardless.
2. **No gate covers it.** `gui_scaffold_check` is tui-only, so nothing goes red — and
   nothing is verifying it today either.
3. **No corpus file builds with it.** Only docs and the IDE reference `--gui-backend=glfw`.

**DO NOT "FIX" THE HISTORICAL DOCS.** `docs/SELFHOST_JOURNAL.md` and `CHANGELOG.md` are
`doc-status: historical`; an entry describing a backend that existed in May is accurate
history, and rewriting it falsifies the record. `doc_lint` already exempts them. What DOES
need updating: `QUICKSTART.md` (the backend table), `IDE/README.md`, <!-- doc-lint-ok: the IDE was deleted rather than updated; kept as the original plan text -->
`docs/archive/BETA_REVIEW_CHECKLIST.md`, `docs/UI_QUICKSTART.md`.

**ORDER:** delete the arms and enum members first and let `doc_lint` name every stale
reference — that is the tool doing the inventory rather than a hand-written list, which is
the same argument `corpus_ls.sh` makes.

## 0.9 — FREEZE THE BOOTSTRAP, THEN MOVE TO N-1 (Sean, 2026-08-29). ADOPTED.

Sean: "is it time to sunset the bootstrap compiler?" Answer: **not yet, but freeze it now,
and move to N-1 sooner than later.** The keyword removals below are PARKED behind this.

**THE IMMEDIATE CONSEQUENCE, and it saves the most work.** `defer`, `errdefer` and
`abstract` are **bootstrap-ONLY** -- measured 2026-08-29, the shipping compiler rejects all
three (`class X is abstract` compiles under the bootstrap, `rc=1` under the selfhost). Sean
had marked them for removal, which is ~62 lines across grammar rules, AST node types and
codegen paths (`genDefer` is a real function at `src/CodeGen.zig:13425`). **If the bootstrap
retires they vanish for free.** Do not do that surgery until this is decided.

**THE ONE REAL ARGUMENT FOR KEEPING A SECOND IMPLEMENTATION** is already written in
`bootstrap_check.sh`'s own comments: "Using selfhost-A to regenerate itself is
chicken-and-egg -- a codegen bug in `selfhost/CodeGen.zbr` would cause selfhost-A to
reproduce that same bug in the output." That is Thompson's *Reflections on Trusting Trust*,
and it is not a small objection.

**BUT THE STANDARD ANSWER IS NOT A SECOND IMPLEMENTATION -- IT IS N-1 BOOTSTRAPPING.** GCC,
Rust and Go all take stage-0 from a PREVIOUSLY RELEASED BINARY rather than a separately
maintained compiler. Our round-trip already performs stages 1-3. So the requirement is not
"a compiler written in Zig", it is **"a compiler we did not just build"** -- and those have
very different maintenance costs.

**AND WE MAY ALREADY HAVE STAGE-0 FOR FREE.** `selfhost/*.zig` are COMMITTED, and `zig
build` produces `zebra.exe` from them. That binary was generated by a previous, reviewed
run -- which is exactly what a stage-0 is. The Thompson protection then comes from the
generated `.zig` being reviewed AS A DIFF: a codegen change that alters emission shows up
in the tracked files, which is why they are tracked. **The decisive experiment is therefore
cheap: does the SELFHOST's emit of its own modules match the BOOTSTRAP's, byte for byte?**
If yes on today's tree, the switch is a one-line change of authority rather than a project.

**THE COST SIDE, MEASURED 2026-08-29 rather than asserted:**

- **Four keywords the two compilers disagree on** -- `defer`, `errdefer`, `abstract`
  (bootstrap-only) and BUG-316's `internal` (different SEMANTICS in each).
- **48 tracked "bootstrap gaps"**, already documented as informational and don't-chase --
  which is an admission that the reference has stopped being a reference.
- **BUG-216's lint (`lint_interp_escape`) exists ONLY because the bootstrap corrupts `\"`
  inside an interpolated string AND is the regen authority.** An entire gate is a workaround
  for one component.
- **Three disagreeing keyword sources**, which cost an hour of triage the day
  `lint_keyword_coverage` was written.

Two compilers that have diverged are not one checking the other; they are two languages, and
every divergence costs triage.

**DECISION: FREEZE, DON'T KILL.** Change the bootstrap's JOB rather than removing it. No new
features, no parity work, no fixes except ones that break REGENERATION. It becomes purely
the stage-0 witness. That stops the bleeding today at zero cost and turns the eventual
removal into a formality.

**UPDATED 2026-09-04: `zebra debug`'s SOURCE MAP is ported and gated. The RELAY is not,
and its cost is NOT yet known -- read the last paragraph before scoping it.**

`zebra debug` is a DAP relay, not a debugger: it sits between an IDE and lldb-dap and
rewrites every source coordinate crossing it, driven by codegen's `// zbr:` markers.

**DONE:** the source map (`dbgLoadMarkers` / `dbgZbrToZig` / `dbgZigToZbr` /
`dbgCanonicalZbr` in selfhost/main.zbr), plus `zebra debug --dump-map
<file.zbr|file.zig>`. Gated by `tools/debug_map_check.sh` (6 legs, FAST tier), which
needs NO lldb-dap. It found BUG-329 on its first run.

**THE TRANSPORT QUESTION IS SETTLED, and it is the finding that makes the port
tractable.** The Zig default path pipes lldb-dap's stdio, which Zebra cannot do -- there
is no piped-spawn primitive. But `runDebugSessionListen` spawns lldb-dap with
`--connection listen://127.0.0.1:PORT` and `.stdin=.ignore, .stdout=.ignore`, which is an
EXACT match for the existing `_sys_spawn`, and talks TCP. The two transports are
INDEPENDENT: the lldb side can be TCP while the IDE side stays stdio. So the stdio mode
is portable, and it is the one to do -- `Tcp.serve` loops and never hands back the
connection the way the Zig `accept` does, and BUG-154 already records that shape as sharp.

Portable with what exists TODAY: `compileDebug` -> `sys.exec_inherit`; lldb-dap discovery
-> `sys.getenv("PATH")` + `File.exists` (plus the Program Files / usr/bin / homebrew
fallback -- lldb-dap IS installed on this machine but is NOT on PATH, so the fallback is
load-bearing, not belt-and-braces); PATH augmentation -> `sys.setenv` before spawn (sound
because the process does nothing else); our own DAP framing -> `sys.readBytes(n)` +
`Terminal.write`, which the LSP server already does and `lsp-smoke` already gates; relay
threads -> `sys.go`. PORT THE 30 x 100ms CONNECT RETRY (src/Debugger.zig:1058) -- without
it, connecting before lldb-dap has bound is an intermittent failure that works locally.

**WHAT IS NOT SETTLED, and do not quote a number for it.** `transform` touches only two
message kinds (`setBreakpoints` outbound, `stackTrace` responses inbound) and returns the
ORIGINAL BODY for everything else and on any error -- so the pass-through case needs
nothing new. But inside the two it does rewrite, it re-serialises by walking
`root.iterator()` and writing each untouched key's `entry.value_ptr.*` back VERBATIM.
Zebra has no key iteration, and -- the part that is easy to miss -- a list of keys would
not be enough either: re-emitting a sibling field whose TYPE you do not know needs a
generic value accessor plus per-value stringify, and every value-returning getter Zebra
has is typed and FABRICATES a default on miss (BUG-331). So the honest scope is "at least
one new stdlib primitive, shape undetermined", not "one primitive". Settle it on paper
first: a preamble edit costs the full `zig build` -> regen -> `zig build` order, and a
wrong primitive costs it twice. The cheap question that decides it: can `seq`/`type`/
`command` and the untouched breakpoint fields be reconstructed from typed getters alone?

**REMAINING BEYOND THAT:** `--zig-backend` and the `stub` GUI backend, which are policy
rather than code.


**UPDATED 2026-09-02: `repl` IS PORTED. Two runtime jobs remain, not three.**

`zebra repl` is now native (`replRun` in `selfhost/main.zbr`); the bootstrap delegation is
deleted. It lives in main.zbr rather than a new `selfhost/Repl.zbr` <!-- doc-lint-ok: names the module deliberately NOT created; the sentence explains why the REPL lives in main.zbr instead --> deliberately -- a new
module must join the FILES list in `bootstrap_check.sh` and `rebuild.sh` and the build's
import set, i.e. the regeneration machinery rewritten hours earlier for criterion 2.

**The port is SIMPLER than the original and the difference is worth knowing.** src/Repl.zig
compiled in-process, injected a sentinel `debug.print` into the emitted Zig at the new
cell's line, ran it, and showed output past the sentinel. The Zebra version writes the
session as an ordinary `.zbr`, re-invokes the compiler, and shows the SUFFIX beyond what
the previous run produced -- the session replays deterministically, so prior cells reprint
identically. Costs a process spawn per cell; buys no duplicated pipeline and no sentinel
injection to keep in step with codegen.

**Two things a faithful port would have got wrong.** The original captures STDERR, because
Zebra's `print` used to write there -- since BUG-318 it writes to stdout, so a faithful
copy would have shown nothing. And decl cells must be type-CHECKED, not run: a
declarations-only session has no `def main()`, so running it fails, and the failure then
prevents the decl from being committed -- so the NEXT cell reports the name as undefined.
One defect presenting as two, found by driving a session and invisible to both the
front-end check and the build.

Gated: `tools/cli_check.sh` drives a real session and asserts state crosses a cell
boundary, a decl cell is accepted AND callable, and `:clear` really resets (proven by the
failure of the cell after it).

**REMAINING:** `zebra debug` (src/Debugger.zig, 1123 lines -- a DAP protocol proxy, a
materially different and larger job than a read-eval loop), plus `--zig-backend` and the
`stub` GUI backend, which are policy rather than code.


**THE BOOTSTRAP'S REMAINING JOBS, COSTED 2026-09-01.** "Retire the bootstrap" was a fog;
it is now a list with numbers against it. These are the only things it still does that the
selfhost does not:

| job | what backs it | cost to remove |
|---|---|---|
| `zebra repl` | `src/Repl.zig` | **579 lines** to port or drop |
| `zebra debug` | `src/Debugger.zig` | **1123 lines** to port or drop |
| `zebra build` | preamble `_build_*` -- **88 lines, and already in the SELFHOST's own preamble** | possibly zero (see below) |
| `--zig-backend` | a flag, not code | a policy decision |
| `--gui-backend=stub` | the `stub` backend only | tui and libui_ng are already native |

**Total real porting surface: 1,702 lines across two files.** Everything else is a
decision rather than an implementation.

**`build` IS THE ONE TO LOOK AT FIRST, and the evidence is incomplete.** The bootstrap's
entire `build` handler is:

```zig
if (build_mode and source_path == null) {
    source_path = build_file orelse "build.zbr";
}
```

No build logic at all -- it sets a default source path and runs the ordinary
compile-and-run pipeline. The machinery lives in `stdlib_preamble.zig`, which the selfhost
owns and embeds too. On that reading the delegation is pure historical accident.

**BUT THE OBVIOUS EXPERIMENT IS MISLEADING, so it is recorded rather than relied on.**
`zebra build.zbr` (selfhost, direct) exits 0 and prints `build declarative: ok`, while
`zebra build` (delegated) fails with BUG-327. That looks like proof the selfhost can
already do the job. It is not: both committed build fixtures are DECLARATIVE (`build_smoke_test.zbr`
says so in a comment -- "we do NOT call b.run()"), so the direct run never reaches the code
BUG-327 is about. The real difference is emission shape -- the bootstrap splices the
preamble INLINE into the root file, where Zig analyses it eagerly, while the selfhost
IMPORTS `zebra_rt.zig`, where analysis is lazy. **The stale API is not fixed on the
selfhost path; it is merely not reached.**

**What would settle it:** a build fixture that actually calls `b.run()`, run both ways.
Neither committed fixture does. Writing one is the next concrete step on this criterion,
and it doubles as the regression test BUG-327 asks for.

**ORDERING NOTE.** The CLI gate (`tools/cli_check.sh`, added 2026-09-01) pins the current
behaviour of `repl` and `build` from OUTSIDE the repo. That is the precondition for
touching any of these: each delegation can now be ported or dropped with a witness that
fails if it regresses, and the witness runs where users actually stand rather than where
the repo happens to be.



**MEASURED 2026-09-04: THE BOOTSTRAP'S ENTIRE REMAINING GATE FOOTPRINT IS `zebra build`.**

All four exit criteria are met. What was NOT known is whether anything still needs the
binary in practice, so it was tested by the only method that can answer it: hide
`zig-out/bin/zebra-bootstrap.exe` and run the tier.

**SUPERSEDED 2026-09-04, LATER THE SAME DAY: `zebra build` IS NATIVE AND THE FOOTPRINT IS
NOW ZERO.** The FAST tier is **28/28 with the bootstrap binary deleted**, hidden for the
whole run (the first attempt at this measurement was confounded by a mid-run restore --
see below -- so this one was left strictly alone until the tier finished).

What the delegation was carrying was never a pipeline: the bootstrap's entire `build`
implementation is "set the source path to build.zbr and run it as an ordinary program".
It was carrying two CODEGEN modes the selfhost lacked, and both fail SILENTLY with exit 0:

| mode | symptom when missing |
|---|---|
| `build_mode` -> `_build_auto_run()` | a build file that never calls `b.run()` compiles, runs, exits 0, builds NOTHING |
| `list_targets_mode` -> `_list_targets_mode = true` | `--list-targets` BUILDS instead of listing |

Both are now in `selfhost/CodeGen.zbr` (module-level flags plus setters, matching
`_gui_backend`), and `--list-targets` output is byte-identical to the bootstrap's on a
two-target project. Three `cli_check` legs cover them, watched RED against a mutant with
both setters neutered -- all three failed, including "does NOT build while listing", which
is the silent direction.

**A METHOD NOTE THAT COST A WRONG ANSWER, recorded because it is the trap in this kind of
measurement.** Probing only the `b.run()` path showed the delegation was "vestigial"; the
absent-`b.run()` path showed silence. Probe a success and you underestimate the gap. The
original measurement below stands as history:

Result: **27 of the 28 FAST gates pass with no bootstrap present.** The single failure is
`cli-surface`, on exactly two legs, and both are the same subcommand:

```
FAIL   a build that calls b.run() SUCCEEDS
FAIL   ...and produces the named binary
ok     ...and fails FAST rather than hanging or crashing
```

That third line passing is worth as much as the two failures: without the bootstrap,
`zebra build` refuses with a message instead of hanging or panicking, which is BUG-322's
fix still holding.

**Two traps in running this experiment, both of which produced a wrong reading first.**

`boundary` appeared to HANG without the bootstrap and was briefly written up as a gate that
hangs rather than fails. It does not: it takes **339 s**, and the probe had a 300 s timeout.
Re-run with room it is `32 pass, 0 fail` and needs no bootstrap. (CLAUDE.md documents
boundary as "~30 s"; measured today it is **104-339 s** across four runs, so that figure is
stale by 3-10x and the timeout was chosen from it.)

And a mid-run restore silently confounds the whole tier. The first attempt reported
`28/28 PASS` with the binary hidden -- but the binary had been put back while `boundary` was
in flight, so the last five gates (`boundary`, `stream-sep`, `cli-surface`, `lsp-smoke`,
`debug-map`) ran WITH it. A tier result is only as good as the tree being unchanged
throughout; those five had to be re-run individually to mean anything, and doing so is what
found the `cli-surface` failure the confounded run had hidden.

**WHAT THIS CHANGES.** The bootstrap is no longer load-bearing for correctness -- it is not
the regen authority (criterion 2), no gate needs it except for `zebra build`, and it can no
longer serve as a divergence reference (criterion 4). Three delegations remain in
`selfhost/main.zbr`: `zebra debug` (3027, relay only -- the source map landed 2026-09-04),
`zebra build` (3065), and `--zig-backend` (3600, the deliberate escape hatch, which is a
decision rather than code).

**CHEAPEST NEXT STEP, and it may already be free:** `BuildTarget` appears 6x in
`selfhost/CodeGen.zbr`, so the Build runtime is partly ported already. Whether the
delegation is still NECESSARY or merely vestigial is untested. Test that before scoping a
port -- and note the two `cli-surface` legs above are the ready-made witness for it.


**EXIT CRITERIA -- all four, in order:**

1. ~~**The equivalence experiment passes.**~~ **RETIRED 2026-08-29 -- IT WAS THE WRONG
   TEST, AND THE RIGHT ONE ALREADY PASSES ON EVERY COMMIT.**

   The proposed test was "selfhost emit == bootstrap emit, byte for byte". **That can never
   pass, by design.** The two compilers emit DIFFERENT SHAPES: the bootstrap inlines the
   runtime into one file (Token.zig, 4532 lines) while the selfhost emits the runtime-module
   shape (654 lines plus a shared `zebra_rt.zig`) -- the default since 2026-07-28. A byte
   comparison across that boundary measures the shape, not the compiler. Three harness
   iterations went into discovering this; the fourth found the premise was wrong.

   **THE QUESTION THAT MATTERS is not "does it emit the same bytes" but "can a compiler
   built from the selfhost's own emission regenerate itself consistently" -- and
   `bootstrap_check.sh` steps 3-5 already answer it, green, on every commit.** Verified
   directly: `/tmp/bs-zig` (a fresh bootstrap regen) is **byte-identical to the committed
   `selfhost/*.zig`, all 12 files**. So `zig build` produces a compiler equivalent to
   selfhost-A, A emits, B is built from A's OWN emit, and B's emit matches A's. That chain
   IS N-1 bootstrapping, and it has been passing all along.

   **What remains for criterion 2 is therefore a DECISION, not an unknown:** the committed
   `selfhost/*.zig` are currently the INLINE shape because the bootstrap wrote them. Moving
   the regen authority means committing the runtime-module shape instead.
2. **Regen authority switches to N-1** -- **THE CHANGE IS TWO LINES:
   `tools/bootstrap_check.sh:160` and `:195`, where `$ZEBRA` is used to emit. Point
   `ZEBRA=` at `zig-out/bin/zebra.exe` instead of `zebra-bootstrap.exe`.** Everything else
   follows.

   **ATTEMPTED AND BACKED OUT 2026-08-29. Read this before trying again.** The first attempt
   built a SEPARATE tool (`tools/regen_selfhost.sh`, kept -- it is useful for measuring)
   that emitted with the selfhost and installed the result. It applied cleanly, `zig build`
   succeeded, and then **the round-trip silently reverted it**: `bootstrap_check.sh` full
   mode is ITSELF an authority -- its own header says a successful run "leaves
   `selfhost/*.zig` in the deterministic selfhost-B-emitted fixed point", and that chain
   starts at step 1, which emits with `$ZEBRA`. Running the check that was supposed to
   VALIDATE the switch is what undid it.

   The result was a MIXED TREE: `main.zig` selfhost-emitted, eleven modules
   bootstrap-emitted, `_zbr_ty_Span` referenced but not exported. It did not build. Two
   things caught it and neither was a person: `doctor` REFUSED the gate tier because the
   binary no longer matched the sources, and the build failed loudly because the two
   emitters use different symbol names (`_zbr_fn_` prefixing). **A mixed tree that
   COMPILED would have been far worse.**

   **What the bootstrap seed actually buys, measured rather than assumed.** selfhost-A is
   built FROM bootstrap-emitted Zig, but A's SOURCE is the same `.zbr` -- so A behaves
   exactly as the selfhost does. The seed is a different ENCODING of the same program, not
   an independent implementation of it. If `CodeGen.zbr` had a codegen bug today, A would
   have it, A's emit would have it, B would inherit it, and **the round-trip would still
   pass**. It proves fixed-point convergence, not correctness.

   So the seed buys exactly one thing: the committed `selfhost/*.zig` are produced by an
   independent implementation, so a selfhost codegen regression cannot write itself into
   the committed artifacts.

   **The risk of switching, stated plainly:** a codegen regression becomes SELF-PROPAGATING
   in the committed files. Detection moves from "a second implementation would have emitted
   something different" to "the gates over 500+ corpus files fail". Recovery moves from the
   bootstrap to GIT -- which is exactly N-1, and exactly what GCC, Rust and Go accept.

   **What gets BETTER, and it was under-weighted:** today the committed `selfhost/*.zig`
   are **not what the shipping compiler produces**. The artifacts a reviewer inspects come
   from a compiler nobody runs. That is a permanent silent inconsistency, and the switch
   removes it. The 33,000-line diff is a ONE-TIME encoding change; the inconsistency it
   removes is forever.

   **CRITERION 2 IS DONE — LANDED 2026-08-30.** The regeneration authority is now the
   SELFHOST. What follows below is the pre-flight that stopped the recorded procedure from
   being run, kept because three of its findings are the reason this worked.

   **WHAT ACTUALLY LANDED, which is not what the ticket said:**

   | the ticket said | what was true |
   |---|---|
   | "the change is two lines" | the two lines emit via `--emit-zig >`, which writes ZERO BYTES under the compiler being switched to (BUG-317) |
   | "full mode installs the new fixed point itself" | full mode does NOT install; it only validates. `--update` installs |
   | the 12 modules in `FILES=` | nine generated `*_test.zig` also existed, orphaned, depending on a symbol the new shape does not export |

   **THE MECHANISM THAT WORKS is `--emit-zig --output-dir`, and it is SIMPLER than the
   loop it replaced:**

   ```
   zebra.exe --emit-zig --output-dir DIR selfhost/main.zbr
   ```

   One command, ~11 s, emits main plus every dependency plus `zebra_rt.zig` — the identical
   13-file set `bootstrap_check.sh` step 4 has been building selfhost-B from on every green
   round-trip. No per-module loop, no move step, no build.

   **THE SEQUENCE THAT WORKED:**
   1. `tools/bootstrap_check.sh` — `ZEBRA=` -> `zig-out/bin/zebra.exe`, and BOTH emit sites
      (step 1, update mode) -> `--emit-zig --output-dir ... >/dev/null`. Steps 3 and 5
      already used that form.
   2. `tools/rebuild.sh` — the `--module` fast path had its OWN regen against the bootstrap.
      Switched too, or one module silently reverts to the other emitter's shape.
   3. `git rm` the nine orphaned `selfhost/*_test.zig` (Sean's call, 2026-08-30). Their
      `.zbr` sources are KEPT: the generated artifacts were duplicated logic, the sources are
      not duplicated anywhere.
   4. `bash tools/bootstrap_check.sh --update` — installs.
   5. `bash tools/rebuild.sh --no-regen` — builds AND re-stamps.
   6. `bash tools/bootstrap_check.sh` — full round-trip. **PASS, byte-identical**, confirmed
      independently with `diff -rq /tmp/bs-A /tmp/bs-B` = 0 entries.

   **RESULT.** `main.zig` 9,292 -> 5,474 lines; `selfhost/zebra_rt.zig` is now a committed
   file; every module header reads `// Generated by zebra-selfhost.` **BUG-317 closed for
   real** — `--emit-zig > file` went from 0 bytes to 1,006, and `stream_check.sh`'s XFAIL pin
   was retired into a positive assertion, which is exactly what the pin existed to force.

   **A CAVEAT ON THE SAFETY ARGUMENT, found while committing.** This plan's Thompson
   protection is stated as "the generated files are TRACKED and the diff is reviewed."
   Tracked, yes. But `.gitattributes:11` carries

   ```
   selfhost/*.zig linguist-generated=true -diff
   ```

   so `git diff` on them shows **nothing at all** by default -- `Bin 421257 -> 242021 bytes`,
   zero insertions, zero deletions -- and git even mis-detects a rename between two unrelated
   generated files because it is comparing them as opaque blobs. The content IS reviewable,
   with `git diff --text`, which shows the real hunks (`@@ -1,3943 +1,13 @@`, header changing
   from `// Generated by the Zebra compiler.` to `// Generated by zebra-selfhost.`).

   So the protection is real but **opt-in**, and the phrase "the diff is reviewed" describes
   something that does not happen unless a reviewer knows to pass `--text`. That is worth
   knowing before anyone leans on it as the answer to "what stops a self-propagating codegen
   regression?" The honest statement is: the artifacts are in git and can be diffed on
   demand; nothing surfaces that diff automatically.

   **THE HARD LIMIT HOLDS:** the frozen bootstrap still compiles the selfhost source
   (`--emit-zig selfhost/main.zbr` -> exit 0, 421,257 bytes), so it remains a viable
   emergency authority.

   **AND IT COST ONE REAL INCIDENT, worth reading before touching this again.** Verifying
   that hard limit with `zebra-bootstrap --emit-zig selfhost/main.zbr > /tmp/out.zig`
   **rewrote eleven dependency modules in place, in bootstrap shape** — `--emit-zig` sends
   the ROOT to stdout and writes DEPENDENCIES next to the source, silently (BUG-325). That
   produced the mixed tree the 2026-08-29 attempt was backed out for, from a command that
   only reads as far as its documentation says, **and it compiled**. Recovered from
   `/tmp/bs-pre`, the snapshot `bootstrap_check.sh` takes at every run. Caught by `git
   status` showing one modified file where twelve were expected — arithmetic, not a gate.
   `doctor`'s sha1 stamp would have refused the next tier.

   **(pre-flight record follows)**
   **STOP -- THE PROCEDURE BELOW DOES NOT WORK. MEASURED 2026-08-30, BEFORE RUNNING IT.**
   Two independent blockers, neither of which is about which binary is the authority.

   **BLOCKER 1: the two lines emit via a STDOUT REDIRECT, and the compiler being switched TO
   cannot write to one.** Both `:160` and `:195` are
   `"$ZEBRA" --emit-zig "selfhost/$f.zbr" > "$BS_ZIG/$f.zig"`. That is BUG-317. Running the
   exact command with each candidate:

   | authority | `--emit-zig > file` |
   |---|---|
   | `zebra-bootstrap.exe` (today's) | 215,587 bytes -- works |
   | **`zebra.exe`** (what this entry says to switch to) | **0 bytes** |
   | `zebra-selfhost-B.exe` | 19,153 bytes -- works |

   So the change as written **regenerates twelve EMPTY files**. The entry's own note that
   criterion 2 "closes BUG-317 for free" describes the AFTER state and is the trap: the fix
   for 317 is this switch, and this switch's mechanism is broken by 317. Literal
   chicken-and-egg. (Why: `zebra.exe` is built from the bootstrap's emission, which lowers a
   Zebra `print` to `std.debug.print` -- stderr. See
   `wiki/pages/claude/fieldnotes_compiler-orbit_2026-08-30.md`.)

   **Pointing at `zebra-selfhost-B.exe` instead is tempting and is NOT reproducible.** It
   works, but it is a gitignored build artifact -- absent on a fresh clone, so step 1 would
   have no authority. The reproducible seed is the COMMITTED `selfhost/*.zig`, and the binary
   built from them is `zebra.exe`. So the fix is to change the **mechanism**, not the
   authority: `--output-dir` works with `zebra.exe` today (verified on 527 corpus files plus
   all twelve modules via `tools/regen_selfhost.sh`). That is more than two lines -- it swaps
   stdout emission for directory emission and needs a move step.

   **BLOCKER 2: nine generated `selfhost/*_test.zig` are NOT in the regenerated set, and they
   depend on a symbol the new shape does not export.** `FILES=` at `:112` lists twelve
   modules. There are **nine more** tracked generated files (`parser_test.zig`,
   `codegen_test.zig`, ...) built from `selfhost/*_test.zbr`, and every one of them calls
   `@import("Token.zig")._initAllocator(a)`. Measured:

   - committed `Token.zig` (inline shape): `pub fn _initAllocator` -- **present**
   - emitted `Token.zig` (runtime-module shape): **0 occurrences** -- it moves to `zebra_rt.zig`

   All nine break. That is the `_zbr_ty_Span` failure of the backed-out attempt, in a second
   location nobody had looked at.

   **It would NOT fail loudly, which is worse.** `build.zig` does not reference them, no tool
   compiles them, and they are not in the smoke suite -- they are nine tracked, generated,
   ORPHANED artifacts. So the switch would leave them stale and non-compiling, silently, with
   every gate green. (They are part of why `registration_check` reports unasserted files.)

   **WHAT CRITERION 2 ACTUALLY NEEDS:** (a) an emit mechanism that does not go through
   stdout, (b) a decision on the nine test modules -- regenerate them in the same shape by
   adding them to `FILES=`, or delete them as orphans, and (c) confirmation that `build.zig`
   still resolves with `zebra_rt.zig` alongside `stdlib_preamble.zig` and the `gui_*.zig`
   sections. (a) and (c) are mechanical; **(b) is Sean's call**, since deleting tracked
   artifacts is not mine to make.

   The entry below is left UNCHANGED as the record of what was believed, per the archive
   ethic. Do not run it.

   **HOW TO DO IT, when there is time for a `--daily`:**
   1. Change `ZEBRA=` in `tools/bootstrap_check.sh` (used at :160 and :195).
   2. `bash tools/bootstrap_check.sh` -- full mode installs the new fixed point itself.
      Do NOT use a separate regen tool; that is what got reverted.
   3. `bash tools/rebuild.sh --no-regen` -- rebuilds AND re-stamps.
      A plain `zig build` leaves `zig-out/.selfhost-stamp` describing the previous sources
      and `doctor` then refuses every tier, which reads as a serious alarm and is not one.
   4. `bash tools/gates.sh --daily`, as the closing move.
   5. Expect ~33,000 changed lines, ~29% whitespace. It will NOT be reviewed line by line;
      say so in the commit rather than implying otherwise.
   6. **It closes BUG-317 for free** -- the compiler's own `print` calls become `_zbr_print`
      (138/1 -> 134/5), so `--emit-zig > file` works. Retire the XFAIL pin in
      `tools/stream_check.sh` and assert the positive; the pin will fail the gate the day
      the fix lands, which is the signal to do it.

   **MEASURED 2026-08-29 AND MUCH CHEAPER THAN THIS ENTRY FIRST CLAIMED.** The earlier
   wording said `build.zig` "must build from a module plus `zebra_rt.zig`", implying build
   work. It does not. `build.zig` sets `root_source_file = selfhost/main.zig` and relies on
   RELATIVE `@import`s, and the selfhost's emit for `main` produces exactly that file set --
   eleven module `.zig` files plus `zebra_rt.zig`, all in one directory, with `main.zig`
   importing the runtime by relative path. Zig resolves it with **no build.zig change at
   all**.

   And it is not speculative: **`bootstrap_check.sh` step 4 already BUILDS selfhost-B from
   `/tmp/bs-A/main/`**, which is precisely this file set. It has been building on every
   green round-trip. So criterion 2 is a re-baseline (regen with the selfhost, commit the
   resulting set, which gains `selfhost/zebra_rt.zig` and shrinks `main.zig` from 9,262 <!-- doc-lint-ok: that path does not exist YET -- it is the file the switchover would ADD, which is the whole point of this paragraph -->
   lines to ~5,471), not an engineering task.

   The one real decision left inside it: the committed `.zig` diff will be enormous on the
   switchover -- every file changes shape at once -- so it should land ALONE, in a commit
   that does nothing else, or the review value of those tracked files (the Thompson
   protection this whole plan rests on) is lost in the noise exactly when it matters most.
3. **GUI backends stop delegating** -- **AND THIS IS THE SAME TASK AS RETIRING IMGUI,
   which was not noticed when this plan was written an hour earlier.** `selfhost/main.zbr:2695`
   reads `gui_selfhost = gui_backend == "tui" or gui_backend == "libui_ng"`, so the two
   SURVIVING backends are ALREADY native to the selfhost. The only ones that still delegate
   are `glfw` -- which IS the imgui backend (`src/CodeGen.zig:3252-3674`) -- and explicit
   `stub`. So the 0.9 item at the top of this file is not merely adjacent to the sunset: it
   removes the bootstrap's last RUNTIME job. Two docket entries, one piece of work.

   That makes this criterion far cheaper than "the harder blocker of the two", which is what
   this line said before the code was read rather than the help text. **The help text is why
   it looked hard**: it claimed `(stub|glfw|tui); delegates to bootstrap` unconditionally,
   omitting `libui_ng` entirely and describing a delegation that two of three backends do
   not do. Corrected 2026-08-29. A stale help line cost an hour of planning against the
   wrong scope -- which is the argument for UNGIT stated in miniature.
4. **`divergence_check` is re-pointed or retired.** Its reference disappears with the
   bootstrap. Its value is already questionable (48 informational gaps), but losing a gate
   silently is not acceptable -- decide deliberately.

   **DONE 2026-09-01 -- OPTION 1, Sean's call.** `n1-anchor-2026-09-01` tags **8cfdc6a**, the
   commit where criterion 2 landed, i.e. the first fixed point this compiler actually shipped.
   HEAD was NOT tagged: an anchor equal to HEAD compares the compiler with itself and can only
   report zero, and the tree was 4 commits past 8cfdc6a, so the gate is non-degenerate from
   day one.

   Verified buildable BEFORE tagging (a reference that cannot build makes the gate refuse
   forever): a worktree at 8cfdc6a produces a zebra.exe that compiles and runs a hello-world.

   `tools/n1_reference.sh` resolves the newest `n1-anchor-*` tag and caches the built compiler
   **by COMMIT SHA, never the tag name** -- a moved tag serving a stale binary is precisely the
   config-vs-artifact seam this repo keeps finding. Cache and build worktree live OUTSIDE the
   repo, because `kill_orphans.sh` kills by executable path under $REPO and `doctor --fix`
   clears scratch. It refuses unless the built reference can compile a hello-world.

   `divergence_check.sh` re-pointed; tokens renamed (`SELFHOST GAP` -> `REGRESSION`,
   `BOOTSTRAP GAP` -> `ADVANCE`) because the epistemics inverted -- a gap used to mean the
   selfhost LAGGED a reference implementation, and now means this compiler LOST a capability.

   **A harness bug found doing it, worth the retelling.** The first smoke run scored 4 of 4
   files as ADVANCES. Implausible for a 4-commit-old anchor, so it was a harness fault, and it
   was: `emit_and_check` had a `boot` branch emitting to STDOUT, which worked only because the
   bootstrap produced a SELF-CONTAINED inline file. The selfhost emits the MODULE shape, so a
   stdout redirect writes an incomplete program and zig fails `unable to load 'zebra_rt.zig'`.
   Both compilers now use `--output-dir`, which also retires a confound the gate carried for a
   year: it had been comparing an inline-shape emit against a module-shape one and attributing
   the difference to the compilers.

   **FALSIFIED WITH A REAL ADVERSARY:** reference := the current selfhost, subject := the
   bootstrap -> 7 REGRESSIONS and exit 1; the normal run gives 0 and exit 0.

   **AND IT REMOVES THE BOOTSTRAP AS A GATE REQUIREMENT.** With criterion 4 landed, no gate
   needs `zebra-bootstrap.exe`. What remains are RUNTIME delegations -- `repl`, `debug`,
   `build` -- plus `--zig-backend` and the `stub` GUI backend, which are policy rather than
   code. The honest remaining distance is 1,702 lines (src/Repl.zig 579, src/Debugger.zig
   1123) and three decisions.


   **ASSESSED 2026-09-01. THE RECORDED PLAN HAS NO ANCHOR TO POINT AT.** The proposal
   above is to re-point this gate at "the PREVIOUS selfhost (built from the committed `.zig`
   at the last tag)", turning an implementation-vs-implementation question into a
   version-vs-version one. That is the right idea. But:

   ```
   $ git tag
   archive/stash-2026-06-17-listelem
   archive/pre-zebra-split
   ```

   **Two tags, both archival, neither a release.** There is no "last tag" whose committed
   `.zig` represents a previous version of this compiler. The plan was written assuming a
   release cadence the repo does not have.

   **Three ways forward, and the choice is Sean's:**

   1. **Create the anchor.** Tag the current tree (the first N-1 fixed point, post-criterion
      2) as the reference, and re-point the gate at a worktree built from it. Cheap, and it
      gives the release cadence a reason to exist. The reference binary must be CACHED per
      tag or the gate pays a full compiler build every run.
   2. **Anchor on a commit rather than a tag** -- `HEAD~N`, or the commit that last changed
      `selfhost/`. Needs no process change and is fragile in exactly the way a moving
      reference is: the thing you are comparing against drifts under you.
   3. **Retire it.** See the decay argument below.

   **AND THE GATED HALF IS NOW DECAYING, which is new information since the plan was
   written.** `divergence_check` gates on SELFHOST GAPS -- cases the bootstrap compiles and
   the selfhost does not. The bootstrap is now FROZEN (criterion 2 moved the regen authority
   away from it, and it takes no new features by policy). So that leg asks "can a frozen
   implementation still do something the advancing one cannot?", and the answer trends
   permanently to zero. A gate whose assertion becomes vacuous by design is worse than no
   gate, because the green keeps being reported.

   The BOOTSTRAP GAP half (selfhost leads) is informational and not gated, and it grows
   monotonically for the same reason -- it was 14, then 23, then 48.

   **COST, measured in the 2026-09-01 daily: 1164 s.** It is the single heaviest gate in the
   ladder. That matters for the retire-vs-re-point decision: this is nineteen minutes per
   daily buying an assertion that is trending toward vacuous.

   **MY RECOMMENDATION, stated rather than hedged: option 1.** Tag the current tree, re-point
   at it, and cache the reference build. It preserves a real regression detector (does THIS
   compiler still handle everything the LAST RELEASE handled?), it is the only option that
   gets more valuable over time rather than less, and it gives 0.9 a natural first anchor.
   Option 3 is defensible and I would not argue hard against it; option 2 I would not do.

   **NOT STARTED -- this is a decision, not an implementation.** What is implemented is the
   measurement above.



   **RE-POINTING LOOKS BETTER THAN RETIRING, and the N-1 scheme hands us the reference for
   free.** Today it asks "bootstrap handles it, selfhost does not" -- an
   IMPLEMENTATION-vs-implementation question that is only interesting while two
   implementations exist. Point it instead at the PREVIOUS selfhost (built from the
   committed `.zig` at the last tag) and it asks "the previous release handled it, this one
   does not" -- a VERSION-vs-version question, which is a regression detector and is useful
   forever.

   That is the same tool, the same corpus, the same `--gate` semantics, and a reference that
   the N-1 bootstrapping scheme already requires us to have. It also fixes the gate's
   current weakness: "bootstrap gaps" grew 14 -> 23 -> 48 while being documented as
   informational and don't-chase, i.e. half its output had stopped meaning anything. A
   version-to-version comparison has no informational half -- every difference is either a
   regression or an intended change with a commit behind it.

**What retires WITH it, so the work is not lost twice:** `defer`, `errdefer`, `abstract`
(bootstrap-only keywords), `lint_interp_escape` (its docstring already says "retire when the
bootstrap is fixed/gone"), the `--zig-backend` escape hatch, and roughly half the
"which compiler is right?" questions in this file.

## 0.9 — BITWISE OPERATORS — **DONE**, and this section was STALE until 2026-08-29

**All six operators work in the shipping compiler** -- verified by running them, not by
reading: `12 & 10` = 8, `|` = 14, `^` = 6, `<< 2` = 48, `>> 2` = 3, `~12` = -13. They landed
2026-08-22 in both compilers and are pinned by four smoke fixtures
(`bug256_bitwise_not_test`, `bitwise_golden_vectors_test`, `bitwise_semantics_test`, and a
negative `bug253_unary_bitnot_fail`). The text below said the five binary operators "do not"
work and was **eight days out of date**.

**Recorded rather than quietly corrected, because a stale blocker is not free** -- the
2026-07-28 audit in this same file says it "makes the distance look longer than it is and
invites re-litigating decisions already shipped". This one made 0.9 look further away than
it was, in the file whose job is to say how far away it is.

**One narrow residue, bootstrap-only:** `~a` where `a` is an UNTYPED literal (`var a = 12`,
i.e. `comptime_int`) fails in the bootstrap with a leaked Zig error --
`error: bitwise not operation on type 'comptime_int'`. Explicitly typed (`var a: int = 12`)
works. The selfhost handles both. Left unfixed **by policy**: the bootstrap is frozen (see
"FREEZE THE BOOTSTRAP" above) -- no new features, no parity work, fixes only for things that
break regeneration. Worth knowing that it is a leaked Zig message rather than a Zebra
diagnostic, which is the UNGIT failure the freeze is choosing not to pay for.

### The original entry, kept for its measurements

`~a` **already works** (BUG-256, 2026-08-04). The five BINARY operators do not, and they
fail in exactly the shape `~` did before that fix — **the lexer already produces the
tokens; the parser has no rule**:

| form | today |
|---|---|
| `~a` | works |
| `a & b`, `a \| b`, `a ^ b`, `a << 2`, `a >> 2` | `error: unexpected expression token: '&'` (etc.) |

`ampersand`, `ampersand_equals`, `tilde` and `caret_equals` are all in the token set, and
`&=` / `^=` are already grammar productions — so the language has **half-committed to the
C/Python spelling already**. Diverging now would make the set internally inconsistent, and
that is the main argument for keeping it.

**THE ONE REAL CONFLICT: `^` is the heap-indirection TYPE prefix (`^T`).** Python and Zig
do not have this problem. It is resolvable the way unary and binary `-` coexist — at the
start of an operand `^` means "pointer to", after a complete operand it means xor — but
note Zebra passes TYPES AS CALL ARGUMENTS (`Atomic(int)(0)`), so `f(^Bar)` and `f(a ^ b)`
are both expression-position. A precedence parser handles it; it is still a genuine wart
rather than a free lunch. If it proves confusing, `xor` as a word operator is the clean
escape, and arguably fits better anyway since Zebra already uses `and`/`or`/`not`.

**PRECEDENCE — DECIDED 2026-08-21: PYTHON'S, NOT C'S.** An earlier draft of this entry
had this exactly backwards and recommended the footgun; corrected here so it does not
drive an implementation the wrong way.

| | `x & 1 == 0` parses as | |
|---|---|---|
| **C** | `x & (1 == 0)` | `&` binds LOOSER than `==`. Ritchie acknowledged it as a mistake — `&` predated `&&`, and by the time `&&` arrived the precedence could not be changed without breaking code |
| **Python** | `(x & 1) == 0` | `\| ^ & << >>` all bind TIGHTER than comparison |

Zebra takes Python's. In the grammar that is three new levels between `Expr4`
(comparisons) and `Expr5` (additive) — `Expr4a → |`, `Expr4b → ^`, `Expr4c → &` — and
the RHS of every comparison rule drops to `Expr4a`.

Reversing it does not silently change an answer, which is the property worth having:
under C's precedence `x & 1 == 0` is `int & bool`, and the bitwise operand check rejects
that outright. Pinned by `test/bitwise_semantics_test.zbr` leg 1.

**GOLDEN VECTORS EXIST — use them rather than hand-computing.** Fable supplied
`zebra_bits_golden_vectors.json` (2026-08-21): 24 `primitive_ops` vectors with
xor/and/or/not64/shl64/shr plus FNV and xorshift steps, and hash-function vectors.

Two things to know before wiring them in, both from the file itself:
- **They are u64.** Several `a` values exceed i64 max, and `not64` is u64-interpreted, so
  they cannot all be written as Zebra `int` (i64) literals. `uint` exists in the type
  system (`Type_.uint_`) and is the natural home for the full set; the i64-representable
  subset can pin the signed path meanwhile.
- Its note flags the overflow idiom: *"Zig default arith panics on overflow; wrapping mul
  or masking required"* for the FNV step — relevant to how `<<` is lowered.

**SLICE 1 LANDED 2026-08-22: `& | ^`, BOTH COMPILERS.** The parser was the ENTIRE gap, in both compilers.
Everything downstream already existed and had simply never been reachable: the
`bit_and`/`bit_or`/`bit_xor` AST tags in both ASTs, `binaryOpStr` in the selfhost, the
`.bit_and => "&"` emit at `src/CodeGen.zig:692`, and — decisively — the typing rule at
`src/TypeChecker.zig:4306`, whose comment already read *"preserve the operand type"*.
Type-following was not a new decision; it was a decision someone made months ago and
never wired a parser to.

That also means none of that code had ever been TYPE-CHECKED, and one piece of it was
wrong: `.shl => "<<"` emits a bare Zig `<<`, and Zig requires the shift amount to coerce
to `Log2Int(T)` — `u6` for 64-bit. `a << b` on two `i64`s is a compile error
(*expected type 'u6', found 'i64'*). Classic unreached-code false-green.

**Verification.** Two fixtures, both `smoke_run` (running them is the point — `&` and `|`
are one character apart, both emit valid Zig and both yield a number, so a swapped operator
is invisible to every compile-only gate in the tree):

- `test/bitwise_golden_vectors_test.zbr` — 96 assertions over 24 vectors, GENERATED from
  Fable's `test/data_bits_golden_vectors.json`. An EXTERNAL oracle: computed by a different
  implementation, so it cannot agree with a bug of ours.
- `test/bitwise_semantics_test.zbr` — the decisions the vectors CANNOT discriminate:
  precedence, signed operands, unsigned operands, `^` sharing a file with `^T`, and the
  relative order of `&`/`^`/`|`.

**Falsified, not merely passed.** Mutating `binaryOpStr`'s `bit_and` to emit `"|"` turned
both red, and turned red PRECISELY: in the golden fixture only the `and` legs failed while
xor/or/not64 stayed green, and in the semantics fixture only the `&`-dependent legs. A
mutation that reddened everything would have proved much less. Restored and re-verified
green.

Both compilers agree: the bootstrap emits `(a & 1)`, `(a ^ 5)`, `(a | 3)` and the selfhost
runs the same program to `0, 15, 9, prec ok`. No selfhost-only divergence to account for.

One note for whoever writes slice 2: `^T` needs a VALUE type. The first draft of the
semantics fixture used `^Cell` on a CLASS and the compiler refused it by name — *"a class
is already a reference; drop the '^'"* — which is the diagnostic behaving exactly as it
should, and is why that leg now uses a `struct`.

**SLICE 2 LANDED 2026-08-22: `<< >>`, BOTH COMPILERS. THE OPERATOR SET IS COMPLETE.**

`>>` follows the operand type (arithmetic on `int`, logical on `uint`), so no `>>>` was
needed. Lowered through `_zbr_shl`/`_zbr_shr` in the preamble, wrapping `std.math.shl/shr`,
which are TOTAL -- no UB, no panic, at any shift amount.

**The one real bug was found by the intent-authored fixture, and the golden vectors could
not have found it.** A literal-only shift (`1 << 3`) arrives as `comptime_int`, which has
no `Log2Int`; `std.math` answers with `comptime unreachable`, so the build dies inside
zig's own std naming `math.zig` rather than the user's program. All 24 of Fable's vectors
use typed `uint` variables, so every shift there has a concrete type. Only the hand-written
fixture shifts bare literals -- which is what a person writes first. **An external oracle
is stronger about VALUES; an intent-authored fixture is the only thing covering SHAPES.**

Falsified by emitting `shr` for `shl`: 5 failures, all shift-left legs, `>>` legs green;
golden 22 of 24, the 2 misses being vectors where `a<<s` and `a>>s` are both 0 (s=63/62,
small operand) so the swap is genuinely invisible. `gramgen` 960/0/0 on the new rules --
which only became possible after regenerating `grammar.txt`, since that is what it derives
its programs from.

The old decisions, for the record -- all three were settled by measurement:
- **lowering** — `std.math.shl`/`shr` are TOTAL (no UB, no panic at any shift amount) and
  were measured: `shl(i64,-8,70)` = 0, `shr(i64,-8,70)` = -1 (saturates to the sign bit,
  matching Python), `shl(i64,-8,-1)` = -4 (a negative amount reverses direction).
- **out-of-range** — Fable's vectors all use in-range amounts, so they go green under any
  choice. Needs its own fixture or it ships undecided.
- **`>>` under implicit conversion** — `int → uint` and `uint → int` are BOTH implicit
  today (measured), so a shift's kind can depend on a type that is not visible at the use
  site. An accumulator that lands in `int` gets an arithmetic shift and a silently wrong
  hash. Pin it with the same bit pattern shifted under both types.

`a << -b` needs the space: `<<-` is the arena deep-copy-out token and out-munches `<<`.
That is now pinned by leg 10 of `test/bitwise_semantics_test.zbr`.

**REMAINING for bitwise, none of it blocking 0.9:**
- **Compound assignment `&= |= ^= <<= >>=`** is still parser-blocked in the SELFHOST only.
  The bootstrap has had `AssignOp -> caret_equals` and the `AstBuilder` mapping to
  `.caret_eq` all along; the selfhost's `parseExprOrAssignStmt` has no case, so `x ^= 1`
  is `error: unexpected expression token: '^='`. Same lexer-yes/parser-no shape the binary
  operators had.
- **Hex literals are SELFHOST-only-blocked too**, and this one is a genuine divergence
  worth closing: the bootstrap grammar has `Atom -> hex_lit` plus `hex_lit_unsign` and
  `hex_lit_explicit` (the `_u` / `_8 _16 _32 _64` suffixes), and `zebra-bootstrap` accepts
  `0xFF` and `0x9E3779B97F4A7C15_u` today. The selfhost refuses both. No corpus file uses
  a hex literal, which is why `divergence` never reported it.



Every genuinely-open item, grouped. Each links to its detail section below or to
the tracker. `[ ]` = open, `[~]` = partially done / has an open tail.

## 0.9 — BRAINSTORM: THE COMPILER SHOULD TELL YOU WHAT COSTS THE MOST, BY DEFAULT (Sean, 2026-08-26)

> "After working with such tools for seven years, I've become convinced that all compilers
> written from now on should be designed to provide all programmers with feedback indicating
> what parts of their programs are costing the most; indeed, **this feedback should be
> supplied automatically unless it has been specifically turned off.**"
> — Knuth, *Structured Programming with go to Statements*,
> ACM Computing Surveys **6**(4), pp. 261-301, December 1974

Sean's, via Casey Muratori's *The Root of The Root of All Evil* (BSC 2026). This is the SAME
paper that produced "premature optimization is the root of all evil", and the quote above is
the constructive half nobody quotes. Read together, Knuth is not saying don't optimise — he
is saying **don't guess**, and then putting the obligation on the COMPILER to remove the need
to guess.

**CITATION CORRECTED, and the correction is instructive.** This was first written here as
*An Empirical Study of FORTRAN Programs* (1971) from memory. That is a real Knuth paper, and
the 1974 one draws on it — but it is not the source of either quote. The filename in Sean's
link (`p261-knuth.pdf`) is what gave it away: Computing Surveys 6(4) begins at page 261.
Verified against the venue; a plausible-sounding citation from recall is exactly the kind of
thing this repo does not let stand.

**READ 2026-08-26** (Sean supplied the PDF; `pdftotext -layout` extracts it cleanly — note
poppler IS installed and on PATH for Bash, though the Read tool cannot see it). What follows
is against the paper, not against the one quote.

### What Knuth actually argues, which is THREE things, not one

His own abstract states the programme: "(a) improved syntax for iterations and error exits,
making it possible to write a larger class of programs clearly and efficiently without go to
statements; (b) a methodology of program design, beginning with readable and correct, but
possibly inefficient programs that are systematically transformed if necessary into efficient
and correct, but possibly less readable code."

The profiling mandate is (c), and it exists to serve (b). The full passage, and the sentence
that is doing the real work is NOT the famous one:

> "It is often a mistake to make a priori judgments about what parts of a program are really
> critical, since **the universal experience of programmers who have been using measurement
> tools has been that their intuitive guesses fail.** After working with such tools for seven
> years, I've become convinced that all compilers written from now on should be designed to
> provide all programmers with feedback indicating what parts of their programs are costing
> the most; indeed, this feedback should be supplied automatically unless it has been
> specifically turned off."

And the famous line, in its actual context, is a *bridge* to that claim rather than a caution
against optimising: "We should forget about small efficiencies, say about 97% of the time:
premature optimization is the root of all evil. Yet we should not pass up our opportunities in
that critical 3%... he will be wise to look carefully at the critical code; **but only after
that code has been identified.**"

**So the mandate rests on an empirical claim about people, not a preference about tools:
intuition about hot code fails, reliably, and the compiler is the thing positioned to fix
that.** Zebra's `@profile` annotation requires the programmer to have already guessed
correctly — it is precisely the failure mode Knuth names.

### THE DEEPEST ITEM, and it is a LANGUAGE requirement, not a tooling one

> "This veil was first lifted from my eyes in the Fall of 1973, when I ran across a remark by
> Hoare that, ideally, **a language should be designed so that an optimizing compiler can
> describe its optimizations in the source language.** Of course! Why hadn't I ever thought
> of it?"

Knuth builds his "programming system of the future" on this: an interactive
program-manipulation system where you write the readable-correct version and transform it,
with the transformations expressible in the language itself.

**Zebra transforms user code constantly and describes none of it.** TCO-wrapping a
value-returning `fn` in `while(true)`; auto-boxing on `^T` assignment; choosing `const` vs
`var` from mutation analysis; materializing temporaries for method chains; auto-propagating
`throws`. Every one is a decision the compiler makes and the user cannot see — and at least
one has already bitten as a HAZARD rather than a nicety (a `branch` arm that falls through
inside a TCO wrapper HANGS; see `lint_fallthrough` and the TCO memory note).

Hoare's criterion says those should be describable IN ZEBRA. That is the same claim as UNGIT
"nothing withheld", arrived at from the opposite direction, and it is a far better feature
than a profiler: **`zebra --explain` showing what the compiler did to your code, in your
language.** It teaches the cost model instead of reporting a number, it is deterministic
(so it can be GATED, unlike timings), and it needs no measurement infrastructure at all.

### Where Zebra already stands against (a) and (b)

- **(a) is largely satisfied**: no `goto`; iteration and error exits are structured
  (`throws`/`raise`/`try`, `branch` with exhaustiveness).
- **(b) is not addressed at all.** There is no supported notion of "here is the readable
  version, here is the transformed version, and here is the proof they agree". The nearest
  thing in the repo is the round-trip gate, which asserts exactly that property for the
  COMPILER's own output — which is suggestive.

### What already exists (measured 2026-08-26, so nobody re-derives it)

| piece | where | shape |
|---|---|---|
| `@profile` method modifier | `QUICKSTART.md` §"Method modifiers" | wraps a body in `Profile.start/end` |
| `Profile.report()` | `selfhost/stdlib_preamble.zig` | sorts entries by total ns, descending |
| per-entry data | same | `{ total_ns, call_count }`, keyed by `"Class.method"` |

So the RUNTIME is largely built. **The whole gap is the trigger**: it is opt-in, per-method,
and hand-annotated. A user must already suspect a function before they can measure it —
which is precisely the guessing Knuth is arguing against. Nothing is automatic, and there is
nothing to turn off.

### Two assets that make this much cheaper here than it looks

**1. `--turbo` is already the "specifically turned off" switch, and the pattern is GATED.**
Contracts are on by default and stripped by an explicit flag; `tools/contract_mode_check.sh`
asserts that four-way matrix (and asserts, deliberately, that `--release` ALONE does not
strip them). Automatic cost feedback wants exactly that shape, and it can copy a mechanism
that already exists, already has a gate, and has already survived one wrong belief about it
(BUG-257).

**2. Source attribution across the Zebra→Zig boundary is ALREADY SOLVED.** The emit carries
`// zbr:<file>:<line>` comments next to generated statements. Mapping a cost measured in
emitted Zig back to the Zebra line that caused it is usually the hard part of this feature,
and it is done.

### Directions worth arguing about

*Runtime measurement*
1. Instrument every user function automatically rather than the `@profile`-annotated ones;
   `--turbo`/`--release` strips it. The smallest change that satisfies the quote literally.
2. Sampling instead of instrumentation — much lower overhead, which matters if this is ON by
   default; costs exactness on short runs.
3. Attribute per CALL SITE, not per function. "`fmt` is 40% of runtime" is much less useful
   than "40% of runtime is `fmt`, called from `render`".
4. Print the top 3 at exit, one line each, not a wall. Automatic feedback that is a wall is
   feedback people turn off — and the quote's whole force is that it stays on.
5. A `zebra profile <file>` subcommand: build, run, report, no flag to remember.

*Static — no run required, and available in `-c`*
6. Cost estimates from structure alone: loop nesting depth, allocations inside loops, string
   `+` inside loops. The compiler knows all of it at emit time.
7. **Code-size attribution**: which functions generated the most Zig. Free, deterministic,
   and a decent proxy nobody has looked at.
8. Report what the compiler DID to the code — TCO applied here, `^T` auto-boxed there, a copy
   inserted, dynamic dispatch not devirtualised. This teaches the cost model rather than just
   reporting a number, and it is pure UNGIT: the compiler knows and does not say.

*Contracts, which is Zebra's own heritage*
9. `@cost(allocs=0)` as a compile-time or run-time obligation, in the same family as
   `require`/`ensure`. A performance property that FAILS rather than being merely reported.
10. Budget regression: record a program's profile, fail when it moves — `output_sweep`'s
    golden-baseline argument applied to cost instead of behaviour.

*Delivery*
11. Cost shown inline in diagnostics, on the source line, where the reader already is.
12. Differential profiling between two runs ("what got slower"), which is the question people
    actually have.
13. Fold in the existing `memStats` so allocation and time are one report, not two.

### The honest objections

- **On-by-default instrumentation changes what you measure.** Sampling (2) or emit-time
  static reports (6-8) dodge this; naive wrapping does not.
- **A default that is noisy gets disabled**, which loses the argument entirely. Whatever
  ships must be small enough to leave on — hence (4).
- **This repo has no gate that measures TIME**, and CLAUDE.md is emphatic that timings here
  swing 2x on identical binaries. Any cost feature that we gate must be gated on
  DETERMINISTIC counts (allocations, call counts, emitted bytes), never on nanoseconds.

That last one is the real design constraint, and it points at the static directions (6-8)
being the ones that can actually be gated.

## Pre-1.0 blockers (the road to 0.9 / 1.0)

> **AUDITED 2026-07-28 — the list was longer than the work.** Every item was checked
> against reality. Of 8 entries, 3 were already complete, and of the 5 that read as
> open:
> - **1 is a real blocker, and more serious than it was labelled** — BUG-221 (module
>   init is not transitive) was recorded as "harmless today"; it is a live segfault.
> - **1 is the milestone act itself** (§15) — not work, the promise to freeze.
> - **1 is explicitly NOT a blocker by its own text** — §28a, which records Sean's
>   2026-07-23 framing verbatim: *"NOT a 1.0/1.5 gate … Doesn't block anything."* It
>   was sitting in the blocker list anyway.
> - **1 had a stale premise** — §19.5d claims 5–10 min; measured 163–180 s.
> - **1 is 1.5 groundwork by its own description** — §28e exists to ground the *1.5*
>   `str_view` design. Left in place pending Sean's call rather than moved unilaterally.
> - **1 was already resolved months ago** — BUG-174, closed 2026-07-28.
>
> **So the honest road to 1.0 is one technical bug plus the freeze**, not five open
> items. A stale blocker is not free: it makes the distance look longer than it is and
> invites re-litigating decisions already shipped.


## HARDENING PROGRAMME — adopted 2026-07-30, ahead of 0.9

**Sean's framing, verbatim (2026-07-30):** *"I'd much rather a system that has no
surprises for anyone (or as little as possible) rather than more new features (not that
I don't want features!)"* — and **0.9 may slip as far as needed** to buy real quality
information. That reorders the queue: the items below come BEFORE the 0.9 ship.

Full reasoning, including what we deliberately do NOT copy from SQLite and why, is in
**`docs/testing_strategy.md`**. Summary of the ranked plan:

- [x] **A1 — bug-fixture gate. DONE 2026-07-30.** Every FIXED `BUG-NNN` must be pinned by
  a test that actually RUNS. `tools/bug_fixture_check.py`, gated in the QUICK tier and
  falsified in `gate_selfcheck.sh`. **First measurement: 175 fixed bugs, only 64 pinned by
  a test that runs, 104 with no fixture, 7 with a fixture nothing executes.** Debt is
  baselined (111) so the gate fails on NEW debt only; the count prints every run so it
  cannot become invisible. "Exercised" deliberately includes fixtures driven by another
  tool or imported by a registered test — a gate that cries wolf gets switched off.
- [x] **A4 — OOM policy. DONE 2026-07-30.** `unreachable` is **undefined behaviour** in
  ReleaseFast.

  > **Correction, same day (and it matters for how urgent this was).** The commit message
  > and the first version of this entry said "`zebra --release` builds with
  > `-OReleaseFast`, so OOM in a user's shipped program was UB." **That was wrong**, found
  > while scoping the contracts pilot. `--release` switches to LLVM but never passes an
  > optimize flag on the exe-producing path, so it builds **Debug** — see **BUG-228**.
  > `-OReleaseFast` is reached only by the **node-addon** build and by a `-fno-emit-bin`
  > check that produces no binary.
  >
  > So the exposure was: node addons (real), and anyone taking `--emit-zig` output and
  > building it themselves with `-OReleaseFast` (a documented workflow) — **not** ordinary
  > `--release` users. Narrower than claimed.
  >
  > The fix stands, and the ORDER turns out to be load-bearing: fixing BUG-228 by adding
  > `-OReleaseFast` would have switched on every `unreachable`-is-UB site at once. Doing
  > A4 first means that flag can now be added safely. A4 is BUG-228's prerequisite. **21 allocation
  sites fixed** (20 emit sites in `CodeGen.zbr` + 1 in `stdlib_preamble.zig`) to
  `catch @panic("OOM")`, which aborts cleanly with a message in every build mode and is
  already what ~148 sibling sites do. Verified end-to-end: an emitted user program now
  carries `allocUpperString(...) catch @panic("OOM")`.

  **Why no gate could ever have caught this, which is the transferable part:** every gate
  runs the DEFAULT build, and the default is Debug (self-hosted backend, no `-O`), where
  `unreachable` traps cleanly. The hazard was invisible in testing and live only in the
  artifact users distribute. Works in test, undefined in production. A static lint is the
  only possible witness → `tools/lint_oom_unreachable.py`, gated in QUICK and falsified in
  `gate_selfcheck.sh`. Two `std.fmt.bufPrint` sites keep `catch unreachable` deliberately:
  the buffer is sized exactly, so the error is impossible rather than merely unlikely, and
  the exemption list is kept narrow on purpose.

  *Build-mode note (Sean, 2026-07-30 — "whichever is fastest for our tests"): no tradeoff
  exists. The default fast backend (`-fno-llvm -fno-lld`, Debug) is both the fastest to
  compile (~6×) and the mode where `unreachable` traps. Tests are already on it.*
- [~] **A2 — behaviour differential across emit modes. TWO OF FOUR AXES DONE
  2026-07-30 (`16922ef`, `c161733`).** `tools/output_sweep.sh` gained `--mode`, comparing
  each mode against the SAME baseline rather than giving each its own — a difference IS
  the bug, which is what made it nearly free.
  - [x] **inline** (`--no-runtime-module`) — zero real differences.
  - [x] **turbo** (`--turbo`, contracts stripped) — zero real differences. Both controls
    proved first, because "no differences" is also what a silently-dropped flag produces.
  - [ ] **release** (`--release`, LLVM backend) — implemented as `--mode release` but
    **not yet run across the corpus**; also entangled with BUG-228 (`--release` does not
    currently pass an optimize flag), so run it after that lands or the result describes
    a mode that is about to change.
  - [ ] **`zebra run` vs a built exe** — not implemented. A different branch of
    `zbrToZig` (temp dir, not `--output-dir`), so it is genuinely a separate path.
- [~] **A3 — boundary-value suite, written from INTENT not recorded. FIRST PASS DONE
  2026-07-30 — four dimensions, and it found three real bugs on its first run.**
  `tools/boundary_check.sh` (QUICK tier, ~30 s, falsified in `gate_selfcheck.sh`), probes
  in `test/boundary/`, full triage in `docs/archive/boundary_triage.md`.

  **The one property that makes it not another golden baseline** is that every expectation
  was authored from QUICKSTART *before* the compiler was ever run, and that ordering is
  protected structurally: the probes and their intended output were committed in one
  commit (`603a580`) and the first run's findings in the next. If a future change authors
  an `.expected` by pasting observed output, this has become `output_sweep` with extra
  steps and should be deleted rather than kept.

  **Found (~140 assertions authored, ~130 matched intent first try):**
  - **BUG-230** (high) — `var nums: List(int) = [1, 2, 3]` does not compile. An
    annotated, non-empty list literal is emitted as Zig `const`, because the const-vs-var
    analysis does not count the literal's own GENERATED appends as mutations, so its
    initialisation then fails. Invisible to every heavy gate at once: both compilers do
    the identical wrong thing (divergence cannot see it by construction) and the
    `test/*.zbr` corpus does not use the form. **`examples/widget_smoke.zbr` DOES, and is
    shipping broken** — which surfaced a bigger hole than the bug: **no gate sweeps
    `examples/`**, the first thing a new user reads.
  - **BUG-232** (high) — argument-count checking is **skipped entirely** inside `${...}`.
    `print("${add(1)}")` is silent where `var r = add(1)` warns; the missing argument is
    zero-padded and the program prints a plausible wrong answer. This is the language's
    most common shape.
  - **BUG-231** (medium) — named arguments do not parse inside `${...}`.
  - Plus a **documentation defect**: the four `is…` predicates are ASCII-only, not
    Unicode as documented (`"é".isAlpha()` is false). QUICKSTART corrected.

  **Deliberately NOT covered, printed by the runner on every run so it cannot pass for
  coverage:** min/max int and float extremes (build-mode dependent — blocked on BUG-228,
  or the expectations pin a mode that is about to change), `s[i]` on non-ASCII (BUG-225 is
  a known wrong behaviour deferred to 1.x by §28e), `charAt` (BUG-223 is an open decision
  awaiting Sean). **Open tail CLOSED 2026-07-31** (`cf35d85` + follow-up): deep nesting and long
  identifiers both **matched intent on every row first try**; non-ASCII string
  operations found **BUG-234** — `reverse()` byte-reverses, so `"世界".reverse()` is
  invalid UTF-8 rather than `"界世"` (every multi-byte codepoint; ASCII unaffected,
  which is why nothing noticed). Suite is now **19 probes, 6 pending tripwires**. A third pass (2026-07-31) also
  reclaimed most of the integer dimension from the BUG-228 deferral — only *overflow*
  is genuinely mode-dependent — and found **BUG-236**: `/` emits `@divTrunc` while `%`
  emits `@mod`, so `(a/b)*b + (a%b) == a` is FALSE for negatives. Max/min literals,
  parsing and base conversion all matched intent first try.
  **BUG-234, BUG-236 and BUG-223 all FIXED 2026-07-31** on Sean's decisions —
  codepoint-aware `reverse()`, `%` emitting `@rem` so the division identity holds, and
  `charAt` retyped to `byte`. Both pending tripwires fired on their own when the fixes
  landed and were rewritten to assert intent; pending count 6 → 4.
  Remaining uncovered: float extremes + integer OVERFLOW only (blocked on BUG-228), and
  `s[i]` on non-ASCII (BUG-225, deferred to 1.x by §28e).
- [x] **A5 — gate `examples/`. DONE 2026-07-30.** `bash tools/full_sweep.sh --examples`, in the FULL tier, falsified in `gate_selfcheck.sh`. **First run: 18 examples — 14 pass, 2 genuinely broken, 1 harness-limited, 1 library.** It found **BUG-233** (a lambda parameter shadowing an enclosing one emits invalid Zig — `panel_smoke`) and confirmed `plugin_host` is broken by a Zig 0.16 `DynLib` stdlib change. `widget_smoke` was fixed by the BUG-230 fix and is baselined. Implemented by extending `full_sweep.sh` with a `--examples` corpus rather than adding a sixth near-identical script, so the emit → build-exe → baseline → regress-only-gate logic cannot drift from its sibling. A `DEPMISS` bucket was added because `lsystem` **runs correctly** but its search-path dependency is not emitted by `--output-dir` — a gate that libels a working file is one people learn to disbelieve. Original entry: Every heavy
  gate globs `test/*.zbr`: `compile_check`, `full_sweep`, `divergence`, `output_sweep`. The
  `examples/` directory — the first thing a person evaluating the language opens — has
  **zero coverage**, and it is already shipping something broken:
  `examples/widget_smoke.zbr` uses `var items: List(str) = ["Apple", ...]` and does not
  compile (BUG-230). Verified by emitting it and running `zig build-exe` on the result.

  **Why it went unnoticed is worth keeping:** `zebra -c examples/widget_smoke.zbr` exits
  **0**, correctly — `-c` is front-end-only by design (#4 above). So the obvious way to
  spot-check an example cannot see this class at all, and the directory is otherwise
  unswept. Both halves had to be true.

  Cheap fix: point `full_sweep`/`compile_check` at `examples/*.zbr` as a second corpus, or
  add an `examples_check.sh` on the same shape. The GUI examples need care (they scaffold
  their own build), so the honest first version may be "every non-GUI example must emit and
  compile", with the GUI ones listed as excluded rather than silently skipped. **For a 0.9
  whose whole claim is ready-for-others, this ranks near A2/A3 rather than below them.**

- [ ] **B2 spike (1 day) — is branch coverage feasible on Windows/Zig at all?** Decide
  B1-vs-B2 on evidence. One option worth the look: teaching Zebra itself to emit coverage
  counters, which would serve users too.
- [ ] **B1 — mutation testing of the compiler. HARNESS BUILT; NO VALID FULL RUN YET**
  (`tools/mutation_check.py`). Two runs published and both partly retracted on 2026-08-01:
  a 300-mutant run whose 241 "regen detections" were a CRLF bug in the harness's own
  restore path, and a 60-mutant run whose `emit_fingerprint()` searched for the
  *bootstrap's* header while running the *selfhost*, hashed a sentinel when it did not
  find it, and so returned a **constant** — filing all 47 non-detections as NO-EFFECT and
  never running `smoke` on any mutant; and a third, stopped at 43/60, whose mutation
  coordinates came from `REPO/rel` while the edits went to `wt/rel` — **two different
  files**, 18 lines apart — so it corrupted the source and scored the bootstrap's correct
  refusal as a detection. **What stands: 13 real detections** (10 A3 boundary, 3
  hello-world). **What is withdrawn: "0 survivors"** — and note the SURVIVED path has
  never executed in any run. Postmortems in `docs/testing_strategy.md` §B1 and §3b.
  Harness now refuses to start on a blind fingerprint AND verifies per-mutant that the
  text at the coordinates is what the site claimed.
  **FIRST VALID RUN 2026-08-01** (5 mutants, seed 7): 2 detected by smoke, **3 SURVIVORS**,
  0 no-effect — the SURVIVED path and `smoke` both reached for the first time, after the
  fingerprint was widened to include `selfhost/CodeGen.zbr`. Cost rose to ~370 s/mutant
  (60 mutants ≈ 6 h). Survivors and their corroboration are in
  `docs/testing_strategy.md` §B1; follow-ups are the two items directly below.
  **"Gates caught 40%" is not a coverage figure — do not quote it.** `--site FILE:LINE`
  re-runs one mutation, which is how a new test is PROVEN to kill a survivor.
- [ ] **→ SEE [`docs/archive/INSTRUMENT_PASS_PLAN.md`](docs/archive/INSTRUMENT_PASS_PLAN.md) — the ordered
  plan for "passing all the instruments" (next week's focus, agreed 2026-08-01).** It
  frames the bar correctly: green is achievable by re-baselining, so the target is that a
  NEWLY BUILT instrument finds nothing new. Highest-value item is not the survivor list —
  it is the **57 corpus files in no known category** (84 of 421 are not emit+compile
  clean; 27 are registered negatives). BUG-241 and BUG-242 were both found in exactly that
  blind spot. Order: run FULL first (cheap, may change everything), then triage the 57.
- [ ] **B1 SURVIVOR WORK — 12 named places the compiler can change with no gate noticing**
  (25 mutants over two runs, 2026-08-01). Full inventory + reasoning in
  `docs/testing_strategy.md` §B1. **Every survivor is in `CodeGen.zbr`; TypeChecker had
  five live mutations and caught all five** (four by the A3 boundary suite). Ranked:
  - [x] **(a) DONE 2026-08-01 — stdlib run coverage 11/30 → 26/30, almost entirely by
    REGISTRATION.** `tools/stdlib_run_coverage.py` is the meter. The tests already
    existed; nobody had wired them to `smoke_run`, the helper that reads what a program
    printed. smoke 267 → 281. Two tests were found broken in the process — **BUG-241**
    (`progress_test.zbr`, uncompilable since the Zig 0.16 migration) and **BUG-242**
    (`csv_test.zbr`, undeclared `CsvWriter`) — both invisible because they carried no
    smoke registration at all, and the baseline-driven sweeps cannot tell "never worked"
    from "intentionally negative".
    Four remain uncovered, each for a stated reason rather than an oversight:
    `Csv` (BUG-242), `Progress` (BUG-241), `Ws` (a server; `ws_smoke_test` does not
    terminate, so it needs a client+server fixture with a bounded wait), and `Shell`
    (the only user is `test/zebra_ide.zbr`, an IDE harness that is not a unit test).
  - [ ] **(a2) The four remaining namespaces**, in the order the blockers clear: fix
    BUG-241 and BUG-242 (then registration is a one-liner each), write a bounded
    client+server fixture for `Ws`, and a `Shell` test that does not depend on which
    utilities the host happens to have.
  - [ ] **(a3) The coverage figure is an UPPER BOUND** and should not be read as done.
    "Covered" means one run-fixture *mentions* the namespace, not that it exercises the
    emitter's branches — `genSqliteCall` has many branches and one `Sqlite.` mention. The
    honest next measurement is per-BRANCH, not per-namespace.
  - [ ] **(a-old) Original framing, kept for the reasoning:** Four survivors, each in a `gen<Thing>Call` emitter with nothing checking
    its output. Line numbers as `worktree → main`:
    - `15348 → 15366` `genWsCall` — `if mname == "serve"`; `Ws.serve` stops being
      recognised. Partial excuse: server fixtures never terminate and are excluded by
      `output_sweep`'s nondeterminism detector — a deliberate exclusion is still one.
    - `15635 → 15653` `genTerminalCall` — `var is_println = mname == "writeln"`. Mutating
      it **SWAPS `Term.write` and `Term.writeln`**, so the newline goes to the wrong one.
      The sharpest illustration in the set of why compile-checking is not enough: the
      result is perfectly valid Zig that prints on the wrong lines.
    - `15893 → ~15889` `genUriCall` — `genExpr(args.at(0).value)` → `at(1)`; `Uri.parse`
      binds the **wrong argument**.
    - `16013 → 16031` `genSqliteParams` — `et is Type_.int_ or elem is Expr.int_lit`;
      **SQLite integer parameter binding** takes the wrong branch.

    A compile check cannot see any of these — they need `smoke_run`-style fixtures with
    expected output. Worth enumerating the stdlib emitters and covering the set rather
    than just these four, since these four are only the ones randomly sampled.
  - [ ] **(b) The bare-constructor special cases are probably REDUNDANT, not untested —
    two independent witnesses now.** `11166 → 11184` (bare `HashMap()`) and `6075`
    (`isStrSetCtor`, same line in both trees) both survive `args.len == 0` → `== 1`, and **twelve corpus files use
    bare `HashMap()` without breaking**. Something downstream already handles the shape.
    **Do NOT just add a test** — that pins behaviour that may be duplicated. Find what
    handles it, then delete the branch or document why both exist.
  - [ ] **(c) Three real semantic boundaries, one fixture each.**
    `12608 → 12626` — a call whose arity EXACTLY matches a defaulted parameter list
    (`um_needs_fill = args.len < um_params!.len` → `<=` runs the fill when it should not).
    `733` (both trees) — `TypeRef.generic` rendering: `if i > 0` → `>=` makes a **generic
    type with arguments** render a leading comma, `Name(, T, U)`.
    `7524` (both trees) — the VALUE position of a string-keyed HashMap parameter
    (`if i == 1 and direct_val_str` → `i == 0` counts the key position twice).
  - [ ] **(d) `330` / `341` (same in both trees) — AstBuilder-only predicates the corpus
    never compiles.**
    Lowest priority; check whether they are dead before writing anything.
  - [x] **CLOSED: `9714 → 9720`**, the one-element inferred list literal —
    `test/boundary/bv_list_literal_inferred.zbr`, and `--site` verified it turns the
    mutant from SURVIVED to DETECTED.
- [ ] **B1 v2 — a design change, not more samples.** The cost that matters is **per LIVE
  mutant (~310 s)**, not per mutant. Two fixes: (a) sample until N *live* mutants rather
  than N total; (b) bias site selection toward code the corpus demonstrably executes, or
  toward rarely-taken branches (error paths, fallbacks) — uniform selection over
  CodeGen's ~3,559 sites spends four fifths of its budget on dead code; and (c) **widen
  the emit fingerprint** — it covers 3 canaries today, which is too narrow to support the
  word "unreachable"; regenerating `selfhost/*.zig` with the mutated compiler (22 s)
  would fingerprint the largest Zebra program we have. ~100 live mutants
  ≈ 8.6 h at today's hit rate; the fixes should cut that substantially.
- [ ] **C tier, post-0.9** — mutation fuzzing of valid programs (dbsqlfuzz's actual
  trick; gramgen *generates*, nothing *mutates*), periodic sanitizer sweeps, a release
  checklist. **C2 (contracts) PILOTED 2026-07-30 (`2f377c0`)** — feasibility proven
  (compiler rebuilt itself with contracts live on its own parser; they survive regen;
  QUICK 9/9), **zero bugs found**, cost ~15–20% on smoke with contracts on. The null
  result is the finding: I chose clauses I was *certain* held, which guaranteed it.
  **A contract you are certain holds is documentation; one you are only fairly sure holds
  is a test.** Next aim is TypeChecker (129 defs, zero contracts, and the phase whose
  wrong beliefs produced BUG-215/218/222/223), not more of the Parser. Detail in
  `docs/testing_strategy.md`.

**Known and not addressed by any of this: no gate clicks a GUI.** Doing it properly needs
per-target-OS build and test infrastructure Sean does not have available (his call,
2026-07-30). Six green gates once sat on top of three real GUI crashes; that remains a
human job and should not be papered over by how thorough the rest looks.

**Supporting infrastructure landed 2026-07-29/30 (see `docs/testing_strategy.md` §2):**
`tools/output_sweep.sh` — THE BEHAVIOUR GATE. Every other heavy gate asks "does the
emitted Zig compile?"; none of them ran anything, so valid Zig producing WRONG OUTPUT was
invisible to all of them (BUG-226). 327 corpus programs golden-baselined; nondeterminism
is DERIVED (3 samples + volatile-field normalisation), never hand-listed.

---

- [ ] **§28a step 4 — inference-or-error language flip (selfhost).** Phase 1 (measure)
  DONE 2026-07-15: instrumented the 3 selfhost guess sites; 80 unique sites but ~0 genuine
  ambiguity — the gap is selfhost *inference strength*, not a flip. **Step 2 open: close the
  ~5–8 inference root causes** (`.len`→int, arith-of-prims→prim, call-return propagation,
  user-class field typing; overlaps §24e), re-measure toward 0, THEN flip. Bootstrap corpus
  stays at 0 (`check_inference_guess.sh`), so the user-facing guarantee already holds. Gated,
  supervised. Also surfaced BUG-181 (selfhost can't self-compile `main.zbr`). → *Open detail §28a.*
  **Framing (Sean 2026-07-23): NOT a 1.0/1.5 gate — an INCREMENTAL thread.** Each inference
  root cause is independent and shippable, so §28a rides as a series of post-1.0 point
  releases (1.0.x), each gated. Doesn't block anything; the bootstrap witness holds the line
  meanwhile. A thread to pull on for a while, not a milestone.
- [x] **SIMD data bridge (BUG-197) — `f32x8` usable on real data. Tiers 1+2 DONE 2026-07-18.**
  Found by the 2026-07-17 Greek-NT dogfood. **Tier 1 `.toFloat32()`** (commit `ac48cbe`) and
  **Tier 2 `List(float32)`/`List(f32)`** (commit `015e8c3`) landed, gated. Payoff delivered: the
  SIMD-vs-scalar all-pairs cosine on the Greek vectors runs at **~7.8×** (f32x8 0.39 ms vs scalar
  3.03 ms, ReleaseFast), identical results, exact clustering. **Tier 2 was a selfhost-lags-bootstrap
  convergence** (the bootstrap already accepted `List(float32)`).
  - [x] **Ergonomic follow-ups DONE 2026-07-18** (commits `ee69570`, `ce12e9f`, all gated):
    un-annotated `var v = f32x8(…)` now dispatches `.sum()`/`.dot()` (SIMD-ctor inference — another
    selfhost→bootstrap convergence); `f32.toFloat()` widens via `@floatCast` instead of
    `@floatFromInt`; short type names `f32`/`i32`/`u8`/… map in `typeFromName` so `List(f32)` is
    inference-consistent with `List(float32)`.
  - [x] **Tier 3 DONE 2026-07-18** (commit `736a7d6`) — `f32x8.load(list, offset)` on Sean's
    approved API: `f32x8.load(WF, o)` → `(WF).items[@as(usize,@intCast(o))..][0..8].*`; 1-arg
    `.load(slice)` (offset 0) unchanged. Benchmark rewritten to it — byte-identical, four one-line
    loads for four eight-arg constructors. **All three SIMD-data-bridge tiers complete; BUG-197
    fully resolved.**
- [ ] **§28e — STRING LAYER COHERENCE (scope expanded 2026-07-29; parts 1 and 3 DONE,
  part 2 awaiting one API call).** Was "a borrows-vs-owns doc table"; now the one pass
  that makes Zebra's string layer tell the truth, so strings are touched once before 0.9
  rather than three times. Three parts:

  1. **The ownership table** — **DONE 2026-07-29** (`a0a8664`). `docs/design/str_ownership.md`,
     28 operations, **derived from real compiler emit** by
     `tools/str_ownership_extract.py` rather than read off `genStdlibMethod`; every row
     carries the emitted Zig it was classified from. Gated via `--check` in the QUICK
     tier plus `gate_selfcheck.sh`, so it cannot drift from the compiler silently.
     The classifier asserts six known-opposite CONTROLS before printing and refuses to
     emit a table it cannot vouch for — which caught three defects in itself during
     development.

     **The substantive finding, which grounds the 1.5 `str_view` design better than a
     plain table would have:** ownership is not one property but two.
     `split`/`lines`/`tokenize` return an **owned container of borrowed elements** — a
     `List(str)` the caller owns whose elements are subslices of the receiver. Under the
     program arena that is invisible; inside an `allocate` scope that owns the receiver
     it is a use-after-free wearing an owned wrapper. Holding the container is not
     enough; the receiver's lifetime is what governs. Documented in QUICKSTART with the
     wrong/right pair.

     Also surfaced and fixed en route: **BUG-224**, `format()` with 2+ arguments emitted
     invalid Zig (one `.{ }` tuple per argument instead of one tuple). Every existing
     call in the corpus passes exactly one argument, which is why no gate caught it.
  2. **Byte-vs-codepoint honesty.** `char` STAYS — Sean's call after review, and the
     data backs it: 559 `c'x'` literals, and the compiler's own lexer is built on
     `branch c on c'a'..c'z'` range matching, so it is the opposite of islanded.
     Removing it would be a 559-site rewrite to buy one fewer type. What is wrong is
     the PRETENSE that byte indexing yields codepoints:

     | | actually is | typed as |
     |---|---|---|
     | `s[i]` / `Lexer.peek()` | byte, widened to u21 | `char` |
     | `charAt(i)` | `u8` | `str` ← BUG-223 |
     | `chars()` | real UTF-8 decode | `char` ✓ |

     Only the third is honest. Adopt Go's model explicitly — `str` is bytes, `char`
     is the decoded codepoint — and make the byte-oriented accessors SAY byte.

     **Measured 2026-07-29, and the two rows have wildly different costs — they should
     be decided separately, not as one "fix the string types" item:**

     * `charAt(i)` → **BUG-223, free.** It is not merely mistyped, it is *unusable*:
       every way of consuming the result is a compile error (`print` → "expected type
       'str', found 'u8'"; `.concat` → "no field or member function named 'concat' in
       'u8'"). `grep -rn '\.charAt(' --include='*.zbr'` over the whole repo returns
       **zero callers**, and it is absent from QUICKSTART. Retyping to `byte` cannot
       regress a caller because no caller can compile, and `byte` already exists.
     * `s[i]` → **BUG-225, expensive.** Typed `char`, holds a raw byte, so it is
       *silently wrong* for non-ASCII: `"eéx"[1].toString()` prints `Ã`. The selfhost
       lexer is built on it (`Lexer.zbr:116` `def peek(): char` → `src[pos]`; ~60
       subscript sites in that file, ~104 across `selfhost/`), and the 559 `c'x'`
       literals compare against the result — so retyping requires deciding `byte`/`char`
       comparison rules. That is language design competing directly with the pre-0.9
       churn freeze.

     **Recommended split: fix BUG-223 now, document BUG-225 for 0.9 and retype in 1.x.**
     Go and Rust both expose a byte layer and neither pretends an index yields a
     character; documenting the limit is most of the value and none of the churn.
     BUG-223 is worth doing regardless of BUG-225, because it leaves users an *honest*
     byte accessor, which `s[i]` currently is not.
  3. **State the ceiling in QUICKSTART** — **DONE 2026-07-29.** A codepoint is not a
     user-perceived character: `é` can be two codepoints, emoji families are many. Swift
     made `Character` a grapheme cluster for exactly this reason; Rust and Go chose
     codepoint and documented the limit. Zebra chooses codepoint, so the limit belongs in
     the docs rather than being discovered by whoever first calls `.chars()` on an emoji.
     QUICKSTART now has a "Bytes, codepoints, and graphemes" section stating the Go
     model, the grapheme ceiling, and that grapheme segmentation is *not* provided —
     plus the BUG-225 gap with the "index for bytes, iterate for characters" guidance.

  **BUG-223 (`charAt` → `byte`) is the one open decision in §28e** — a user-facing API
  change, so it waits on Sean rather than being slid in. Everything else in the pass is
  landed. → *Open detail §28e.*
- [x] **§28f — generic `Set(T)` DONE (2026-07-24).** Distinct `Type_.set_` variant
  emitting `AutoHashMap(T, void)` / `StringHashMap(void)` (str). API: `add`/`contains`/
  `remove`/`len`/`count`/`items`→`List(T)`/`clear`, `for x in set`, `x in set`. Works as
  local/param(by-ptr)/field/return/nested `List(Set(int))`. **Selfhost-only** (bootstrap
  sunsets; the compiler's own source never uses Set, so round-trip holds). Decisions taken:
  str specialized (content-hash), `items()`→`List(T)`, StrSet stays internal. Limits (=HashMap):
  T must be auto-hashable; no `==`/`print(set)`. **Collection literals also DONE** —
  `{a, b, c}`→`Set(T)` (new `Expr.set_lit`) and `{k: v, ...}`→`HashMap(K,V)`
  (`Expr.dict_lit`, disambiguated by `:`); `{}`→empty dict (annotate or error). (Set
  literals root-caused a nasty TCO fall-through hang — see [[project_tco_fallthrough_hazard]];
  dict literals went smoothly since that plumbing was already safe.) Tests: `set_basic_test`,
  `set_advanced_test`, `set_literal_test`, `dict_literal_test` (all smoke-gated). → detail §28f.
- [x] **BUG-174 — `str.indexOf` signature design call. CLOSED 2026-07-28 — it was
  already resolved, just never closed.** Both compilers and the docs now agree on a
  mixed convention: `indexOf`/`lastIndexOf` return `int` with a `-1` sentinel (so
  arithmetic like `indexOf(x) + 1` stays natural — the reason BUG-181 moved the
  selfhost off `int?`), while `indexOfFrom`/`indexOfIgnoreCase` return `int?`.
  Verified by running the same program through both compilers: identical output on
  all four methods, hit and miss. **Was sitting in the pre-1.0 blocker list as an
  open decision that no longer needed deciding.**
- [x] **BUG-221 — module init is not TRANSITIVE. CLOSED 2026-07-29, both emission
  paths.** A three-module program whose deepest module touched a file segfaulted at
  `0xffffffffffffffff` (Zig's `0xaaaa…` poison in the trace) because the entry point
  initialised DIRECT deps only. Fixed on the runtime-module path when that became the
  default (`ade34cf`), then on the inline path — still reached by `--no-runtime-module`
  and the fallback for `--single-file`/node-addon/GUI — the next day (`7e5fb72`), where
  it was still live rather than latent. Same cause both times, same fix: sweep the
  TRANSITIVE dep list instead of direct `use` decls. Gated in both shapes by
  `tools/runtime_module_check.sh`.

  **This was "the one genuine technical blocker left on this list" per the 2026-07-28
  audit. With it closed, nothing on this list is a technical blocker:** §28a is
  explicitly not a 1.0 gate (Sean, 2026-07-23), §28e is documentation that grounds a
  *1.5* design, §19.5d had a stale premise and is an optimisation. **What remains
  between here and 1.0 is §15 — the freeze itself.** That is a decision to make, not
  work to do, and it is Sean's.
- [ ] **§15 — 1.0 stability lock + final CHANGELOG pass. SEQUENCE DECIDED 2026-07-29:
  §28e + docs polish → ship 0.9 public → freeze 1.0 on evidence.** Not a straight freeze:
  the public release is 0.9 (ready-for-others), and it should read as finished when it
  lands, so the `str` ownership table (§28e) and a documentation pass come FIRST.
  Freezing 1.0 before anyone outside has compiled a line would spend the stability
  commitment against a corpus of 335 files instead of against real use. The milestone
  act itself:
  everything below the line is delivered; 1.0 is the promise to freeze it. → *Open
  detail §15.*
- [ ] **§19.5d — `bootstrap_check.sh` latency. NOT A BLOCKER; premise was stale.**
  The §19.5d note says "5–10 min observed". Measured 2026-07-28 via the new per-gate
  timing in `tools/gates.sh`: **163–180 s** (~3 min), roughly half the recorded figure.
  It is an optimisation, not a correctness gate, and nothing about 1.0 depends on it.
  Moved off the blocker list in spirit — left here only until someone re-files it under
  tooling.

## Compiler hardening (gated; unattended-safe — deterministic, round-trip-checked)

- [x] **BUG-220 — user function names could collide with preamble internals. FIXED 2026-07-28.**
  Zig forbids a parameter shadowing a file-scope declaration, and top-level `def`s emit at file
  scope, so a user function collided with any of the preamble's 423 non-underscore identifiers:
  `count`, `data`, `total`, `buf`, `body`, `color` — 15 of 16 everyday names tested — failed to
  compile, with the error pointing into preamble source the user never wrote. Top-level defs now
  take the reserved `_zbr_fn_` prefix, finishing the half of BUG-137 (`_zbr_mv_` for module vars)
  that was never done. Selfhost-only; gate `test/toplevel_name_collision_test.zbr`. Residual:
  `@export`/`@node_export` keep their names (the ABI symbol IS the name) — closed only by the
  namespaced-emission design (§ docs/design/single_file_emit_design.md 1a).
- [x] **BUG-219 — `sys.run` deadlock. FIXED 2026-07-28.** Sequential pipe drain (stdout to EOF,
  then stderr) deadlocked whenever a child filled its stderr buffer — which made `zebra -c` hang
  precisely when a program had errors to report, and that is what the IDE's Check button runs.
  Now delegates to `std.process.run` (concurrent drain via `Io.File.MultiReader`). 4 min → 1.09 s,
  verified against 29.5 KB of child stderr. Same family as BUG-208's noted follow-ups.

- [ ] **Selfhost↔bootstrap divergence burn-down** (`tools/divergence_check.sh`,
  `docs/archive/divergence_audit.md`). New harness (2026-07-18) catches drift the other gates
  can't (they all emit with one compiler). First run: 272 agree-pass, **19 → 17 selfhost
  gaps** after the Build fix (`e5f34d8`). Every remaining gap has a known-good bootstrap
  emit to diff against — a `diff bootstrap-emit vs selfhost-emit → converge` workflow.
  - [x] **All selfhost gaps closed (2026-07-22).** 17 emit-compile D-clusters + the final 3
    post-BUG-181 (string_methods/expressiveness_test/throws_autoprop_test). Every fix diffed
    against the known-good bootstrap emit and gated.
  - [x] **Root fix — unify the stdlib-namespace list (DONE 2026-07-23, `0b11d83`).**
    Extracted `CgHelpers.isStdlibNs` as the single source both `Resolver.isBuiltin` and
    `CodeGen.isStdlibNamespace` consult — the Build-bug drift class can no longer recur.
    Behavior-preserving; all 5 gates green.
  - [x] **GATED (2026-07-22).** `bash tools/divergence_check.sh --gate` exits 1 on any selfhost
    gap; baselined 0. Documented in CLAUDE.md verification-gates. Per-session/pre-release (heavy).
  - Note: **14 BOOTSTRAP gaps** = selfhost LEADS; no fix needed (bootstrap sunsets).
    Full 5-family root-cause triage under "Bootstrap-lags-selfhost convergence" below
    (2026-07-22): pointer/value, `.items`-on-non-list, inference, parser/SIMD, sqlite-binding.
- [x] **GUI builds via selfhost emission (TUI) — DONE 2026-07-26.** `--gui-backend=tui`
  now emits the tui backend and scaffolds/builds the `zig build` project via the
  **selfhost itself** (commits `61a3ffa` Phase 1, `bbc7845` Phase 2, `3ef1e8e` example
  cleanup) — no more bootstrap delegation. Dissolves BUG-204 + BUG-206 for the tui path
  (proven: `examples/tears_of_the_tuon.zbr` builds via `--gui-backend=tui` with all
  workarounds removed). Mechanism: `selfhost/gui_tui_section.zig` (tui backend, read at
  runtime) + `CodeGen.guiSelectPreamble` (substitutes it for the stub section) +
  `main.compileGuiTui` (scaffold + `zig build --build-file` w/ inherited stdio). Gated:
  stub emit byte-identical, bootstrap_check byte-identical, smoke 254/254.
  **libui_ng also ported (2026-07-26, commit `af4d0f3`) AND now works end-to-end
  (2026-07-27).** Same generalized path (`compileGuiProject(zig_path, mode_run, backend)`
  + `gui_libui_ng_section.zig` + `luiBuildZig/Zon`). The former blocker — the upstream
  `zig-libui-ng` dep not compiling under Zig 0.16 (`ui.h` `uiRect` undefined) — is
  resolved by pointing the binding at Sean's consolidated forks:
  `torial/zig-libui-ng@main` (wp base + zig-0.16's sci/scintilla, Zig-0.16 fixes:
  `@intFromBool` on c_int setters, `Separator` alias, 5-arg `OnToggled`) which in turn
  pins `torial/libui-ng@main` (carries the vendored `uiRect` struct from petabyt/libui-dev).
  Both forks consolidated to a single `main` (stale branches deleted, defaults set).
  **Proven portable:** `examples/tears_of_the_tuon.zbr` compiles + links `app.exe` via
  `--gui-backend=libui_ng` from a **cold global cache** (both deps fetched fresh from
  GitHub). The *proven* part is compile + link (the emitted `app.exe` is produced); only
  the `run` step fails — the exe won't launch in this non-interactive shell (exit 57 under
  `zig build run`, 127 when invoked directly from git-bash). Not diagnosed to a root cause;
  most plausibly the lack of an interactive Windows display/session, NOT a build problem.
  Needs a manual interactive run to confirm the window actually shows. Also fixed a latent
  `compileGuiProject` bug: it wrote `build.zig`/`build.zig.zon` only when absent, so a
  stale scaffold silently kept an old dependency pin — now rewritten unconditionally.
  **RUNTIME-VERIFIED 2026-07-27:** counter (`+`/`−`/reset work), the game
  (difficulty screen renders), and — after porting the `CodeEditor` builtin to the
  selfhost — a single Scintilla editor (`examples/editor_min.zbr`: renders + displays
  its `setText` content, Sean-confirmed). See `docs/archive/libui_ng_audit.md` for the full
  claims-vs-verified ledger.
  **IDE: BUG-214 FIXED 2026-07-27 — next step is ONE INTERACTIVE RUN (Sean).**
  The IDE compiles + links + **renders** via `--gui-backend=libui_ng` (all compile gaps
  closed: CodeEditor port `b42074a`, BUG-211 `using`-usage `33571e5`, BUG-213 `SysProcess`
  dispatch `1895d79`), and the click-crash is fixed: BUG-214 emitted a no-payload
  `union(enum)` `Msg` variant as a bare **tag** (`Msg.list_targets`, 1 byte) instead of
  `Msg{ .variant = {} }` (the full union), so the type-erased MVU `g.send(anytype)` copy
  size-mismatched. Fixed selfhost-side, narrowly (only the `send`-on-`Gui` argument
  position — a blanket rewrite is illegal Zig for `==` and would force a bootstrap-parity
  diff; see BUGS.md). All 11 bare IDE sends now convert; new runtime gate
  `test/mvu_mixed_union_test.zbr` (reproduces under the **stub** backend, no display
  needed) is in the smoke suite. Gates green: round-trip byte-identical, smoke 255/255,
  compile_check 215/0/1, divergence 0 selfhost gaps.
  **INTERACTIVE RESULT (Sean, 2026-07-27): THE IDE IS NOW CLICK-STABLE.** Final word after
  the second pass: *"All crashing behavior w/ those buttons is gone."* BUG-214 confirmed
  (buttons dispatch), and the two crashes it had been masking — BUG-215 and BUG-217 —
  are fixed and confirmed in the same session. Nothing ever dispatched before BUG-214, so
  neither downstream crash could have been seen until it was fixed:
  - **BUG-215 (FIXED + confirmed)** — `Check` and `List Targets` aborted: the IDE called
    `str.indexOf(sub, from)`, which is not a real signature (`indexOfFrom` is), and both
    compilers silently dropped the offset → `substring(start > end)` panic. Fixed in the
    IDE *and* guarded in codegen so it cannot recur silently.
  - **BUG-217 (FIXED + confirmed)** — `Build` segfaulted: `SCI_SETTEXT`
    **ignores** the length it is given and calls `strlen()` on the pointer
    (`scintilla/src/Editor.cxx:6190`), but `_code_editor_set_text` used
    `_allocator.dupe`, which produces no terminator. `setText("")` — the first thing
    `Msg.build_start` does — passes a zero-length slice whose `.ptr` is not readable at
    all, hence `Segmentation fault at address 0xffffffffffffffff`. `_CodeEditor` now
    maintains `buf[len] == 0` as an invariant; also fixed a latent one-byte overflow on
    the `SCI_GETTEXTRANGE` read path. **Method note:** the stack trace settled this in
    one round after three hypotheses died guessing — including this one, dismissed
    because the *binding* takes an explicit length (it does, then discards it at the C
    boundary). For any future GUI crash, get `… > log 2>&1` + the top 40 lines FIRST.
  **ALL IDE UNKNOWNS NOW CLOSED (2026-07-27).** The four Scintilla editors **do**
  coexist in one window, and editability behaves exactly as authored: typing works in
  `m.editor`, while the three panes given `setReadOnly(true)` in `ideInit`
  (diag/output/buildOutput) correctly reject input — Sean confirmed the one-editable-
  pane behavior and correctly attributed it to read-only mode. `examples/editor_min.zbr`
  was also re-run post-BUG-217, re-earning the marker it held under the buggy code.
  **The IDE is END-TO-END RUN-VERIFIED**: builds, links, renders, dispatches, survives
  every toolbar button, and hosts four coexisting Scintilla controls.
  **What remains is UNBUILT, not broken** — syntax highlighting (`forZebra` falls back
  to plain; no lexer wired), `setErrorMarkers` (no-op stub), the column half of
  `setCursorPosition`, and any Table/Tree widget for a file explorer. Those are the
  next IDE features whenever the IDE comes back up the queue.
  NOTE: use `bash tools/bootstrap_check.sh --update` DIRECTLY to
  regen after `.zbr` edits — `zig build update-selfhost` silently skips (BUG-210).
  **Housekeeping surfaced by BUG-214:** the checked-in `examples/*.zig` artifacts are
  stale — regenerating `examples/counter.zig` produced ~1400 lines of pre-existing
  preamble drift on top of the 3 lines BUG-214 actually changed, so it was left alone
  rather than burying the fix. Regenerate the `examples/` artifacts as a standalone
  cleanup commit (or decide they should be gitignored like `selfhost/*.zig` is not).
  **Remaining (follow-ups, not blocking):** (a) `compileGuiProject` copies only the root
  emitted `.zig` — multi-module GUI apps still need dep `.zig` files copied into the
  scaffold (single-file / no-dep GUI apps like the game work now; residual "GUI
  module-resolution" limit). (b) **only glfw** still delegates to the bootstrap (same recipe
  to port when wanted: extract its arm from `src/CodeGen.zig`, add a section file +
  build template + backend name to `gui_selfhost`). (c) `--gui-backend=stub` explicit still
  delegates (plain `zebra run` already emits stub via the selfhost).
- [ ] ~~**GUI builds via selfhost emission — phase the bootstrap out of the GUI path**~~
  (epic; scoped 2026-07-25, scoped TUI-only). Today
  `--gui-backend=*` delegates the WHOLE build to `zebra-bootstrap.exe`, so bootstrap-lags-
  selfhost gaps BLOCK GUI/TUI apps even though the primary/selfhost compiler accepts the code —
  found porting `examples/tears_of_the_tuon.zbr` (BUG-204 return-position `except`, BUG-206
  `.toInt()`-on-float, GUI module-resolution all bite here). **Payoff: dissolves BUG-204 +
  BUG-206 + GUI module-resolution at once**, phases the bootstrap out of the GUI path (endgame).
  **Decision (Sean 2026-07-25): the right fix; do NOT do bootstrap grammar surgery for BUG-204.
  Scope TUI-only (defer imgui/libui_ng). Mechanical copy into the selfhost — do NOT refactor the
  sunsetting bootstrap (its GUI copy dies with it). Do it as a fresh, gated, phased effort.**
  - **Corrected scope (was mis-estimated as ~160 lines / "focused session"):** ~500 lines
    TUI-only, ~2000 all-backends. The scaffold driver was only half. **The real work + risk:**
    the selfhost gets its GUI backend from the preamble file UNCONDITIONALLY (always **stub** —
    `selfhost/stdlib_preamble.zig`, `_gui_active_backend` between the STDLIB_PREAMBLE_GUI markers;
    the selfhost reads the whole file, the bootstrap keeps the section inline in CodeGen with a
    `switch(gui_backend)`). To emit tui *instead*, stub must become codegen-**selected** — split
    the stub block out of the shared preamble, gate on `gui_backend`. This restructures a path
    every GUI-stub test depends on: it **MUST stay byte-identical for the stub case** or
    `bootstrap_check` breaks + every GUI stub test shifts. That gate-holding restructure is the
    crux, NOT the tui glue (static strings — mechanical copy, watch CRLF/escaping in `.zbr`).
  - **Reference map (bootstrap side, to copy/mirror):** backend `switch(g.gui_backend)` =
    `src/CodeGen.zig:3061-4683` (stub 3062-3234, imgui ~3234-3835, **tui 3841-4114**, libui
    4124-4683; each arm ends `const _gui_active_backend = _gui_<x>_backend`). Scaffold =
    `compileGuiProject` `src/main.zig:1348-1417`; build.zig/.zon templates `1188-1300`
    (tui template `1254-1300`). Selfhost currently: parses `gui_backend` (`selfhost/main.zbr:2094`)
    only to delegate (`~2320`); CodeGen emits `_gui_active_backend.*` CALLS but has NO
    `gui_backend` field/param (never threaded).
  - [x] **Phase 1 DONE 2026-07-25 (commit `61a3ffa`, gated).** Threaded `gui_backend` through
    the pipeline (`main` → `setGuiBackend` → `_gui_backend` var in CodeGen, mirroring
    `setSingleFile`) and routed every preamble-append site through `guiSelectPreamble`, which
    splits on the STDLIB_PREAMBLE_GUI markers so codegen picks the backend. **Refinement vs the
    original plan:** stub stays SOURCED FROM the preamble file (split-then-reassemble = verbatim),
    NOT extracted into codegen strings — so stub is byte-identical by construction (lower risk).
    Verified: counter (GUI stub) + a plain program emit byte-identical to pre-change;
    bootstrap_check byte-identical; smoke 254/254.
  - [~] **Phase 2 — core mechanism VALIDATED 2026-07-25; delivery+scaffold+routing remain.**
    **Validated (the make-or-break unknown):** grafting the bootstrap's tui GUI section into a
    *selfhost* emit (selfhost preGui + bootstrap tui-section + selfhost postGui) COMPILES + links
    with zigzag (`zig build` exit 0). So the selfhost preamble is compatible with the bootstrap's
    tui glue; the ~20-line stub-vs-preamble divergence is confined to the GUI section (replaced
    wholesale for tui) and is irrelevant. **tui section extraction (reproducible):** emit any GUI
    program with the bootstrap twice — `zebra-bootstrap.exe --emit-zig g.zbr` (stub) and
    `--gui-backend=tui --emit-zig g.zbr` (tui); the tui GUI section = the tui emit's text from
    `// ─── GUI: backend isolation` through `const _gui_active_backend: _GuiBackend =
    _gui_tui_backend;` (~508 lines / 26 KB; contains the sole `@import("zigzag")`; no `"""`).
    **`guiSelectPreamble` tui branch (validated shape):** for `_gui_backend=="tui"`, return
    `preamble[0..siEnd] + "\n" + <tui-section> + preamble[aeEnd..]` where `si`=STDLIB_PREAMBLE_GUI_START
    marker, `ae`=`const _gui_active_backend … = _gui_stub_backend;` (ASCII-stable anchors). **NOT
    byte-identical to the bootstrap is fine** — tui isn't in the divergence corpus; it only needs
    to build+run. **Remaining:** (a) deliver the tui section — file `selfhost/gui_tui_section.zig`
    read at runtime (resolve like `preamble_path`, install next to exe in build.zig) is cleaner
    than a 508-line embed [triple-quoted `"""` works but bloats CodeGen]; (b) port the
    scaffold+zig-build driver (`compileGuiProject` `src/main.zig:1348-1417`, uses `.stdout=.inherit`
    already) + the tui build.zig/.zon templates (`src/main.zig:1254-1300`) into `selfhost/main.zbr`;
    (c) route `--gui-backend=tui` through emit-then-scaffold instead of delegating (`selfhost/main.zbr`
    ~2320). **Acceptance: `zebra --gui-backend=tui examples/tears_of_the_tuon.zbr` builds + runs the
    game WITHOUT the BUG-204/206 workarounds (revert those in the example to prove it);
    bootstrap_check + smoke green.**
- [ ] **Grow the fuzzer's `DEFAULT_CAPS`** (`fuzz/gen.py`) — highest-leverage
  correctness lever (risk surface is combinatorial; see `docs/archive/COVERAGE_MAP.md`).
  Remaining caps need class-relationship generation: (4) `^T` boxing,
  (5) interfaces + `is`, (6) generics / backed-enums / chained-cmp. → *Open detail,
  Fuzzer.*
- [ ] Grow fuzzer grammar surfaces (generics, error/throws, branch/enum); run
  `fuzz/run.py --run` batches when free RAM allows (small batches under memory
  pressure).
- [~] **Bootstrap-lags-selfhost convergence** (bootstrap is the regen authority;
  selfhost is ahead — converge only where the round-trip needs it):
  - **RECOMMENDATION (2026-07-22): do NOT chase these as a batch.** Full triage below shows
    the 14 span 5 codegen surfaces (not one bug), most triggered by escape-hatch/niche
    constructs (`zig"…"` raw literals, `f32x8`, generic-fn syntax), and all require porting
    selfhost codegen *back into the sunsetting bootstrap* — against the roadmap's "don't do
    sizable ports into the phasing-out bootstrap." Witness value is real but bounded: for all
    14 the selfhost output is already known-correct (compiles + smoke-passes), so there is no
    silent blind spot today — only a degraded reference for *future* changes in those (stable)
    areas. Fix opportunistically if one blocks the round-trip; otherwise leave until/unless
    the bootstrap's Phase-2 (single-file witness) work reopens it.
  - **Triage map — 14 bootstrap gaps → 5 root-cause families (divergence_check, 2026-07-22):**
    - **(A) pointer/value confusion (~6, dominant):** `greet`/`with_test`/`features`/
      `selfhost_probe5` emit `*T = T{}` (declared `*T`, init value); `pratt_calc`/`lambda_calc`
      the inverse (`T` vs `*T`). Trigger: explicit class-type local + `zig"T{}"` raw-literal
      init. Bootstrap's pointer-vs-value / `^T`-box decision is diffuse (no single guard) —
      this is the `^T`-boxing class the fuzzer notes flag as hard. Sizable.
    - **(B) spurious `.items` on non-list (~3):** `list_iter` (`.items` on `[]i64` slice),
      `hashmap_init_patterns_test` (`.items` on HashMap), `bug177_178_index_tostring_test`
      (nested `g.items[0][1]` — inner needs `.items`). Container-shape tracking lag.
    - **(C) inference/TC lag (~2):** `lisp` (`expected float, got Value`), `sort_test`
      (indexing empty slice).
    - **(D) parser/feature gaps — EMITFAIL (~2, deepest):** `generic_fn_test` (bootstrap
      parser: `syntax error near '('` on generic-fn syntax), `simd_test` (`f32x8` not
      defined — known niche).
    - **(E) stdlib-binding lag (~1):** `sqlite_test` (`asInt` missing on `_SqliteRow`).
  - [ ] **BUG-180 (new 2026-07-14)** — bootstrap drops omitted ctor defaults on emit
    (`Vector3()` → `Vector3.init()`); selfhost fills them. Workaround: spell ctor
    args out. → `BUGS.md`.
  - [ ] `for x in <as-bound List>` → `.items` (low value now — bootstrap phasing out; family B).
  - [ ] `zig"…"` ref-analysis (count idents used inside zig-literals; no spurious `_ = v;`).
  - [ ] Reconcile explicit `: void` parse divergence (bootstrap `.named "void"` vs
    selfhost `.void_`).
  - [ ] BUG-147 (3 bootstrap lisp-emit divergences); BUG-149 (`.len` on a local-map `fetch`).
- [ ] Audit/regenerate stale engine-style `.zig` with the converged bootstrap
  (`pathfinding.zig` was stale; others likely are); add a numeric-conversion
  compiler test; correct QUICKSTART §21.
- [x] Run full `compile_check.sh` corpus (JOBS-paced) + triage regressions. **DONE
  2026-07-16: 198 passed / 0 FAILED / 3 skipped (selfhost, JOBS=3)** — the §28a step-2
  changes introduced no emitted-Zig regressions. `compile_check` is the *independent
  witness* the round-trip lacks (round-trip diffs the selfhost against itself → blind to
  wrong-but-compiling output AND to programs it never compiles; `compile_check` runs
  `zig build-exe` on emitted corpus programs). **Recommend gating it** (per-commit or at
  least per-session) — it is currently a manual tool, so the coverage-blindness it closes
  is only closed on the days someone remembers to run it. Cost: a few min at JOBS=3.
- [ ] **⚠️ 1.0 BLOCKER — emit-compile triage campaign** → **`docs/archive/emit_compile_triage.md`**.
  > **RE-SWEPT + GATED 2026-07-24** (`docs/archive/full_sweep_triage.md`, `tools/full_sweep.sh`).
  > Full 403-file re-sweep: **328 PASS, 0 regressions, 0 NEW bugs** — every remaining
  > CFAIL/EMITFAIL is a negative test, library module, interop-needs-libs, multi-module,
  > or a KNOWN item in this campaign's backlog. Fixed 3 stale tests (removed syntax) en
  > route. The corpus is now gate-able: `full_sweep.sh --gate` fails on regression vs a
  > 328-test baseline (no skip-list needed). The codegen backlog below is unchanged — the
  > sweep confirmed the state rather than finding new work.
  A full-corpus independent-witness sweep (all 399 `test/`+`examples/` `.zbr`, not just the
  ~201 smoke-registered) found **52 standalone-compile FAILs**: ~11 negative/harness, and
  **~30 genuine codegen/type miscompiles on current constructs**, clustered into ~15–20 root
  causes (undeclared-type-not-emitted `Http`/`CsvWriter`; syntax errors in emitted Zig `json`;
  `.len`-on-ArrayList `dns`; `^T`-box `*T`-vs-`T`; BUG-182-class mis-typed-receiver dispatch;
  one GUI `param shadows 'init'` bug covering ~6 files). BUG-182 was the tip. Campaign: verify
  real-vs-stale per cluster, fix by root cause (~15–20 fixes clear ~30 files), gate
  `compile_check` over the triaged-clean corpus so it can't regrow, prune stale tests. Found
  2026-07-16 by casting the witness wider than the curated smoke set.
  - [ ] **Follow-up (D7 residual) — closure local over-marked `var`.** BUG-191 (2026-07-17, two
    rounds) made the `var`/`const` scan type-driven for value + by-value-handle receivers
    (immutable str/primitives → never `var`; json/tcp/ws/udp/sqlite/regex → `const` unless an
    explicit mutator; optional/`^T` unwrapped), killing the `never mutated` class corpus-wide.
    The ONE remaining `never mutated` (in `gui_test`) is NOT a scanMutations case: `frame` is a
    **closure** (`var frame = def(g)…`) passed by value to `Gui.run`, marked `var` by closure
    lowering because the closure body mutates a captured var — yet `frame` itself is copied into a
    heap slot and never mutated locally. Fix lives in the closure/lambda codegen (emit the closure
    temp `const` when it is only passed by value and never locally re-invoked with mutation), not
    in `scanMutations`. Low priority: 1 file, which also fails on an unrelated
    `GuiContext has no member 'run'`. NOTE: a measured corpus scan found **no** named-struct-getter
    `never mutated` case, so the earlier "per-method struct mutation map" idea is unnecessary —
    structs correctly stay on the name-based fallback.
- [ ] **§24e — single method-descriptor table** (stdlib method registration touches
  4 places). Deferred post-1.0, but §28a raised its priority (it converts four
  heuristic dispatch surfaces into one spec). → *Post-1.0 §24e.*
- [ ] **Single-file emission — codegen architecture** [Phase 1 (single-module, both compilers)
  + §7b Phase 2 (multi-module merge, **selfhost**) + Phase 4 (edge-case parity + node-addon
  hardening) LANDED 2026-07-21, behind default-off `--single-file`. **F5 closed**;
  `compile_check.sh --single-file` = 200/0/1 == multi-file baseline; round-trip byte-identical;
  smoke 236/236. **BUG-181 RESOLVED 2026-07-22 → Phase 5 UNBLOCKED** (the combined selfhost/main.zig
  now COMPILES). **Phase 5/6 DE-SCOPED (2026-07-22, `docs/design/regen_authority_decision.md`):** keep
  the bootstrap as the independent multi-file regen authority (the trusting-trust witness that
  caught BUG-181); do NOT make the selfhost sole authority, do NOT add single-file to the
  bootstrap now. Single-file stays a shipped feature (default-off), gated by
  `tools/selfcompile_check.sh`. Revisit post-1.0 (freeze bootstrap) or if the 9-file burden bites
  (then bootstrap Phase 2 is the correct route). **Feature complete for now.**]

- [x] **Convergence sweep: 3 selfhost gaps — ALL CLOSED (2026-07-22).** The post-BUG-181
  `divergence_check.sh` found 3 selfhost-lags-bootstrap gaps; all fixed + gated (200/0/1 +
  round-trip each): `string_methods` (indexOf→int, `37873e8`); `expressiveness_test`
  (named-args/defaults in user-method calls + string-repeat codegen + inference, `3fe5630`);
  `throws_autoprop_test` (try-block catch-wiring in the user-method early-exit). **Two of the three
  shared ONE root:** genMemberCall's "general user-method early-exit" (~11620) emitted args
  positionally and returned before the default path's named-arg/default AND try-block-catch handling
  — so both named-args/defaults and throws-in-try were silently wrong for user-method calls (a
  high-impact class: any program using default params, named args, or throws-in-try on a user
  method). Confirmed: `divergence_check.sh` now reports **0 selfhost gaps** (292 agree-pass · 46
  agree-fail negatives · 18 no-main libraries; 14 bootstrap-lags-selfhost gaps remain — secondary
  witness-quality item, tracked separately). Original triage below (kept):

  <details><summary>Original 2-gap triage (2026-07-22)</summary>
  - **`expressiveness_test` — named args + default params in METHOD calls.** `g.greet(name: "Alice")`
    (default `greeting`) emits `g.greet("Alice")` (1 arg, no default); reordered
    `g.greet(greeting: "Hi", name: "Carol")` emits source-order `g.greet("Hi", "Carol")`. Root: in
    genMemberCall, `mc_params` is nil because `inferExpr(g)` doesn't resolve an EXPLICITLY-typed local
    (`var g: Greeter = Greeter()`) to `named("Greeter")` (or `lookupFnParams("Greeter.greet")` is
    empty) — so neither the legacy reorder path NOR a `genArgListFull` delegation can fire. FIX =
    make the receiver's class resolve (bind explicitly-typed locals in infer_ctx / register method
    params) THEN delegate the has-named/needs-fill case to `genArgListFull` (the correct algo the
    constructor path already uses; a guarded delegation was drafted + reverted pending the inference
    fix). The bootstrap handles all of this. Connects to §28a inference.
  - **`throws_autoprop_test` — a bare `throws` call in a try-block.** `.outer()` (throws, no `?`) inside
    a method-level `catch` emits bare `self.outer();` → "error union is ignored". `.inner()?` (explicit)
    works, so throws DETECTION is fine; the try-block CATCH-wiring at genMemberCall ~12950
    (`callee_throws2 and try_block_label != nil`) doesn't fire for `.outer()` despite both conditions
    appearing set — a context bug (couldn't pin statically; needs instrumentation). The bootstrap does
    this at the STATEMENT level (src/CodeGen.zig genStmt ~6843: `e is call and try_block_label and
    exprCallIsThrows`) — mirroring that (statement-level catch) is the likely clean convergence, but
    verify it doesn't double-emit with the existing 12950 path.
  </details>
  (Resolution note: fixed instead in the user-method early-exit, which was the real path both
  gaps flowed through — see the closed entry above.)

- [x] **Grammar fuzzer (generative)** [idea Sean 2026-07-22 → BUILT 2026-07-23]. `fuzz/gramgen.py`:
  coverage-guided CFG derivation from `grammar.txt` (production choice weighted 1/(1+times_used) →
  94% production coverage over 200 programs), stateful indent/dedent renderer, plugs into the
  existing `harness.check(zig_check=False)` oracle. Complements `gen.py` (semantic) by attacking the
  front-end accept/reject space directly. **First runs paid off immediately:** found **BUG-199** (an
  18-byte selfhost parser INFINITE LOOP, `readonly struct b` — now FIXED + gated), plus lower-signal
  divergences (G2 empty-body decl leniency, G3 size-type alias resolution, G4 misc) and a dead
  grammar rule (`ValueArg*`). Findings in `fuzz/FINDINGS.md` (G-series). Note on "Earley": generation
  is CFG *derivation* (no parsing algorithm needed); Earley matters only for the inverse.
  - [ ] **Follow-ups (optional):** address G2 (selfhost accepts body-less `struct`/`extend`);
    dead-rule cleanup in `grammar.txt`; add a front-end-only oracle mode (parse/`--check` rather
    than full `--emit-zig`) so resolver/TC divergences aren't swamped by legit "undefined name"
    rejections; ~~consider gating a fixed-seed gramgen batch (assert no crashes/hangs) per
    session~~ — **DONE 2026-08-19**: `gramgen --gate` is registered in the new `--daily` tier
    of `gates.sh` (960 deterministic programs, gated on hangs and crashes only, since
    accept/reject divergences are expected). "Per session" was the right cadence to ask for
    and the wrong thing to encode: a cadence nobody can run is a paragraph. It is now a tier
    with a name.

- [ ] **`indexOf` nil-safe API (principled `int?`)** [deferred 2026-07-22, Sean's call: revisit
  during hands-on language testing]. `str.indexOf`/`lastIndexOf` currently return `int` with a `-1`
  sentinel (matches the reference bootstrap + `main.zbr` usage; the documented `int?` was never
  implemented — the codegen always emitted `i64`). The nil-safe `int?` (nil-not-found) fits the
  language's Eiffel-style **nil-tracking** pillar and is the preferred long-term shape. Doing it is
  a deliberate cross-compiler change: type `int?` + emit `?i64` in BOTH compilers, and fix
  `main.zbr`'s `indexOf(" ") + 1` (→ `!`/guard). `indexOfFrom`/`indexOfIgnoreCase` already return
  `int?` (do them too for consistency). Not incidental convergence work — its own small task.
  Emit all Zebra modules into **one** `.zig` file, each wrapped in a namespace `struct`, with
  **one** shared runtime preamble at file scope (today: one file *per module*, each inlining the
  full ~3712-line preamble). Wins: dissolves the **F5** name-collision class for free (namespaced
  user decls leave file scope, so preamble internals can't shadow them), emits the preamble once
  (the ~9-module selfhost compiles ~9 copies today), and **deletes** the cross-module
  `_initAllocator`/`_initIo`/`_zbr_error_msg` fan-out (`main.zig` hand-wires it for 8 modules).
  **Justification is architecture + F5-closure + simplification, NOT speed** — the spike measured
  the compile-time win as modest (~12 ms/preamble-copy frontend; Sema win real but unmeasurable in
  noise). Prototype compiled + ran; cross-module `use`, bare outward preamble resolution, and F5
  dissolution all verified. Real project: both emitters kept equivalent, round-trip goes
  single-artifact, phased behind a temporary `--single-file` flag. **Supervised, careful, gated.**
  → *Design + phased plan: `docs/design/single_file_emit_design.md`.* Supersedes the bespoke F5 fix.

## Environment / repo cleanup (safe, unattended)

- [ ] Prune the stale session task list to the genuinely-open few.
- [ ] **Wiki sync** — N-API, First Horseman, bootstrap convergence, the GameEngine
  boss-move layer → `project_zebra.md`; lint dates.
- [ ] Tidy scratchpad repros into `examples/` or delete.

---

# Open — detail
---

**Where things live** — this file is one of five; see [NEXT_STEPS.md](NEXT_STEPS.md)
for the map.

| file | answers |
|---|---|
| [docs/PRINCIPLES.md](docs/PRINCIPLES.md) | how do we decide? |
| [docs/archive/FINDINGS.md](docs/archive/FINDINGS.md) | what do we already know? |
| [docs/NEXT_STEPS_to_0.9.md](docs/NEXT_STEPS_to_0.9.md) | what is next, before public release? |
| [docs/NEXT_STEPS_to_1.0.md](docs/NEXT_STEPS_to_1.0.md) | what is next, before the freeze? |
| [docs/NEXT_STEPS_post_1.0.md](docs/NEXT_STEPS_post_1.0.md) | deliberately deferred past 1.0 |
