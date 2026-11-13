<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-711. Next new bug: BUG-712.**

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

### BUG-708: `private` is not enforced from another module, and never on methods
- **Status:** OPEN (filed 2026-11-13; Fable from Graze, reproduced on 0aaf714)
- **Repro:** `vault.zbr` declares `class Vault` with `private var secret: str`, `private var log:
  StringBuilder` and `private def hidden(): str`. `other.zbr` does `use vault exposing Vault`, then
  `v.secret = "w"`, `v.log.append("x")`, `print(v.hidden())`. `zebra -c other.zbr` exits 0 and the
  program runs, printing the written value through both methods.
- **Two defects, measured separately:**
  1. **Fields, across modules.** In ONE file the field shapes are refused at their column
     (`'secret' is private`, `'log' is private`, for a read, a write and a container mutation).
     From another module none is. The check in `TypeChecker.zbr` (`'...' is private`, near the
     BUG-680 runtime-object arms) asks only `ctx.module_types.isPrivateMember`; a dep's class
     records its private keys in `dep_types`, which is never consulted (reading, not yet
     measured: `populateModuleTypes` runs `addClassMembers` for deps, which records the key).
  2. **Methods, everywhere.** `v.hidden()` is accepted even with the class and the call in the
     same file. `addClassMembers` records a private method's key, but no call path reads it.
- **Cost:** QUICKSTART §18 says `private` "restricts the member to the owning class". A type whose
  point is an invariant -- Graze's `SafeHtml` keeps its text in a private `StringBuilder` so only
  its methods can write it -- has no guarantee from the compiler. Graze covers it with a source
  check of its own.
- **Fix shape:** an `isPrivateMemberAny` beside `fieldTypeAny` (own module, dep table, bare-name
  fallback), used by the field check; the same test on the member-call path for methods, with
  the owning-class exemption. A refusal names the member and the class (`'hidden' is private to
  Vault`). Before landing, measure: `-c` refusal counts over this repo, zebra-ide and the
  GameEngine before and after, since a private method called from outside may exist today.
- **Control when fixing:** each of the four repro lines refused at its column across modules, and
  the method call refused in one file; the class's own methods still read and call every
  private member; a public member of the same class still reachable from `other.zbr`.

---

### BUG-709: `zebra -c` accepts a `str` or `int` where a class is expected
- **Status:** OPEN (filed 2026-11-13; Fable from Graze, reproduced on 0aaf714)
- **Repro:** `class SafeHtml` and `def html(body: SafeHtml)`; then `html("<p>")`, `return name`
  from `def f(name: str): SafeHtml`, and `var h: SafeHtml = name`. `-c` exits 0 on all three.
  `--check-full` and a build refuse at the `.zbr` line (`expected type '*SafeHtml', found
  '*const [3:0]u8'`), so a build never ships it. `html(5)` and `html(Other())` with another
  class pass `-c` too; `-c --strict` sees none of them.
- **Cost:** `-c` is the fast check the IDE and the LSP run on every edit; a wrong argument type
  shows up only at build, as a Zig type name. `--help` says `-c` can pass code a build refuses,
  but plain argument types are the first thing a reader expects it to cover.
- **Fix shape:** in the call-argument loop, the typed-`var` check and `return`, refuse a value
  whose type is KNOWN (a literal, a `str`/`int`/`float`/`bool` local, another class) where the
  slot is a user class, naming both types. An unknown type is not refused (the BUG-632 rule).
  Measure `-c` counts over the three corpora first.
- **Control when fixing:** the five shapes refused at their columns; a `SafeHtml` value, a
  `SafeHtml?` slot given `nil`, and an interface slot given an implementing class still pass.

---

### BUG-710: `SqliteDb.querySegments` reads every column of a depth-2 nested procedure one place off
- **Status:** OPEN (filed 2026-11-13; Fable, diagnosed from Mosaic through Graze, on 8ac485e)
- **Symptom:** Mosaic's `CALL witnesses_full() RETURNING *` -- `wid, label, claims TABLE(subject,
  cid, property, confidences TABLE(cid, aspect, confidence))` -- reads `asStr("wid")` as `""`,
  `asStr("label")` as the wid, and in segment 1 `cid` holds the subject and `property` the cid.
  Nothing errors. Depth-1 procedures (two sibling tables, bugbook's `bug_show`) read correctly.
  Graze's Mosaic viewer printed empty links from the day its clients moved to `querySegments`.
- **Cause (Fable's reading, two errors in `stdlib_preamble.zig`):**
  1. `_segInterleaved` starts its column bases at `var acc: usize = 2`, assuming two leading
     columns (`_segment`, `_key`). A depth-2 `WITH INTERLEAVED` result leads with THREE
     (`_segment|_k1|_k2|...`), one key column per nesting level.
  2. `_segNames` skips a nested column (empty decltype in `PRAGMA proc_info`) only in the parent
     (`idx == 0 and ...`). Segment 1 here has one too (`confidences`), so its arity is counted 4
     instead of 3 and every later base is one too far. On this procedure the two errors cancel
     for segment 2, which is why it looked right.
- **Fix shape (Fable tested it in a scratch toolchain):** skip a nested column in every segment;
  count the leading key columns from the column NAMES (`_segment`, then `_key` or `_kN`) instead
  of assuming 2; and if the bases do not account for exactly every column, return null so the
  walk transport serves the query rather than shifted columns. That last guard also covers a
  procedure whose first real column happens to be named `_key` or `_k1`.
- **Control when fixing:** a depth-2 procedure fixture reading every column of every segment
  correctly, red against today's `_segInterleaved`; a depth-1 procedure (two sibling tables)
  reading identically before and after. Repro database: `C:/Projects/mosaic/sprocket/job.db`
  (work on a copy). The fixture taken from sprocket on 2026-11-08 has depth-1 shapes only,
  which is why nothing caught this.

---

### BUG-711: `DateTime.inZone` answers in UTC for a zone it does not know, without saying so
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's `watch`)
- **Repro:** `DateTime.now().inZone("America/Phoenix").format("HH:mm")` prints the UTC time.
  QUICKSTART says "Unknown zone names fall back to UTC (no crash)", and the table lists 10
  zones. A program that labels the time with the zone it asked for prints a wrong time with a
  right-looking label.
- **Second half:** nothing reads the machine's own zone, so a program cannot print local time
  without the user naming an IANA zone; `DateTime.now()` is documented as "current wall-clock
  time", which reads as local.
- **Fix shape (a decision):** refuse a literal zone outside the table at `-c` and panic or return
  nil at run time for a computed one -- a default that reads as an answer is the UNGIT
  "fabricated" case; and add a local-zone read (`DateTime.local()`, or `inZone("local")`) from
  the OS. Say "UTC" in the `DateTime.now()` row.
- **Control when fixing:** `inZone("America/Phoenix")` no longer prints UTC silently;
  `inZone("America/Denver")` unchanged.

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
