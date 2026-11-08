<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-685. Next new bug: BUG-686.**

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

### BUG-684: a `Ws.serve` server prints Zig "unexpected NTSTATUS" traces when clients drop

**Reported 2026-11-07 by Fable** while confirming BUG-682's fix with the GameEngine's
`net_departure_test`: 550 to 655 traces per run, every one CONNECTION_RESET,
CONNECTION_ABORTED or LOCAL_DISCONNECT, on the server's reads at client departures. These are
std's Debug-mode prints for an NTSTATUS it does not map, and they appear before the runtime's
`catch` turns the failed read into nil. The program is correct and carries on, so this is not
a failure. But a user sees pages of Zig traces about runtime code they never wrote, which is
BUG-542's shape (that one fixed the WRITE of a second close frame; this is the READ). It
predates BUG-682 and is unchanged by it.

**Fix shape (to decide):** the trace is printed inside std (`windows.unexpectedStatus`), so
the runtime cannot catch its way out. Options: read through a path that maps these statuses
(check what 0.17 offers), or accept it as Debug-only noise and document it. Measure what a
`--release` build prints first.

**Control when fixing:** a `Ws.serve` program whose client exits without closing (a
reset): today it prints the traces; after the fix nothing, and `recv()` returns nil.

---

### BUG-682: `ws.close()` under a reader blocked in `ws.recv()` on another thread ends the process with no message (Windows)

**Reported 2026-11-07 by Fable** (GameEngine F65, `game/net_departure_test.zig`, 1c93942).
`_ws_close` sends the close frame and then calls `closeStream()`. If another thread of the
same program is blocked in `_ws_recv` on that connection, Windows cancels the pending read,
and Zig std's `netReadWindows` maps `.CANCELLED => unreachable`. The process exits with code
3 and prints nothing. It is DETERMINISTIC (Fable's correction, the same evening): 3 of 3 runs
died in the first rounds when the close came 0.5 ms into a stream of incoming frames (the
server broadcasting 400 small texts), so a read was in progress, not idle. The timing does not
matter. The 1-in-3 race in F65 was the OTHER half, the server's send into a freed `WsConn`.
The engine's client now sends only the close frame and lets the peer close the socket.

This is NOT REPRODUCED in this repo yet. No gate runs a WebSocket reader and a closer on two
threads. The `unreachable` is inside std rather than in Zebra code. What is Zebra's is that
`ws.close()` is documented as "send close frame and shut down the connection" with no
threading caveat. A user program that follows the documentation and closes from a second
thread dies silently.

**Fix shape:** (a) `_ws_close` sends the frame and shuts down only the WRITE half
(`shutdown(.send)`), leaving the reader to see the peer's close and return nil; the stream
is released when the last user is done; or (b) keep it as it is and document that
`close()` must not race a `recv()`. (a) is the one a user can't get wrong, and Opus and Fable
agreed on it in writing (2026-11-07). Check what 0.17's std offers for a half-close on
Windows first; if it offers none, say so here before falling back to (b).

**Control when fixing:** a Zebra program with a reader thread blocked in `ws.recv()` and the
main thread calling `ws.close()` against a local `Ws.serve` peer that is still SENDING (a
loop of small texts, so a read is in progress). Today: exit 3, no output, on the first run.
After the fix: `recv()` returns nil, the program prints a sentinel after the join and exits 0.
Red first on the current runtime, then green; a handful of runs is enough since it is
deterministic.

**Related, documentation only (done 2026-11-07):** `Ws.serve` destroys the `WsConn` when the
handler returns. A host that sends on it from another thread must make sure no send is in
flight at that moment. In the engine, a failed write inside a freed `_WsConn` segfaulted at
offset 0xe8. QUICKSTART's `Ws` notes now say so.

---

### BUG-680: a field or method a runtime object type does not have passes `-c` and fails inside zig

**Found 2026-11-05** validating the book against rc9: `DateTime.now().epochMs` (the book's
09_multiple_mixins; the accessor is `.toEpoch()`) passes `zebra -c` and fails in zig with
`no field named 'epochMs' in struct 'zebra_rt._DateTime'`, at the user's line. The front end
checks the members of the runtime types that have a `Type_` variant (BUG-369's recipe, 16
types) and not the rest -- DateTime, File handles, HttpResponse, the GUI widget structs --
which docs/SURFACE.md already lists under CANNOT SEE. Predates rc8; not a regression.

**Fix shape:** the BUG-369 recipe per type -- a `Type_` variant (or a named-type table) and a
`*MethodKnown` predicate derived from the type's dispatch arms, refusing an unknown member by
name in the front end.

**Control when fixing:** `DateTime.now().epochMs` refused at -c naming `toEpoch()`;
`DateTime.now().toEpoch()` and the computed fields (`dt.year` ...) still compile.

**Found probing it, 2026-11-07 -- DateTime cannot be NAMED as a type at all.** `var t:
DateTime = DateTime.now()`, a `DateTime` parameter, and a class field `var when: DateTime`
are each refused at -c, "unknown type 'DateTime'". The runtime's type is `_DateTime`, which
the runtime-public-name check does not match, and `isBuiltinObjectTypeName` does not list
it. Codegen has no mapping for the name either, so even an accepted annotation would fail in
zig. Nothing in this repo, the book, zebra-ide or the GameEngine annotates one; every use
is an unannotated local. This is BUG-345's shape (Timer could not be a field) for DateTime.
Separately, codegen recognises a DateTime by NAME (`isDateTimeExpr`: locals initialised
from `DateTime.*` or an `add*` call), not by type, so `c.when.year` on a field would emit
`.year` on the raw struct even once the annotation is accepted.

**Plan (daytime):** (1) give DateTime a checker type, either a `Type_` variant as BUG-345
did for Timer or `Type_.named("DateTime")` guarded by `not ctx.hasClassAny("DateTime")` as
CsvTable does. Choose by counting the exhaustive `branch` sites a new variant touches.
(2) Type the constructors and the `add*`/`inZone` results as it, the seven fields int, and
the methods per QUICKSTART's table. Also allow the raw `epoch_ms` (QUICKSTART's inZone notes
name it). (3) Refuse any other member by name. (4) Accept `DateTime` as a type name and map
it to `_DateTime` in codegen. (5) Make `isDateTimeExpr` consult the type, so fields and
parameters dispatch. A fixture covering a field, a parameter, a return, and a refused
member. Then the same for CsvTable / HttpResponse / File, one at a time. Related: BUG-683
(two DateTime emit leaks found on the same probe, fixed on the bug682 branch).

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

