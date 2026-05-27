# Zebra — Changelog

All notable changes to Zebra from 0.1 through the current 0.15 development
release. Most-recent entries first.

Zebra is a compiled language: changes land in the bootstrap compiler
(`src/`) and the self-hosted compiler (`selfhost/`) together. "Both
compilers" means both are updated and round-trip identical output is
confirmed via `tools/bootstrap_check.sh`.

---

## [0.15] — 2026-05 (in progress)

### GUI: libui-ng backend (native OS widgets)

- **File dialogs** — `g.openFile()→str?`, `g.saveFile()→str?`,
  `g.openFolder()→str?`, `g.msgBox(title, msg)`, `g.msgBoxError(title,
  msg)`. The path-returning methods are typed as `str?`; use
  `if g.openFile() as path` to bind. All five backends wired; libui-ng
  uses `ui.Window.OpenFile/SaveFile/OpenFolder/MsgBox/MsgBoxError`.

- **`progressBar(label, f64)`** — 0–100% display widget; retained-mode
  correct via `_LuiMut.pb` cache entry. All five backends.

- **`combobox(label, List(str), int) → int`** — drop-down selector;
  `OnSelected` callback writes `sval`; frame-0 creation with item
  list. All five backends.

- **`spinbox(label, int, int, int) → int`** — integer spinner with
  min/max bounds; `OnChanged` callback. All five backends.

- **`beginPanel(id) / endPanel(id)`** — `uiGroup` titled border with
  inner VBox; retained-mode cached in `_lui_grp_cache`; `using g.hbox()`
  / `g.vbox()` factory methods work inside panels.

- **`beginHBox / endHBox` / `beginVBox / endVBox`** — horizontal and
  vertical layout boxes; `_GuiBackend` fn-ptr slots; stub, TUI, and
  libui-ng backends; `g.hbox(id, stretch)` / `g.vbox(id, stretch)`
  factory methods + `using` desugaring.

- **libui-ng ecosystem** — `torial/libui-ng` rebased onto kojix2 (111 bug
  fixes) + 46 C additions (float spinbox, file dialogs, placeholder text,
  `DrawBitmap` decl); `torial/zig-libui-ng` Zig 0.16 compat (`.c`
  callconv, `comptime` callback fixes); 9 new bindings (Tab.selected,
  Grid.delete/numChildren, Draw.Transform/Clip/Save/Restore,
  Entry/Combobox placeholder).

- **`--gui-backend=libui_ng`** — end-to-end tested; `examples/counter.zbr
  --gui-backend=libui_ng` opens a native Win32 window.

### GUI: MVU architecture

- **`Gui.run(title, w, h, init, update, view)`** — 6-arg MVU form
  replaces the 4-arg frame-callback form. `init()` → initial model,
  `update(model, msg)` → next model, `view(g, model)` → renders and
  calls `g.send(Msg)`. The runtime queues messages, calls `update`, and
  re-renders.

- **`g.send(msg: anytype)`** — type-erased send via `_send_fn`/`_send_ptr`
  fields in `GuiContext`. Can be called from `view()`.

- **ZebraIDE MVU rewrite** — `IDE/ZebraIDE.zbr` rewritten from 454-line
  frame-callback to 365-line MVU; 14-variant `Msg` union; background
  process polling in `view()` via `g.send()`.

### Language syntax cleanup (0.15)

- **`x!` postfix force-unwrap** — `x!` is equivalent to the existing
  `x to!`; supports chaining `x!.method()`. `to!` retained as alias.

- **`with OBJ` contextual self** — `with g` makes bare method calls like
  `text("hello")` desugar to `g.text("hello")`.

- **Removed `try expr` prefix** — this was a Zig syntax leak. Use `expr?`
  error-propagation instead; `try EXPR` still works inside `zig` blocks.

- **Inline single-line `if/else`** — `if x: y` and `if x: y else: z`.
  Colon required; `else if` chaining and next-line `else:` supported.

- **`Scope` interface check for `using`** — TC verifies the object passed
  to `using EXPR` has `def begin()` and `def end()`; structural typing;
  error names the missing method(s).

- **`is not` operator** — precedence documented and tested; `Expr4 > not >
  or` ordering confirmed for both compilers.

- **`using EXPR` scope blocks** — renamed from `in EXPR`; any object with
  `begin()`/`end()` works. Desugars to `{ const _t = EXPR; _t.begin();
  defer _t.end(); body }`. `kw_in` retained for `for`-in loops.

