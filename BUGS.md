<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-668. Next new bug: BUG-669.**

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

### BUG-667: integer overflow is undefined behaviour in a `--release` build -- Debug traps it, release prints a wrong number

- **Severity:** High -- gate G1 ("safety holds at run time; there is no switch to turn it
  off"), and the failure is the quiet kind: a plausible wrong value, exit 0.
- **Status:** OPEN. Found 2026-10-29 while comparing what the Zig and V backends promise.

```zebra
def main()
    var n: int = sys.args().count()       # 1
    var x: int = 9223372036854775807
    var y: int = x + n
    print("y=${y}")
```

Debug: `panic: integer overflow`. `zebra --release`: `y=9223372036854775807` -- neither
the trap nor the wrapped value (`-9223372036854775808`): `--release` passes `-OReleaseFast`,
where Zig treats `+` overflowing as undefined behaviour, so the optimiser may assume it
never happens. The emit is a plain `const y: i64 = (x + n);` -- no Zebra helper is in the
path, so the wrong value is Zig's UB and not our runtime's. Measured with `n` printed
(`n=1`), so the addend is not a constant fold.

The same class as BUG-313 (raw indexing unchecked under ReleaseFast), which was answered
for indexing only; BUG-534 answered it for the `toInt8..toUint64` conversions. Arithmetic
was never decided -- no ledger entry, design note or finding mentions it.

**Options, for Sean:** (a) checked arithmetic emitted explicitly (`std.math.add` or `+%`
with a trap), as BUG-313 did for indexing -- the release keeps the trap and pays per
operation; (b) `--release` uses ReleaseSafe -- every Zig safety check back, at its cost;
(c) wrapping as the defined semantics -- a language decision, and the one V makes. Whatever
is chosen is also what a V backend must emit. Measured on V ee6d62a (the engine's pin),
not assumed: the same program through `--target v` WRAPS, `got=-9223372036854775808`,
under tcc and under clang `-prod` alike -- no trap on either. So (a) or (c) there too.

The G1 matrix that found this and BUG-668 (2026-10-29; five probes, each with a
run-time operand): divide by zero and index past the end trap in all four builds (Zig
Debug, Zig `--release`, V tcc, V clang `-prod`); `300.toUint8()` traps on Zig and is not
mapped by the V emitter; a nil unwrap traps in all but Zig `--release` (BUG-668); integer
overflow traps only in Zig Debug.

**Control when fixing:** the program above, both modes, and `release-mode`'s gate gaining
an overflow leg as it gained the bounds and conversion legs.

### BUG-668: a nil unwrap (`x!`) is unchecked in a `--release` build -- it reads garbage and carries on

- **Severity:** High -- gate G1, the quiet kind.
- **Status:** OPEN. Found 2026-10-29 by the G1 matrix (BUG-667's entry).

```zebra
def main()
    var s: str? = nil
    if sys.args().count() > 5
        s = "x"
    var t: str = s!
    print("got=${t.len}")
```

Debug: `panic` at the unwrap. `zebra --release`: `got=0`, exit 0. The emit is
`const t: []const u8 = s.?;` -- Zig checks `.?` in Debug and ReleaseSafe and not in
ReleaseFast, which `--release` passes: BUG-313's class again, for the non-nil assertion.
The V backend's release lane TRAPS here (`V panic: nil unwrapped at g1_nil.zbr:5`, clang
`-prod`), because CodeGenV routes every narrowed read through `zunwrap_at` -- the shape the
Zig side's fix can copy: an explicit check that names the place, as BUG-313 did for `.at()`.

**Control when fixing:** the program above in both modes; `release-mode` gains the leg.

---

### BUG-289: two deterministic programs disagreed with themselves inside a full output_sweep — cause unknown

**Found 2026-08-15** during an `output_sweep --update-baseline`. `log_test` and
`refinement_type_test` were auto-excluded as nondeterministic and so dropped out
of behaviour coverage. Both are deterministic:

| check | result |
|---|---|
| built executable, 10 consecutive runs (`refinement_type_test`) | byte-identical, 12 bytes, rc=0 |
| built executable, 8 consecutive runs (`log_test`) | byte-identical, 178 bytes |
| through the harness's own `--show --only` path, 5 runs | byte-identical |

The disagreement appears **only** inside a full 354-file sweep. What the
exclusion records actually show is narrower than "truncation", and the
distinction matters because the wrong word sends the next reader chasing the
wrong mechanism: the recorded reason is a single `<` line — `0` for
`refinement_type_test`, `All log tests passed.` for `log_test` — meaning that
line was present in one sample and absent in another. Both happen to be the last
line of the recorded output, which is suggestive, but nothing here establishes
that the tail was cut rather than a sample differing some other way.

**The obvious explanation was tested and FAILED.** This repo has a documented
Windows hazard — stdout to a PIPE can lose writes, which is why `rebuild.sh` and
`mutation_check.py` both redirect to a file — and `output_sweep` captures with
`$(...)`, a pipe. Predicted: pipe capture truncates occasionally, file capture
never does. Observed: **12/12 identical through both.** The theory is recorded
here as eliminated, not as the answer.

Remaining candidates, none tested: interference from an earlier fixture in the
same sweep (a server or thread fixture outliving its `timeout`), console/handle
contention, or something about sustained sequential load.

**Mitigated, not fixed.** `output_sweep --update-baseline` now requires an
exclusion to REPRODUCE: three samples, and if they disagree, a three-sample
confirmation round; only a repeated difference excludes. A file that disagrees
once and is then unanimous is kept and reported as a `transient` in the run
summary. Both paths are control-tested (a clock-printing fixture must still be
excluded; a forced single disagreement must be kept). That converts this from
silent coverage loss into a printed number — but it does not explain the
underlying disagreement, and a rising transient count is the signal to come
back to this ticket.

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

