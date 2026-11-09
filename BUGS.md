<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-693. Next new bug: BUG-694.**

> **Numbering correction 2026-08-05.** Two different bugs were both filed as
> BUG-260 by sessions working in parallel. The query-param one below was filed
> first (`5717d80`) and keeps the number; the C-dependency one was filed later
> (`fcd9c7c`) and is **renumbered BUG-261**. Commit `fcd9c7c`'s message still
> says "BUG-260" — that is the record of what was written at the time and is
> left alone; look for BUG-261 in the ledgers.
>
> No gate could see this: `doc_lint` D4 only checks that a cited BUG-NNN exists
> *somewhere*, so a duplicate satisfies it twice over.

> ### FILING PRACTICE — read this before adding an entry
>
> **1. Leave the workaround in the CALLING code, with the bug number beside it.**
> A bug report says what broke. A workaround comment says what the author did
> *instead* — and that is the measurable cost of the defect, in a form nothing else
> captures. Receipt (2026-08-26): three entries in `C:/Projects/tinylm`'s Zebra sources
> — BUG-311, BUG-312 and one unfiled quirk — recorded that the author could not return a
> tuple of containers, could not share a generic `matvec` helper, and could not put
> functions in a class. Reading those three comments established in minutes that the
> code's whole shape was dictated by our defects rather than chosen, which no amount of
> reading the ledger would have shown. Prefer `# BUG-NNN: <what I had to do instead>`
> next to the distorted code.
>
> **2. A workaround also dates the defect's cost.** When the bug is fixed, the comment
> is the test: remove the workaround and see whether the natural form now works. Without
> it nobody knows which code was bent, so nobody straightens it and the tax is paid
> forever.
>
> **3. Reproduce before filing, and say so if you could not.** The same session tried to
> file that third quirk and *could not reproduce it* — top-level `def` and `static def`
> both mutated a list parameter correctly, nested `List(List(float))` included. It was
> NOT filed. An unreproducible entry costs a future reader more than a missing one, and
> "I could not reproduce this, here is exactly what I tried" is a legitimate thing to
> write in the ledger.
>
> **4. Measure both build modes for anything touching memory or arithmetic.** Every gate
> here builds Debug. BUG-313 is invisible in Debug and silently fabricates a value in
> `--release`; BUG-228 shipped Debug binaries from `--release` for four days under 19
> green gates. If an entry claims a safety property, it must say which mode it was
> measured in.

---

### DESIGN-001: Throws auto-propagation scope — nested expression calls require `?`
- **Not a bug** — by design
- **Description:** Throws auto-propagation emits `try` for direct self-method calls and statement-level calls whose receiver is a `throws` method. It does NOT auto-propagate for:
  - `localVar.method()` — receiver is a local variable
  - `this.field.method()` — chained member access through a field
  - Calls nested inside compound expressions
- **Required action:** Use explicit `?` suffix for these cases: `localVar.method()?`, `this.field.method()?`

---