### Stdlib completeness (0.15)

- **`Http.serve(port, handler)`** — `std.http.Server` wrapper; exposes
  response writes; both backends.

- **`ThreadPool(n)`** — erased fn-ptr worker pool; `pool.submit(lambda)` +
  `pool.wait()`; bounded concurrency. Plain named type (not generic).

- **`Atomic(T)`** — wraps `std.atomic.Value(T)`; `add/sub/load/store/swap`
  operations; `Atomic(int)` / `Atomic(bool)`; both backends.

- **`SQLite`** — sqlite3.c amalgamation bundled at build time; `Sqlite.open
  / exec / query / begin / commit / rollback / close`; `row.asInt /
  asStr / asFloat / asBool`; `sqlite_row_list` iterable type.

- **`UDP`** — `Udp.bind(port)` / `Udp.socket()`; `sock.send / recv /
  close`; complement to `Tcp.connect`.

- **`Log` improvements** — `Log.json(level, msg, data)` JSON-lines format;
  `Log.setFile(path)` file sink.

- **`Crypto` additions** — AES-256-GCM `Crypto.encrypt / decrypt`; SHA-256
  key derivation (`Crypto.deriveKey`).

- **`Path.*`** — `join / dirname / basename / ext / extension / stem /
  isAbsolute / absolute`; wraps `std.fs.path`; `extension` is an alias
  for `ext`.

- **`Compress.gzip / gunzip`** — round-trip gzip compression via
  `std.compress.flate`.

- **`Tcp.serve(port, handler)`** — complement to `Tcp.connect`; per-connection
  handler.

### Zig 0.16 migration

- Core APIs: `ArrayList.empty`, `init: std.process.Init`, `_initIo` chain,
  selfhost `genMethod` fix.
- Net migration: TCP / WebSocket / HTTP serve ported from removed
  `std.net` / `std.posix` to `std.Io.net`.
- `_Chan(T)` updated to `std.Io.Mutex` / `Condition`; `_build_new` uses
  `.targets = .empty`.

---

## [0.14] — 2026-05

- **`<-` deep copy-out** — `_zbr_deep_copy` preamble helper; `List` and
  classes inside `allocate` blocks deep-copy on `<-` assignment;
  `HashMap` blocked by design.

- **`allocate` Slice 5** — `is_scoped` flag in copy-out; `allocate_depth`
  counter replaces `arena_depth`; scoped `Arena / Debug / FixedBuffer`
  copy correctly across scope boundaries.

- **`allocate` Slice 6** — `arena` keyword removed (soft deprecation with
  helpful diagnostic); `kw_arena` kept in lexer so the error message can
  guide migration to `allocate Arena()`.

- **`Chan(T)`** — `ch <- val` send, `var v <- ch` receive, `ch.close()`;
  `sys.go(lambda)` fire-and-forget goroutine-style threads; TC inference
  for `recv→?T`, `send/close→void`; QUICKSTART §35.

---

## [0.13] — 2026-05

- **Visibility enforcement** — `private / public / internal / protected`
  parsed and enforced; TC error when a private member is accessed outside
  its owning class; `internal` excluded from cross-module interface
  tables.

- **`^T` boxing edge cases** — `List(^T).add(val)` heap-boxes struct
  values in both compilers; `for item in List(^T)` via Zig auto-deref;
  method-chain temporaries fixed (BUG-027/079).

---

## [0.12] — 2026-05

- **ZebraIDE self-hosted** — `IDE/ZebraIDE.zbr`; Build panel, Debug/Stop
  buttons, background process management via `SysProcess`.

- **Debugger / DAP** — `zebra debug file.zbr` launches LLDB-DAP proxy;
  VS Code and ZebraIDE integration; `--listen PORT` mode for custom
  IDEs.

- **`zebra check` dead-code tool** — reports unused union arms and
  unreachable functions; selfhost has 3 deref workarounds.

- **REPL** — `zebra repl`; accumulate-and-rerun model; sentinel output
  isolation; `:help / :clear / :history / :load / :save`.

---

## [0.11] — 2026-04 / 2026-05

- **JSON auto-inference** — `Json.parse(T, src)` typed overload routes to
  `parseStrict` machinery; `@reflectable` required on the target struct.

