<!-- doc-status: historical -->
# Zebra Compiler — Bug Tracker (Open)

**Last bug number generated: BUG-725. Next new bug: BUG-726.**

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
- **Option A progress (2026-11-13):** BUG-703 (`chars()` on bytes that are not UTF-8), BUG-704
  (`readAll` on a reset) and BUG-715 (`conn.write` to a peer that left) are fixed. Left in A:
  the parse helpers' panic arms and integer conversions on header values.
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

### BUG-711: `DateTime.inZone` answers in UTC for a zone it does not know, without saying so
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's `watch`)
- **Repro:** `DateTime.of(2026, 1, 15, 12, 0, 0).inZone("America/Phonix")` (a typo) and
  `.inZone("America/Boise")` (a real IANA zone the runtime's table lacks) both format as `12:00`,
  the UTC time; `"America/Phoenix"` correctly gives `05:00`. QUICKSTART says "Unknown zone names
  fall back to UTC (no crash)". A program that labels the time with the zone it asked for prints
  a wrong time with a right-looking label, and a one-letter typo is indistinguishable from UTC.
- **Correction (2026-11-13, same day):** this entry first gave `America/Phoenix` as the repro and
  said the table lists 10 zones. Both were wrong: QUICKSTART's 10 rows are "representative
  (~75 total)", the runtime's table has Phoenix, and Phoenix formats correctly. Measured with
  the probe above before correcting.
- **Second half:** nothing reads the machine's own zone, so a program cannot print local time
  without the user naming an IANA zone; `DateTime.now()` is documented as "current wall-clock
  time", which reads as local.
- **Fix shape (a decision):** refuse a literal zone outside the table at `-c` and panic or return
  nil at run time for a computed one -- a default that reads as an answer is the UNGIT
  "fabricated" case; and add a local-zone read (`DateTime.local()`, or `inZone("local")`) from
  the OS. Say "UTC" in the `DateTime.now()` row.
- **Control when fixing:** `inZone("America/Phonix")` no longer answers UTC silently;
  `inZone("America/Phoenix")` (05:00 at 12:00 UTC) and `inZone("America/Denver")` unchanged.

---

### BUG-716: a failed SQLite statement is silent, and a refused query reads as "no rows"
- **Status:** OPEN (filed 2026-11-13; Fable, from a Graze cold-start, measured on Graze's task
  demo at 7d24f18; the code read confirmed here)
- **Where:** `stdlib_preamble.zig`'s `_run` discards the step's result (`_ = sqlite3_step(stmt)`),
  and the readers loop `while (sqlite3_step(stmt) == _SQLITE_ROW)`, returning what they have when
  step answers BUSY, CONSTRAINT, IOERR or FULL (four loops). Only a failed PREPARE prints.
- **Measured (Fable):** four signed-in browsers saving forty tasks each at once: 148 of 160 saves
  answered "Added" and 101 rows were written -- 47 reported success and wrote nothing; 12 were
  answered 403 because a refused account read looked like "signed out"; where a handler indexed
  the answer (`.at(0)`) the server ended. The engine's DataStore has the same exposure for a full
  disk.
- **Fix shape (agreed in direction with Fable; V mirrors it):** print a step failure the way a
  prepare failure is printed, and give `SqliteDb` an error surface the caller can ask, at minimum
  `db.lastError(): str` -- `""` after a statement that succeeded, cleared at the start of each
  `exec`/`query`/`querySegments`. Whether a refused statement should instead RAISE (exceptions are
  the primary error model) is the decision to make first.
- **Control when fixing:** a write refused by a held lock (a second connection inside
  `BEGIN IMMEDIATE`) is reported -- printed, and visible to the caller -- while an empty SELECT
  still answers an empty list with no error.

---

### BUG-717: `Sqlite.open` sets no busy timeout, and its own pragmas run before one could be set
- **Status:** OPEN (filed 2026-11-13; Fable, measured on Graze)
- **Symptom:** with WAL, two writers at once is ordinary (each `Http.serve` request is its own
  thread, and in Graze its own connection), and the second is refused at once (`database is
  locked`). Graze now runs `PRAGMA busy_timeout=5000` after the open and reads it back, which took
  the BUG-716 measurement to 160 of 160. But the open's own `PRAGMA journal_mode=WAL` still logs
  "database is locked" under load, and when its `synchronous=NORMAL` is refused the connection
  silently keeps FULL.
- **Fix shape:** `sqlite3_busy_timeout(db, ms)` inside `_sqlite_open` BEFORE `_setWriteAhead`, as
  an argument with a default: `Sqlite.open(path, writeAhead: true, busyMs: 5000)`, `0` meaning
  "refuse at once" by name. A refused pragma in the open is reported, not kept silently.
- **Control when fixing:** a second connection writing while the first holds a write transaction
  for 200 ms succeeds after waiting; with `busyMs: 0` it is refused (and, with BUG-716, says so).

---

### BUG-718: SQLite is linked only when the ROOT file calls `Sqlite.open`
- **Status:** OPEN (filed 2026-11-13; Fable found it moving Graze's open into a module; reproduced
  here with Fable's probe, C:/tmp/link_probe)
- **Repro:** `dbmod.zbr` holds the program's only `Sqlite.open`; `main_a.zbr` uses it. The build
  fails with 16 `lld-link: undefined symbol: sqlite3_...` errors naming nothing the author wrote.
  The control `main_b.zbr` (the same program plus one `Sqlite.open` in the root) prints `n = 42`.
- **Cause:** `selfhost/main.zbr` (~572-582) decides whether to link sqlite3.c by counting
  `_sqlite_open` in the ROOT module's generated Zig only.
- **Workaround:** call `Sqlite.open` in the root file.
- **Fix shape:** decide from every emitted module (or from the checker's knowledge that any module
  names `Sqlite`), so the root's spelling stops mattering.
- **Control when fixing:** `main_a` prints `n = 42`; a program that never names Sqlite still links
  without sqlite3.c (its build does not grow).

---

### BUG-719: `Http.serve`, `Ws.serve` and `Tcp.serve` listen on every interface
- **Status:** OPEN (filed 2026-11-13; Fable, from Graze)
- **Where:** all three bind `0.0.0.0` (`stdlib_preamble.zig`, `_addr`/`_waddr`), with no way to
  ask for another address. Every Graze app prints `http://127.0.0.1:port/`, so a demo started on a
  laptop is reachable from every network the laptop is on, and nothing says so.
- **DECIDED 2026-11-13 (Sean, first-hand): loopback by default for all three serve calls;
  every other interface is asked for by name.** His reason: a broader default can reserve
  network channels or ports a program was never meant to hold -- keep the default minimal.
  Shape: an address argument, `Http.serve(port, handler, host: "127.0.0.1")`, the same on
  `Ws.serve` and `Tcp.serve`, with `"0.0.0.0"` (all interfaces) stated by the program. The
  GameEngine's `--server` (through `Ws.serve`) needs the LAN and will pass the address
  explicitly (Fable, in the pin-move commit). An address the machine does not have is refused
  by name, never a fallback. The V route has no serve calls yet, so nothing to mirror there.
- **Confirmed (Fable, 2026-11-13):** a Graze app on port 8099 answered 200 on 127.0.0.1 and on both
  of the machine's non-loopback addresses; netstat showed `0.0.0.0:8099 LISTENING`.
- **Control when fixing:** with the default, a connection to the machine's LAN address is refused
  and one to 127.0.0.1 is served; with `host: "0.0.0.0"` both are served.

---

### BUG-720: `zebra build` cannot build a program that uses SQLite
- **Status:** OPEN (filed 2026-11-13; Fable, from Graze; reproduced here on a copy of
  C:/tmp/link_probe)
- **Repro:** `build.zbr` holding `b.exe("main_b", "main_b.zbr")`, where `main_b.zbr` calls
  `Sqlite.open` in its root (it runs fine with `zebra main_b.zbr`). `zebra build` fails with 16
  `lld-link: undefined symbol: sqlite3_...` errors and `build: zig build-exe exit 1`.
- **Cause:** the build path runs `zig build-exe` on the emitted Zig and never adds
  `vendor/sqlite/sqlite3.c`; the run path does (by BUG-718's root-only decision).
- **Second half (Windows):** for a program without SQLite the build works, but the output is
  `zig-out/bin/<name>` with no `.exe` (beside `<name>.pdb`), which cmd will not run by name.
- **Why it matters:** there is no supported way to build a SQLite app once. Every Graze start is
  a compile (7 s for the task demo, 25 s with `--release`), and the only executable is the
  `.zig.run.exe` in a scratch directory.
- **Fix shape:** the build path takes the same link decision as the run path (after BUG-718, the
  module-graph one), and names the file `.exe` on Windows.
- **Control when fixing:** the repro builds and the binary prints `n = 42`; a program without
  SQLite still builds without sqlite3.c; on Windows the output ends `.exe`.

---

### BUG-721: `HttpResponse.text` (and its other fields) have no type in the checker
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's model calls)
- **Repro:** `def g(resp: HttpResponse)` with `var u = resp.text` then `print(u.len)`: `-c`
  refuses "cannot infer the type of `u`, so `.len` cannot be resolved". The same through
  `if r as resp` and through `resp.text.replace(..)`. A field read off a runtime object type
  is untyped, so every use past a method call needs an annotation (`var u: str = resp.text`).
- **Fix shape:** type `HttpResponse`'s fields (`status: int`, `text: str`, `headers`) where its
  methods are typed (BUG-680's runtime-object tables), and check the other runtime objects'
  fields the same way.
- **Control when fixing:** the repro passes `-c` and prints the length; an unknown field on an
  `HttpResponse` is refused by name.

---

### BUG-722: `Json.array().append(v)` with a JsonValue passes `-c` and fails inside zig
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's model calls)
- **Repro:** `var m = Json.object()`, `m.put("role", "user")`, `var arr = Json.array()`,
  `arr.append(m)`. `-c` exits 0; the build fails `error: expected type 'str', found
  'json.dynamic.Value'`. `put(k, obj)` is the same shape. So JSON objects cannot be nested
  through the builder, and the front end does not say so.
- **Workaround:** stringify each scalar-only object and join the request body as text
  (`plm.zbr`'s `jq()`).
- **Fix shape (a decision):** either `append`/`put` take a JsonValue (nesting, which is what a
  request body needs), or a JsonValue argument is refused at `-c` naming the scalar forms.
  The first is the useful one.
- **Control when fixing:** the repro stringifies to `[{"role":"user"}]`, or is refused at `-c`
  by name; scalar `append`/`put` unchanged.

---

### BUG-723: `s.chars()` as a value passes `-c` and fails inside zig (the V route builds it)
- **Status:** OPEN (filed 2026-11-13; Fable, from a probe of every char-to-text position for
  BUG-712; reproduced here)
- **Repro:** `var cs: List(char) = "aéb".chars()` then `print(cs.count())`. `-c` exits 0; the
  build fails `no field or member function named 'chars' in 'str'`. Three of Fable's 31 probe
  programs died on it (keeping the list, printing it, joining it).
- **Why it matters:** QUICKSTART says `chars()` is `for`-only and that binding it "does not
  compile" -- but the refusal is zig's, about code the user never wrote, and the V route maps
  it (`zstr_chars`), so the two routes disagree on whether the program builds at all.
- **Fix shape (a decision):** support it on the Zig route (a `List(char)` built by the BUG-703
  decoder, the same items the loop yields), or refuse it at `-c` by name on both routes. The
  first matches the V route and costs little now that the decoder is the runtime's own.
- **Control when fixing:** the repro prints 3 on both routes, or is refused at `-c` naming
  `chars()`; `for c in s.chars()` unchanged.

---

### BUG-724: a zig the compiler cannot start is reported as "spawn failed", naming nothing
- **Status:** OPEN (filed 2026-11-13; found running the Pocket Lab manager's tools)
- **Repro (Git Bash):** `source tools/zig_toolchain.sh` (exports `ZEBRA_ZIG=/c/Users/.../zig.exe`,
  a POSIX-style path), then `MSYS_NO_PATHCONV=1 zebra prog.zbr`. Git Bash normally rewrites that
  path to Windows form for a native program; `MSYS_NO_PATHCONV=1` turns the rewrite off for the
  environment too, so the compiler tries to start a zig at a path Windows cannot find. All it
  prints is `spawn failed` -- not which program, not the path, not that the path came from
  `ZEBRA_ZIG`. It took six runs to isolate, two of them misread (one success came from a shell
  that had not sourced the toolchain, so `ZEBRA_ZIG` was unset).
- **Where:** `_sys_run` turns `error.FileNotFound` into the bare text "spawn failed"; main's zig
  resolution (`getenv("ZEBRA_ZIG")`) takes the variable without checking that it exists.
- **Fix shape:** check `ZEBRA_ZIG` when it is resolved and refuse naming it ("ZEBRA_ZIG names
  /c/... which does not exist"; on Windows add that a /c/... path is Git Bash's spelling); and
  make the spawn failure name argv[0].
- **Control when fixing:** `ZEBRA_ZIG=/nonexistent/zig.exe zebra hello.zbr` says ZEBRA_ZIG and the
  path; a valid `ZEBRA_ZIG` unchanged.

---

### BUG-725: a runtime `int` formatted with a width prints a `+` sign
- **Status:** OPEN (filed 2026-11-13; found building the Pocket Lab manager's dialogue report)
- **Repro:** `var n = sys.args().count()` (1), then
  `print("[${n:>3}] [${n:3}] [${n:<3}] [${7:>3}] [${n:03}] [${-n:>3}]")` prints
  `[ +1] [ +1] [+1 ] [  7] [001] [ -1]`. A width on a RUNTIME signed int adds a `+` the program
  never asked for; the literal `7` and the zero-padded form are right. Python prints
  `[  1] [  1] [1  ] [  7] [001] [ -1]` for the same specs, and QUICKSTART's format-spec section
  describes Python's meaning.
- **Likely cause:** the hole emits Zig's `{d:>3}` over an `i64`; Zig's integer formatting shows the
  sign of a signed value when a width is given. A `comptime_int` (the literal) takes another path.
- **Fix shape:** format a signed int with a width the way `_zbr_zpad` already does for the `0`
  flag -- through a runtime helper that writes the sign only when negative (or when the spec has
  `+`) -- and pin every alignment.
- **Control when fixing:** the repro prints `[  1] [  1] [1  ] [  7] [001] [ -1]`; `${n:+>3}` and
  `${n:+}` still show the sign where the spec asks for it.

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
