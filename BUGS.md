<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-678. Next new bug: BUG-679.**

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

### BUG-678: `%` over two constants has no type, so `n + 100 % 7` is refused as "cannot infer"

**Found 2026-11-04** while probing BUG-675. With `n: int`, `var e: int = n + 100 % 7` is
refused at `-c` with "cannot infer the type of this expression, an operand of `+`", and
so is `k + (100 % 7)` on a byte. `n - 100 % 7` and `n * (9 % 4)` pass. Cause: inferExpr's
binary branch has arms for `+ - * /` and none for `%`, so two literals (numericJoin
returns unknown for a constant pair) fall to `else -> unknown_`; codegen's `+` operand
guard (the §28a refusal) then refuses, while `-` and `*` have no such guard. Predates
BUG-674 (the pre-674 compiler refuses the same lines). `var c: int = 100 % 7` is fine.

**Fix shape:** an `on BinaryOp.mod` arm beside `div` (arithOperandCheck with "%", then the
numeric operand's type). Lands with BUG-675, which reads the same constant expressions.

**Control when fixing:** `n + 100 % 7` prints 1002 for n = 1000; `"x" % 5` is refused in
the front end, as `"x" / 5` is.

---

### BUG-677: a second `_zbr_cens_install()` does nothing and says nothing, so a host's late census install is silently a whole-run census

**Found 2026-11-04 by Fable**, reading the first kept-column run (cbfe879). A program
emitted with `--census` installs the census in its own entry prologue. The GameEngine host
calls that `main` before its loop, and its `--census-at 120` then calls
`_zbr_cens_install()` again, which returns at `if (_zbr_cens_on) return;` with no word.
Every "steady state" census the engine took (2026-11-01, 11-03, 11-04) was really a
whole-run census, and the only evidence was that the unseen-free count came out small where
a late install would make it large. Nothing withheld fails: the runtime knows the call
changed nothing and the caller cannot tell.

**Fix shape (joint, Opus + Fable in writing, 2026-11-04 evening; supersedes the note-only
shape agreed earlier that day, which left `--census-at` with no window):**
1. `zebra --census=host`: the emitted entry prologue does NOT install; the host calls
   `_zbr_cens_install()` when its window should start. Plain `--census` is unchanged. The
   intent is in the BUILD -- an environment variable read at start-up (`ZEBRA_CENSUS_DEFER`
   was proposed) was declined as ambient state: a shell that happens to set it gets a binary
   that does not count, and nothing at the call site says why. Fable has no case for one
   binary choosing at run time.
2. A redundant install says so on stderr, once, naming who installed first (the entry
   prologue) and that counts run from then -- keeping the `void` signature, since a Zig host
   calling it as a statement would break on a returned value.
3. A `--census=host` build that reaches exit with no install says so on stderr ("built for a
   host install, never installed") and writes no zebra-census.json, so no report never reads
   as an empty one.
A `_zbr_cens_reset()` that zeroes the counts was offered and DECLINED. The engine works around
the silence today (`NO WINDOW` printed, and the window taken as the difference of two runs'
JSONs, `tools/census_kept.py --baseline`); when this lands its census regen passes
`--census=host`, the host installs at frame 0 or at `--census-at`'s frame, and `--baseline`
stays an option rather than the method. A new CLI form: `docs/SURFACE.md` (surface-freeze),
`cli_check`, CHANGELOG and QUICKSTART move with it.

**Control when fixing:** census_check legs -- (a) a `--census=host` probe that installs from a
`zig"..."` line after N labelled allocations must report exactly the allocations made after
the install (derived from the probe's labels, not from the runtime); (b) a plain `--census`
program that calls `_zbr_cens_install()` again must see the note on stderr and unchanged
totals, and one that never calls it again must print no note; (c) a `--census=host` program
that never installs must print the never-installed note and leave no zebra-census.json.

---

### BUG-675: a constant expression or a `1_000` literal beside a narrow operand still reaches zig

**Found 2026-11-03**, the residual of BUG-672. `litFitsType` reads only a bare (or negated)
decimal or hex `int_lit`, so with `k: byte` both `k + 100 * 3` and `k + 1_000` pass `zebra -c`
and fail in zig with `type 'u8' cannot represent integer value '300'` / `'1000'` (probed). A
constant expression adapts to the other operand exactly like a literal (`isNumLit`), so it
must fit there too; a digit separator is treated as "a suffix or separator: not checked here".

**Fix shape:** fold the constant (`+ - * / %` over literals, unary `-`) to a value in
`litFitsType`, and skip `_` between digits while still leaving a type suffix (`0xFF_32`) alone.
Front-end only; needs the same 3-repo `-c` sweep as BUG-672 before landing.

**Control when fixing:** `k + 100 * 3` and `k + 1_000` refused at the expression naming the
range; `k + 3 * 4`, `k + 1_0` and `k + 0x1FF_32` still pass. (The entry first named `5_u8`, which is not
writable: decimal `_i`/`_u` suffixes lex as `integer_lit_explicit` and no parser rule accepts that token.
A suffixed hex literal carries its own type, and 511 beside a byte shows the fold leaves it alone.)

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