- **Tuple / multi-return** — `(T1, T2)` type, `(a, b)` literal, `var (x,
  y) = f()` destructure; `.0` / `.1` index; TC element-type registration.

- **Generic functions** — `def identity(T)(x: T): T`; `comptime T: type`
  Zig emission; call-site flattening `identity(int)(42)` → `identity(i64,
  42)`; TC type-variable inference.

- **ImGui `LowLevel` sub-API** — `g.lowLevel.addLine / addRect /
  addRectFilled / addCircle / addCircleFilled / addText` (DrawList);
  `getWindowPos / Size / getCursorPos / getMousePos` → `(float, float)`
  tuple; `beginGroup / endGroup`.

- **Build system** — `zebra build` + `Build` stdlib module; `--build-file
  / --list-targets / b.target()`; selfhost TC / codegen parity.

---

## [0.10] — 2026-04

- **Self-hosting complete** — `zig-out/bin/zebra.exe` is now the selfhost
  binary compiled from `selfhost/main.zig`; `zig-out/bin/zebra-bootstrap.exe`
  is the Zig reference compiler. `tools/bootstrap_check.sh` verifies
  byte-identical round-trip (5 steps).

- **`@derive(Debug, Eq, Hash)`** — auto-generates `toString / eql / hash`
  on structs; both compilers.

- **WebSocket** — `Ws.connect / serve / send / recv / close` + `wss://`
  TLS; blocking `recv`; graceful close; both backends.

- **`DynLib`** — vtable shims; fat-pointer coercion; `DynLib.open / close /
  lookup`; plugin demo; both backends.

- **Optional chaining `?.`** — `x?.field`, `x?.method()` — short-circuits
  to `null` if `x` is null; both compilers.

- **Type aliases with constraints** — `type Name = BaseType where value > 0`;
  transparent emit; constraint injected after `var` init; `--turbo` strips
  checks.

- **Refinement types (parametric aliases)** — `type Bounded(lo, hi) = int
  where value >= lo and value <= hi`; value params bound into constraint;
  `Bounded(0, 100)` in type position.

- **`Chan(T)` / `sys.go()`** — see 0.14 entry (this was phased across
  0.10 and 0.14).

---

## [0.9] — 2026-04

- **Self-hosting Phase 22** (cutover-ready) — parity runner; error-compat
  fixtures; `zig build selfhost`; MISMATCH 13 → 0, PASS 67 → 86.

- **Named / default parameters** — `def f(x: int, y: int = 0)` and
  call-site `f(x: 1, y: 2)`; selfhost codegen parity.

- **Optional-unwrap `as` binding** — `if x as n`, `if x is T as n`; both
  compilers.

- **String intern pool** — `_str_pool` + `_intern`; auto-intern at
  `List / HashMap / str-field` sinks; eliminates `"" +` workaround in
  selfhost.

- **`for...else`** — list/.items / Zig-native `for…else` (Path 1);
  `while`-based loops use labeled block `_fels_N` (Path 2); both
  compilers.

- **`ensure` + `old` postconditions** — `defer`-based post-conditions;
  `old_` snapshot in selfhost `UnaryOp`; both compilers.

- **`static def / static var`** — renamed from `shared def / shared var`;
  208 files updated; top-level `def main()` + postfix `catch` also
  added.

---

## [0.8] — 2026-04

- **Self-hosting Phase 14–21** — `codegen.zbr` (1,879 lines); round-trip
  zero errors; cross-module struct patterns; `if-is-capture`; source-map
  line threading; Phase 22 parity sprint.

- **`IANA timezone`** — `DateTime.inZone("America/New_York")`; ~75 built-in
  zones; 4 DST rule families (US/EU/AU/NZ); dead-stripped if unused.

- **`allocate` Slices 1–4** — `Allocator` type; `allocate` block; scoped
  arenas; `<-` copy-out (Slice 4).

- **`zebra debug`** — initial DAP integration (see 0.12 for full notes).

---

## [0.7] — 2026-04

- **Self-hosting Phase 7–13** — `codegen.zbr`, `cg_helpers.zbr`,
  `main.zbr`, `astbuilder.zbr`, full multi-file pipeline; corpus 50% →
  100%.

- **`@derive`** — see 0.10 (first landed here, stabilized at 0.10).

- **Generic functions** — first landed here (see 0.11 for final form).

- **`for-loop` destructuring** — `for a, b in list_of_pairs`; arity error;
  `where` clause; both compilers.