### DESIGN-002: `collectAndEmitOldSnapshots` (selfhost) missing `Expr` arms
- **Status:** Fixed — `selfhost/codegen.zbr` `collectAndEmitOldSnapshots`; `test/contract_old_compound_test.zbr` covers the `array_lit` case; 31/31 smoke, bootstrap 5/5.
- **Was:** `selfhost/codegen.zbr` `collectAndEmitOldSnapshots` fell through to `else: pass` for 8 compound Expr variants. An `old expr` nested inside any of these produced an undeclared-identifier Zig compile error: the `defer` block referenced `_old_N` but no snapshot was ever emitted.
- **Confirmed failing test:** `ensure val in @[old val, n]` — `old val` inside `array_lit` — produced `error: use of undeclared identifier '_old_0'` before the fix.
- **Fixed arms added:**
  - `array_lit` — iterate `elems`, recurse each
  - `list_lit` — iterate `elems`, recurse each
  - `tuple_lit` — iterate `elems`, recurse each
  - `dict_lit` — iterate `entries`, recurse `entry.key` and `entry.value`
  - `string_interp` — iterate `parts`; recurse only `StringPart.expr_` arms
  - `type_check` — recurse into `tc.expr`
  - `slice` — recurse `sl.object`; recurse `sl.start to!` and `sl.stop_ to!` if non-nil
  - `except_` — recurse `ex.base`; recurse each `f.value` in `ex.fields`
  - `lambda` — left as no-op (correct: `old` inside a lambda body is semantically unsound)
  - Leaf nodes — left as `else: pass` (correct: can't contain `old_`)
- **Note on slice optional fields:** `ExprSlice.start: ^Expr?` uses `!= nil` + `to!` (not `if x as s`) — consistent with the existing `genExpr` slice handling in the selfhost.
- **Files:** `selfhost/codegen.zbr` (`collectAndEmitOldSnapshots`), `test/contract_old_compound_test.zbr` (new), `tools/selfhost_smoke.sh` (new smoke entry).


---

### INFRA-001: --update non-idempotence on first run after certain bootstrap states
- **Not a bug** — cosmetic only; both output forms compile and round-trip correctly
- **Symptom:** The first `bash tools/bootstrap_check.sh --update` (or `zig build update-selfhost`)
  after a full bootstrap or manual `/tmp/bs-zig` copy can produce `selfhost/*.zig` files with
  the header `// Generated by the Zebra compiler.` (bootstrap style) rather than the expected
  `// Generated by zebra-selfhost.` (selfhost style). Subsequent `--update` runs are stable and
  idempotent on the selfhost-style output.
- **What to do:** If you see bootstrap-style headers after `--update`, just run `--update` once
  more. The second run will produce the correct selfhost-style headers and stay there.
- **Root cause (partial):** `codegen.zbr` line 808 (`generateFullWithDeps`) and line 831
  (`generateDepWith`) both emit `"// Generated by zebra-selfhost.\n"`, so selfhost-A should
  always produce selfhost-style output. The first-run anomaly may be a stale `zebra-selfhost.exe`
  binary that predates step 2's rebuild, or Zig build-cache reuse in step 2 that skips the
  recompile when source timestamps haven't changed. Not fully traced.
- **Where this is also documented:** Comment in `tools/bootstrap_check.sh` update-mode header.

---


### BUG-692: a `split` passed inline as a `List(str)` argument emits the raw SplitIterator (found 2026-11-08)
- **Reported by** the GameEngine session (Fable's seat), running a control on the
  v-backend-poc worktree; **reproduced on main** (`99aa12c`'s zebra.exe), Debug, with a
  program of its own.
- **Repro:**
  ```zebra
  class Rec
      var tags: List(str)
      cue init(tags: List(str))
          this.tags = tags
  def count(xs: List(str)): int
      return xs.len()
  def main()
      var r = Rec("a*b*c".upper().split("*"))   # error at this line
      print(count("a,b".split(",")))           # and, alone, at this one
  ```
  zig: `expected type 'List(str)', found 'mem.SplitIterator(u8,.sequence)'`, at the
  call's line. Both a CONSTRUCTOR argument and a plain FUNCTION argument fail (measured
  separately: zig stops at the first).
- **Workaround:** bind it first -- `var tags = s.split("*")`, then `Rec(tags)`; that
  path collects (BUG-092).
- **The family:** BUG-092 (var init), BUG-350 (`return`), BUG-336/605 (`.at`/`.len`)
  each fixed one POSITION where a lazy `split` meets a `List(str)` slot. Argument position
  is the one left. Fix the position-independent way if there is one -- collect wherever
  the expected type is `List(str)` -- rather than a fourth site; a fifth position will
  otherwise be found the same way.
- **Control when fixing:** both lines above must build and print 3 / 2; a `for t in
  s.split(",")` must stay lazy (no collect); leakgen should generate the shape.
- **The V target** emits the inline form fine (`zstr_split` returns the box).

---

### BUG-693: `CodeEditor.sci` does not build on the default (stub) backend -- the IDE's headless tests have no backend on Zig 0.17 (found 2026-11-09)
- Found by reading zebra-ide's CI: `check` has been red against every release since rc7. Its
  three headless legs (`keys_test`, `model_test`, the `ide.zbr` compile control) pass
  `--gui-backend=tui`, which Zig 0.17 refuses -- and the refusal says to use libui_ng "or no
  flag". With no flag, `model_test.zbr` (which `use`s ide.zbr) fails inside zig on 99aa12c:
  `ide.zbr:238: error: use of undeclared identifier '_code_editor_sci'`.
- Cause: codegen lowers `ed.sci(...)` to `_code_editor_sci` / `_code_editor_sci_str`
  (CodeGen.zbr ~20175). Both GUI sections define them (the tui one as `return 0` stubs);
  the stub backend's GUI region in stdlib_preamble.zig defines the other 19 `_code_editor_*`
  helpers and not these two. `gui-surface` checks GuiContext verbs, the backend table and
  `_gui_*` helpers, not `_code_editor_*`, so nothing saw it.
- Fix: add the two stub helpers to the preamble (return 0, as the tui section did), and grow
  gui_surface_drift to require every `_code_editor_*` name CodeGen emits in all three
  regions. Then move zebra-ide's three legs off `--gui-backend=tui`.
- Control when fixing: `model_test.zbr` prints `model_test: ok` with no flag; the drift gate
  goes red with one helper deleted from the preamble. keys_test already passes with no flag.

