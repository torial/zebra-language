<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-707. Next new bug: BUG-708.**

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

### BUG-701: a panic in an `Http.serve` handler ends the whole server process
- **Status:** OPEN (filed 2026-11-12; Fable, measured through the sprocket toolchain of 2026-11-08)
- **Observed:** `GET /task/\xff\xfe HTTP/1.1` (a path holding bytes that are not UTF-8) killed
  a Graze server: the next connection was refused. The handler walked the path as text
  (`split` / `chars()` / compare). **The operation is `chars()`** (Fable, 2026-11-12: with the
  guard removed, raw `\xff\xfe` went through `split`, `trim` and `==` and died in `for c in
  s.chars()`), filed on its own as BUG-703 -- a `str` operation that panics on bytes a peer
  controls is a crash any client can trigger.
- **The general shape, true by construction:** the accept loop calls the handler in-process,
  and a Zig panic is a process exit, so ANY handler defect is a denial of service. Graze's
  charter (§4.3) wants per-request recovery that answers 500 and keeps serving; Zig has no
  `recover`, so that needs a design (a worker process, or handlers that cannot panic on input),
  not a patch. **Decided 2026-11-12 (Sean):** option A (remove the panics input can reach,
  BUG-703 first), then option B (an opt-in supervising restart), and both are required;
  `docs/design/http_serve_recovery.md`. This entry closes when B lands.
- **Workaround today:** check `isValidUtf8()` on path, query and body first and answer 400
  (Graze does; witnessed red and green in `graze/tasks/check_tasks.py`).
- **Control when fixing:** a raw `Tcp` client sends the non-UTF-8 path; the server must answer
  it (400 or 500) AND answer the next request.

---

### BUG-702: `b.toInt()` on a byte from `s.bytes()` passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-12; found by Fable in Graze's percent-decoder, reproduced on the
  batch's compiler)
- **Repro:** `for b in "AB".bytes()` then `var n: int = b.toInt()`. `-c` exits 0; the build fails
  `error: expected float type, found 'u8'` -- the call is lowered as a float-to-int conversion.
- **Workaround:** `var n: int = b` (a byte widens to int), which Graze uses.
- **Fix shape:** the receiver's numeric kind decides the lowering: an integer receiver of any
  width is `@as(i64, b)`, never `@intFromFloat`.
- **Control when fixing:** the repro prints 65 and 66; `3.7.toInt()` keeps truncating.

---

### BUG-703: `s.chars()` panics on a string that is not valid UTF-8
- **Status:** OPEN (filed 2026-11-12; reproduced)
- **Repro:** `var s = "a" + "${255:c}" + "b"`; `s.isValidUtf8()` is false, and `for c in s.chars()`
  panics: `attempt to unwrap error: Utf8InvalidStartByte`. In an `Http.serve` handler that is
  BUG-701 -- any client sending such bytes ends the server.