- **Optional chaining** — first landed (see 0.10 for final form).

- **DynLib plugin** — first landed (see 0.10 for final form).

---

## [0.6] — 2026-04

- **Self-hosting Phases 1–6** — Token, Lexer, AST, Parser, Resolver,
  TypeChecker in Zebra; `selfhost/*.zbr` sources; ~41 compiler bugs fixed
  along the way.

- **`zebra check`** — dead-code detection; see 0.12.

- **`sys.spawn()` / `SysProcess`** — process launch + I/O capture;
  ZebraIDE Debug/Stop buttons.

- **`remove pro / get / set / body` keywords** — replaced by exposed fields
  and computed properties (commit 1990682).

---

## [0.5] — 2026-04

- **Zebra renamed** — language renamed from Cobra to Zebra (Zig + Cobra
  portmanteau); `.zbr` extension; repo extracted from `cobra-language`
  on 2026-04-16.

- **Visibility keywords** — `private / public / internal / protected`
  parsing added (enforcement in 0.13).

- **`static` keyword** — `static def / static var` class-level declarations.

- **`^T` heap indirection** — `^T` on struct fields auto-boxes on
  assignment, auto-derefs in `branch` arms.

- **`except` struct update** — `this except field = value, ...` immutable
  update idiom.

- **`@reflectable`** — opt-in reflection metadata; required for
  `Json.parse(T, src)`.

- **`Progress` stdlib** — `Progress.bar / tick / done` wraps
  `std.Progress`.

- **`Test` stdlib + `zebra test`** — test subcommand; `Test.pass / fail /
  assert / eq`.

---

## [0.4] — early 2026

- **`zebra repl`** — interactive REPL (first version; see 0.12 for
  polished form).

- **`Http.get / post`** — HTTP client; `HttpResponse.body / status /
  headers`.

- **`WebSocket`** — `Ws.connect / send / recv / close`; first version.

- **`Tcp`** — `Tcp.connect / send / recv / close`.

- **`Hash`** — SHA-256/512, MD5, Blake3, HMAC-SHA256.

- **`Random`** — `randInt / randFloat / randBool / choice / shuffle`;
  secure seed.

- **`DateTime`** — parse, format, `now()`, arithmetic; ISO 8601.

- **String interpolation** — `"Hello, {name}!"` syntax; `{expr:.2f}`
  format specs; `{/` escape.

- **`Arg`** — CLI argument parsing; `flag / option / positional / usage`.

---

## [0.3] — early 2026

- **Regex** — Thompson NFA + Laurikari TNFA; `r"pattern"` raw strings;
  `^/$` anchors; `{n,m}` quantifiers; `(?:...)` non-capturing groups;
  `\b` word boundary; named captures; flags `i/s/m`.

- **HTTP server** — `Http.serve(port, handler)` first version.

- **`Path`** — `join / dirname / basename / ext / isAbsolute`.

- **`File`** — `read / write / append / exists / delete / lines`.

- **`Json`** — `Json.parse / stringify / get / set / object / array`;
  first version.

---

## [0.2] — early 2026

- **JSON stdlib** — see 0.3 (first landed here).

- **`UDP` hostname fix** — DNS resolution for `Udp.send`.

- **String methods** — `padLeft / padRight / center` with fill-char.

---

## [0.1] — early 2026

Initial public language. Compiles `.zbr` source to native executables via
Zig. Features present at 0.1:

- **Core syntax** — `def`, `var`, `if/else`, `for`, `while`, `return`,
  `class`, `struct`, `union`, `branch`, `interface`, `extend`, `namespace`.

- **Type system** — `int / float / bool / str / byte`; `List(T)`;
  `HashMap(K, V)`; optional `T?`; `throws` / `anyerror!T`; `nil`
  tracking.

- **Error model** — `throws / raise / try / catch` exceptions;
  `_error_ctx` message; richer than Zig error enums.

- **`print`** — built-in statement; `println`.

- **`Math`** — trig, `pow / log / exp`, rounding, `abs / min / max /
  clamp`.

- **`Gui` stub backend** — `Gui.run(title, w, h, cb)` 4-arg frame-callback
  form; ImGui backend for native rendering.

- **CLI parsing** — `Arg.parse()`.

- **`sys.run(cmd)`** — shell-out; `SysRunResult.output / exit_code`.
