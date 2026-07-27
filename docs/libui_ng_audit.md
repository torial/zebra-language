# libui_ng GUI backend — verified-state audit

**Date:** 2026-07-27  **Auditor:** Opus 4.8 (Claude Code)
**Supersedes:** `docs/archive/libui_ng_audit_2026-05-25.md` (kept for its upstream
C-fork bug inventory; its capability matrix is stale — see §6).

## Why this audit exists

The libui_ng backend accreted a month of enthusiastic documentation while, until
**2026-07-27**, *no libui_ng executable had ever run* — the upstream dependency
did not compile under Zig 0.16, so every "works"/"complete"/"end-to-end tested"
claim was written against a program that had only ever been *emitted*, never
built-and-run. This audit separates what is **proven** from what is **asserted**.

### Verification tiers (used throughout)

Two independent axes. A widget can be fully WIRED yet NEVER-RUN.

**Implementation status** (what the code does):
- **WIRED** — real body that calls the `ui.*`/`sci.*` binding to do the thing.
- **PARTIAL** — does part; visibly drops or fakes some inputs.
- **STUB** — body is a no-op (`_ = arg;`) or returns a constant default.
- **ABSENT** — claimed somewhere, but no such function exists.

**Evidence status** (how far it's been proven):
- **RUN-VERIFIED** — observed working at runtime (states who/when/how).
- **COMPILE-VERIFIED** — the emitted Zig compiles + links under `zig` (the
  independent witness), but has never been executed.
- **NEVER-RUN** — no program has exercised this path at runtime.

The whole glue is at least **COMPILE-VERIFIED** as of 2026-07-27: `counter.zbr`
and `tears_of_the_tuon.zbr` both emit Zig that `zig build-exe` links to an
`app.exe` (the game proven from a *cold* cache — deps fetched fresh from GitHub).

---

## 1. Runtime verification ledger (the part that was missing)

| Program | Implementation exercised | Evidence | Status |
|---|---|---|---|
| `examples/counter.zbr` | window, root VBox, `text`(Label), `separator`, `button`×3, `sameLine` | Window renders **and `+`/`−`/`Reset` all change the count** — Sean-confirmed 2026-07-27; exits **0** | **RUN-VERIFIED (render + interaction)** |
| `examples/tears_of_the_tuon.zbr` | game view (difficulty-select: easy/medium/hard buttons) | **Window renders on screen** — Sean-confirmed 2026-07-27 | **RUN-VERIFIED (render)** |
| Everything else (checkbox, slider, entry, combobox, spinbox, progressbar, panel, all dialogs, CodeEditor/Scintilla) | — | Links into the exe; never instantiated at runtime | **NEVER-RUN** |

**What the runtime proof now covers:** counter's `+`/`−`/`Reset` buttons all
change the count (Sean, 2026-07-27), so the **full MVU round-trip is
RUN-VERIFIED** — button-click latch → `update` → model change → `Label.SetText`
re-render, driven by `uiMainStep`. The game's difficulty-select screen also
renders. This exercises: window, root VBox, Label(dynamic), Separator, Button +
its click callback, and the MVU loop. Button interaction proven via counter
applies to the game's buttons (same code path); the game's *own* flow past the
first screen (does clicking "easy" start play?) is not separately confirmed.

**Still true — "renders" ≠ "renders as authored":** `counter.zbr` calls
`g.sameLine()` between its buttons, and `sameLine` is a **no-op stub** in libui
(§3), so the three buttons stack **vertically** instead of inline. The behavior
is correct; the layout is not what the source asks for.

---

## 2. The root-cause fix that unblocked runtime (2026-07-27)

**Symptom:** counter + game both exited **57** under `zig build run` with no
window (Sean: "nothing happened").

**Cause:** libui is linked **statically**. libui-ng embeds the Common-Controls
v6 application manifest only in a **shared** build — `windows/resources.rc`
guards it behind `#ifndef _UI_STATIC` and the source comments *"static builds
have to include the appropriate parts of the manifest in the output
executable."* The emitted consumer exe supplied none, so comctl6 was inactive
and window/control creation failed at init.

**Fix (commit `596e9d1`):** `luiBuildZig` now sets
`.win32_manifest = b.path("app.manifest")`, and `compileGuiProject` writes
`app.manifest` (comctl6 dependency, taken from libui-ng's own
`test/test.static.manifest`) into the scaffold unconditionally.

**Result:** counter runs exit 0 and the window appears (Sean-verified). Clean
before/after — the exit code went 57 → 0 with only the manifest added.

---

## 3. Glue inventory — `selfhost/gui_libui_ng_section.zig`

This file is the **active** libui_ng path: since the 2026-07-26 selfhost-GUI
epic, `--gui-backend=libui_ng` routes through the selfhost (`gui_selfhost =
tui | libui_ng`, `main.zbr:2267`) and this section is substituted into the
emitted Zig at runtime. (The bootstrap's `src/CodeGen.zig` libui arm still
exists but is **no longer the path taken** — docs describing "the ~300-line
preamble in CodeGen.zig" describe the retired route.)

Every `ui.*`/`sci.*` call the glue makes **exists in the binding** (cross-checked
against `zig-libui-ng/src/*.zig`) — no phantom calls, consistent with it linking.

### WIRED (real implementation)

| Feature | Notes |
|---|---|
| Window + close handler + 100 ms poll timer | `_lui_init`/`_lui_deinit` |
| MVU run loop (`_gui_run`, `_gui_mvu_run`) | 32-slot msg queue, view→drain→update/frame |
| VBox / HBox | id-cached, stretch append |
| Group / **Panel** (`beginPanel`/`endPanel`) | `uiGroup` + inner VBox |
| Button, Checkbox, Slider, Entry, Combobox, Spinbox | real widget + change/click callback |
| Label (`text`), Separator (horizontal) | dynamic `SetText` each frame |
| **File dialogs**: openFile, saveFile, openFolder, msgBox, msgBoxError | native modals via `ui.Window.*` |
| CodeEditor: new, setText, getText, setReadonly, render, getCursorLine, getCursorCol | via `sci` (Scintilla) |
| All event callbacks (`_lui_*_cb`) | button/checkbox/slider/entry/mle/combobox/spinbox |

### PARTIAL (works but drops inputs)

| Feature | What's dropped |
|---|---|
| MultilineEntry | width/height args ignored; 1 KB text cap |
| ProgressBar | label arg discarded; value clamped 0–100 |
| textColored | **color faked** — renders a plain Label |
| CodeEditor.render | `id`, width, height, context all discarded |
| CodeEditor.setCursorPosition | **column ignored** — only line honored |
| lowLevel.getWindowSize | returns stored init size, not live window size |

### STUB (no-op — present in API, does nothing)

`sameLine`, `spacing`, `indent`/`unindent`; `selectable` (always false);
`beginWindow`/`endWindow` (nested windows); **entire Table API** (beginTable,
setupColumn, headersRow, nextRow, nextColumn, endTable — no `ui.Table` binding
used at all); `treeNode`/`treePop`; `beginChild`/`endChild` (scroll regions);
all theming (`setColor`, `setColorsDark`, `setStyleFloat`, `setVec2`,
`scaleAllSizes`); `getDpi` (hardcoded `1.0`); **entire low-level immediate draw
API** (addLine/Rect/RectFilled/Circle/CircleFilled/Text + cursor/mouse pos);
**`CodeEditor.setErrorMarkers` (pure no-op)**.

### ABSENT

`Grid` — no glue function or backend slot exists (the binding has `ui.Grid`, but
the Zebra glue never wires it).

---

## 4. The binding — `torial/zig-libui-ng@main` (commit `8677b01`)

Consolidated 2026-07-27 (wp base + zig-0.16's sci/scintilla + Zig-0.16 fixes),
single `main` branch, **public**. API surface is essentially **complete libui
coverage**: Window (+ all file dialogs), all layout (Form/Box/Grid/Group/
Separator/Tab), all buttons (Button/Color/Font), all inputs (DateTimePicker/
Checkbox/Combobox/RadioButtons/Slider/Spinbox), text (Entry/Label/MultilineEntry/
EditableCombobox), menu, table, draw. **The binding is not the limiting factor —
the Zebra glue (§3) wires only a subset.**

**`sci` module (Scintilla):** thin, real, 33 lines — `new`, `setText`,
`getLength`, `getRange`, `sendMessage`, `as_control` over libui-scintilla's C
API. `luiBuildZig` always links it, so Scintilla **compiles + links into every
libui_ng exe** — but no program has created a Scintilla control at runtime, so
the CodeEditor is **NEVER-RUN**. No lexer/highlighting is wired
(`CodeEditor.forZebra` falls back to plain; `setErrorMarkers` is a no-op).

## 5. The C fork — `torial/libui-ng@main` (commit `85976bc`)

Single `main` branch, **public**, carries the vendored `uiRect` struct (from
petabyt/libui-dev) that the whole GitHub chain depends on. Its unique work over
upstream: a **Haiku backend** (5 commits — irrelevant on Windows), libui-dev
extras (placeholder text, `DrawBitmap` decl, `ui_safe.h`, Issue #308 fix), Zig
0.16 build compat, float spinbox + file-dialog params, and a Windows
`InitCommonControlsEx` robustness fix. Remotes retained for six upstreams
(kojix2, petabyt/libui-dev, libui-ng master, nicowillis, origin) — useful for
future rebases; not a build concern.

---

## 6. Claims-vs-facts corrections (the punch list)

Adjudicated from the doc catalog against the verified glue. **The recurring
pattern: capability was wired in later than the audit/design docs, and separately
"runtime" was claimed before anything ran.** Two failure directions:

### 6a. Stale-PESSIMISTIC — docs say STUB/absent; reality is WIRED

The May-25 audit and `gui_mvu_design.md` predate the ProgressBar/Combobox/
Spinbox/Panel/file-dialog wiring:

| Feature | Stale claim | Verified fact |
|---|---|---|
| beginPanel/endPanel | "stub" (archived audit A27–A28; gui_mvu_design G10) | **WIRED** (`uiGroup`, glue 636–656) |
| ProgressBar | preamble "–" absent (archived A41) | **WIRED/PARTIAL** (label dropped) |
| Combobox, Spinbox | preamble "–" absent (archived A41) | **WIRED** |
| File dialogs | preamble "–" absent (archived A44) | **WIRED** (all five) |

`gui_mvu_design.md` header "**both backends complete**" / "libui-ng status ✅
Complete (2026-05-22)" describes emit-completeness, not a running program.

### 6b. Stale-OPTIMISTIC — docs assert runtime; nothing had run

| Source | Claim | Verdict |
|---|---|---|
| `CHANGELOG.md:84` | "`--gui-backend=libui_ng` — **end-to-end tested**; `counter.zbr` opens a native Win32 window." | **FALSE when written** (libui_ng could not build). **Now TRUE** for the render, post-manifest (2026-07-27). Reword to date the evidence. |
| `NEXT_STEPS.md:107` | "works end-to-end 2026-07-27" | TRUE for counter render; the same block correctly narrows it to compile+link elsewhere — tighten to one story. |

### 6c. Contradictory dependency pins (three docs, three commits)

| Doc | Pin named as "the" pin |
|---|---|
| `docs/UI_QUICKSTART.md:233` | `zig-libui-ng` `d99a49c` |
| `docs/gui_mvu_design.md:74` | `zig-libui-ng` `39665dc`, libui-ng `5c24fd66` |
| **Actual (2026-07-27)** | **`zig-libui-ng@main 8677b01` → `libui-ng@main 85976bc`** |

Both older pins are stale; `luiBuildZon` in `selfhost/main.zbr` is the single
source of truth now.

### 6d. Correct-as-written (no change)

`QUICKSTART.md` §30 and `docs/UI_QUICKSTART.md` are accurate on the STUBs
(sameLine/table/tree/color/low-level no-ops; selectable false; CodeEditor col
ignored / setErrorMarkers no-op / no highlighting). `project_zebra.md` wiki line
was refreshed 2026-07-27 and matches.

---

## 7. IDE readiness (Sean's question: "recover/merge Scintilla for an IDE")

**Nothing to recover — Scintilla is already present and wired**, and
`IDE/ZebraIDE.zbr` already uses `codeEditor`. What's actually true:

- **Present & compiles+links:** the `sci` module + `_CodeEditor` glue (create,
  set/get text, readonly, cursor line/col via raw Scintilla messages).
- **NEVER-RUN:** no program has instantiated a Scintilla control, so the editor
  pane is unproven at runtime — the single most valuable next verification for
  the IDE thread is to build+run `IDE/ZebraIDE.zbr --gui-backend=libui_ng` and
  confirm the editor appears.
- **Genuinely missing for an IDE:** syntax highlighting / lexer setup (not
  wired), error markers (`setErrorMarkers` is a no-op), fixed column in
  setCursorPosition, and any Table/Tree (file-explorer) widget — all STUB/absent.

**Bottom line:** the IDE substrate exists at the compile level; the gap is
runtime verification + the highlighting/markers/tree features that a real editor
needs, none of which are "lost" — they're unbuilt.

---

## Appendix — verification commands

```bash
# emit + build + run a libui_ng program (window appears on an interactive session)
zig-out/bin/zebra.exe --gui-backend=libui_ng examples/counter.zbr

# prove portability cold (both deps fetched fresh from GitHub)
ZIG_GLOBAL_CACHE_DIR=/c/tmp/cold zebra.exe --gui-backend=libui_ng examples/counter.zbr
```