- **Fix shape (a decision, not a patch):** yield U+FFFD for each invalid sequence (what most
  languages' lossy decoders do), or refuse at the call by returning nothing for the bad run.
  Either way, never panic on input bytes; `isValidUtf8()` stays the way to tell. Fable's leaning
  (2026-11-12, to be agreed in writing before building, since the V route needs the same answer):
  REFUSE in anything whose result feeds a comparison or a store, because two U+FFFDs compare
  equal (the reassuring-answer failure), and keep a separately named lossy conversion for display.
- **Control when fixing:** the repro iterates three items (or the chosen spelling's count) and
  exits 0; a valid string's `chars()` is unchanged.

---

### BUG-704: `conn.readAll()` panics when the peer resets the connection
- **Status:** OPEN (filed 2026-11-12; found by the BUG-699 red-check)
- **Where:** `_tcp_read_all` ends `streamRemaining(..) catch |e| @panic(@errorName(e))`. A peer that
  resets instead of closing -- which any server does when it closes with unread input -- turns
  into `panic: ReadFailed` in the CLIENT: a remote peer can crash a program by misbehaving.
  Seen 8 of 8 runs against `Http.serve` with its lingering close removed.
- **Fix shape:** return what arrived. `read()` already treats an error as end of stream; whether
  `readAll` should also distinguish "reset" from "closed" is the decision to make (QUICKSTART
  says `""` at EOF for `read`, nothing for `readAll`).
- **Control when fixing:** a `Tcp.serve` handler that writes a reply and closes with unread input;
  the client's `readAll()` returns the reply (or what arrived) and the program exits 0.

---

### BUG-705: an unbraced `ë` in a string passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-12; found writing the Crypto batch's fixtures, reproduced on 8ac485e)
- **Repro:** `print("cafë")` (the Python/JSON spelling). `zebra -c` exits 0; the build fails in
  the emitted Zig with `error: expected '{', found '0'` -- the escape is passed through verbatim.
- **Why it is a leak, not a typo:** the lexer already refuses an unknown escape at its column --
  `"a\wb"` gives `unknown escape \w in a string -- the escapes are ... \u{N}` -- but it accepts
  `\u` without checking that `{` follows.
- **Fix shape:** refuse `\u` not followed by `{` at the escape's column, naming the braced form
  (`\u{00eb}`); the same check for an unterminated `\u{`.
- **Control when fixing:** the repro is refused by `-c` with a column; `print("caf\u{00eb}")` still
  prints `cafë`. Write the fixture from Python or an editor: bash `printf` rewrites `\u` itself.

---

### BUG-706: `zebra prog.zbr` exits 1 whatever code the program exited with
- **Status:** OPEN (filed 2026-11-12; Fable, reproduced on 8ac485e)
- **Repro:** `def main()` printing `hi` then `sys.exit(7)`. `zebra exit7.zbr; echo $?` prints `1`, and
  the driver adds `note: the scratch build is kept in ...`. The same program built with
  `--output-dir` and run directly exits 7. Control: a program that exits 0 gives 0.
- **Cost:** a program that uses exit codes (2 for bad usage, say) cannot be told from a compile
  failure through the run mode -- any script wrapping `zebra prog.zbr` loses the information.
- **Cause:** both run paths in `selfhost/main.zbr` answer a non-zero program exit with
  `mc.exitWith(1, true)`
  (the fast path near `deleteScratch(fast_exe)`, the LLVM path near `exec_inherit`).
- **Fix shape:** `mc.exitWith(rc, true)` at both sites. Keeping the scratch on a failed PROGRAM is
  BUG-513's deliberate rule; the note should then say the program exited N, so it does not read
  as a build failure. A build failure stays exit 1 with its note.
- **Control when fixing:** the repro exits 7 through `zebra exit7.zbr` and through the LLVM path
  (`--release`); a zig refusal still exits 1; a panicking program keeps a non-zero code.

---

### BUG-707: an `Http.serve` 413 is lost to a reset when the client really sends the body
- **Status:** OPEN (filed 2026-11-12; Fable, measured from Python on loopback against Graze on 8ac485e)
- **Observed:** a Content-Length of 10 GB with nothing sent gets the 413 every time (the
  `bug698_http_serve_hardening_test` leg). A 1.5 MB form actually sent got the 413 once and a
  reset twice in three runs; 3 MB was a reset every time, also from a client that polls for an
  early answer between 16 KB chunks.
- **Cause:** `reject` drains at most `_HTTP_MAX_BODY` (1 MB) after answering, and every body it
  refuses is larger than that, so a client that sends its whole body always leaves unread input
  at close: an RST, which can destroy the 413 before the client reads it.
- **Not a safety issue:** nothing is created and the server keeps answering. A browser uploading
  a large form shows "connection reset" instead of the 413.
- **Fix shape (a decision):** drain up to min(Content-Length, a larger cap such as 16 MB) under a
  time bound, so a slow or lying client cannot hold the thread. There is no read deadline yet
  (BUG-699's open half), and the time bound wants that first.
- **Control when fixing:** a raw client that sends a 3 MB body in full reads `413` in 10 of 10 runs,
  and the server answers the next request.

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
