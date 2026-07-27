# libui-ng Ecosystem Audit

*Generated 2026-05-25 against torial/libui-ng (wp-2025), torial/zig-libui-ng (zig-0.16),
libui-ng/libui-ng (master, last code commit Aug 2024), petabyt/libui-dev (frontier fork),
and kojix2/libui-ng (111 commits ahead of master, last pushed 2026-05-24).*

---

## Repository map

| Repo | Branch / tag | Role |
|---|---|---|
| `libui-ng/libui-ng` | master | Canonical upstream — **effectively abandoned** (no code commits since Aug 2024) |
| `petabyt/libui-dev` | master | Frontier fork: new APIs (placeholder, bitmap, Qt5). Only 3 kojix2 fixes merged. |
| `kojix2/libui-ng` | main / dev | **The real bug-fix upstream.** 111 commits ahead. Binary release pipeline. Last pushed 2026-05-24. |
| `kojix2/libui-ng` | dev | 119 commits ahead — adds `uiImageView` widget (all 3 platforms) |
| `torial/libui-ng` | `wp-2025` | **Our C fork** — 2 commits ahead of libui-ng master; misses ~108 kojix2 fixes |
| `desttinghim/zig-libui-ng` | main | Original Zig bindings parent |
| `torial/zig-libui-ng` | `zig-0.16` | **Our Zig bindings** — strict superset of desttinghim; pins old C lib |

**Critical correction from first pass:** kojix2 is NOT merely a contributor. They maintain a
real, actively pushed fork (`kojix2/libui-ng`) that is 111 commits ahead of upstream with
~100 original bug fixes across all three platforms. They also have a `kojix2/libui-dev` fork
of petabyt's frontier fork, but it is 5 commits *behind* petabyt and contains no unique work.
Their primary output is the main fork + a binary release pipeline (28 pre-built assets per
release: Win x64/x86 MSVC, macOS arm64/x86_64, Linux x86_64/aarch64).

The practical upstream hierarchy is therefore:
1. `kojix2/libui-ng` (main) — bug fixes; most correct C library
2. `petabyt/libui-dev` — new APIs; only 3 kojix2 fixes absorbed
3. `libui-ng/libui-ng` — canonical but abandoned; don't use as reference

Our `torial/libui-ng` is currently rebased on libui-ng/master and is therefore missing
all 111 kojix2 fixes and only 3 of them exist in petabyt/libui-dev.

---

## What our forks added (our two commits ahead of upstream)

### torial/libui-ng (wp-2025)

| Commit | What it fixes | Why it matters |
|---|---|---|
| `de1b1305` | `Build.Module` API fix — Zig build.zig for the C library | Required for Zig 0.16 package import |
| `5c24fd66` | `InitCommonControlsEx` returns FALSE on some Win11 configs → made non-fatal (code 0 only) | Without this, `uiInit` crashes on vanilla Win11 systems |

Neither fix exists in libui-ng/master or libui-dev.

### torial/zig-libui-ng (zig-0.16)

| Commit | What it fixes |
|---|---|
| `fe1d7fa` | `callconv(.C)` → `callconv(.c)` — Zig 0.16 renamed this; fixed at 72 call sites |
| `95d01af` | `OnToggled` comptime function parameter + removed `void` catch |
| `39665dc` | Dependency hash update to match patched C fork |

**Extensions beyond desttinghim parent** (features we added, not in any other Zig binding):
- `uiSpinboxValueDouble` / `uiSpinboxSetValueDouble` — float-precision spinbox
- `uiSpinboxValueText` — string representation of spinbox value
- `uiOpenFileWithParams` / `uiOpenFolderWithParams` / `uiSaveFileWithParams` — parameterised file dialogs
- Full `uiTable` / `uiTableModel` / `uiTableValue` API
- `uiImage` / `uiNewImage` / `uiImageAppendPixels`
- `sci` module — Scintilla code editor via libui-scintilla (Windows-only build currently)

---

## Full widget / feature matrix

"**✓**" = present and correct. "**–**" = absent. "**≈**" = partial / stub.
"**✓\***" = present with bug fixes beyond what other repos have.

### Controls

| Widget / API | libui-ng master | kojix2 main | libui-dev | torial C fork | torial Zig | Our preamble |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Window | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| VBox / HBox | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Button | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Checkbox | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Entry (single-line) | ✓ | ✓* (UTF-16 caret fix, SetText sentinel fix) | ✓ | ✓ | ✓ | ✓ |
| MultilineEntry | ✓ | ✓* (disabled state fix, suppress-while-editing fix) | ✓ | ✓ | ✓ | ✓ |
| Label | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Separator (H + V) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (H only) |
| Slider | ✓ | ✓* (tooltip from mohad12211, all platforms) | ✓ | ✓ | ✓ | ✓ |
| Spinbox (int) | ✓ | ✓* (enable/disable fix macOS+Win) | ✓ | ✓ | ✓ | – |
| Spinbox (double) | – | – | – | – | ✓ (our ext) | – |
| ProgressBar | ✓ | ✓* (timer ID mismatch fix, indeterminate row shift) | ✓ | ✓ | ✓ | – |
| Combobox | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| EditableCombobox | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| RadioButtons | ✓ | ✓* (validate index fix, enable/disable propagation) | ✓ | ✓ | ✓ | – |
| Tab | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| Tab.OnSelected callback | ✓ (Aug 2024) | ✓ | ✓ | ✓ | – | – |
| Tab.Selected / SetSelected | ✓ | ✓ | ✓ | ✓ | – | – |
| Group | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| Form | ✓ | ✓* (spinbox baseline fix) | ✓ | ✓ | ✓ | – |
| Grid | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| Grid.Delete / NumChildren | ✓ | ✓ | ✓ | ✓ | – | – |
| DateTimePicker | ✓ | ✓* (segfault/use-after-free fix, AM/PM state fix, NULL mouse guard) | ✓ | ✓ | ✓ | – |
| DateTimePicker.Destroy | – | ✓ (kojix2 PR #4 → libui-dev) | ✓ | – | – | – |
| ColorButton | ✓ | ✓* (brush failure handling, callback safety, dealloc fix) | ✓ | ✓ | ✓ | – |
| FontButton | ✓ | ✓* (DirectWrite dialog guard) | ✓ | ✓ | ✓ | – |
| **Entry placeholder text** | – | – | ✓ | – | – | – |
| **EditableCombobox placeholder** | – | – | ✓ | – | – | – |
| Menu + MenuItem | ✓ | ✓* (prevent adding items post-finalization, macOS) | ✓ | ✓ | ✓ | – |
| Image | ✓ | ✓* (WIC failure fix, HBITMAP cleanup, append input validation) | ✓ | ✓ | ✓ (our ext) | – |
| **ImageView widget** | – | ✓ (dev branch only) | – | – | – | – |
| **Table + TableModel** | ✓ | ✓* (image list cleanup, selection ownership, text null-term) | ✓ | ✓ | ✓ (our ext) | – |
| Table progress-bar column | – | ✓ (kojix2 PR #3 → libui-dev) | ✓ | – | – | – |
| **Scintilla CodeEditor** | – | – | – | – | ✓ (our ext, Win-only) | ✓ (Win-only) |
| Tooltip | – | ≈ (stalled PR #266) | – | – | – | – |
| uiAreaScrollTo | – | ✓ (Win + Unix) | – | – | – | – |

### Drawing API (uiArea)

| Feature | libui-ng master | kojix2 main | libui-dev | torial C | torial Zig | Our preamble |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Area (draw surface) | ✓ | ✓* (many D2D hardening fixes) | ✓ | ✓ | ✓ | – (no-op) |
| ScrollingArea | ✓ | ✓* (resize rejection fix) | ✓ | ✓ | ✓ | – |
| Mouse events | ✓ | ✓* (DIP scaling, inside-state on enter, double-click distance) | ✓ | ✓ | ✓ | – |
| Keyboard events | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| Path / fill / stroke | ✓ | ✓* (clip path/layer, stroked path guard) | ✓ | ✓ | ✓ | – |
| uiDrawTransform | ✓ | ✓* (matrix invertibility check by determinant) | ✓ | ✓ | – | – |
| uiDrawClip | ✓ | ✓* (clip to update rect) | ✓ | ✓ | – | – |
| uiDrawSave / Restore | ✓ | ✓* (drawing state block error handling) | ✓ | ✓ | – | – |
| **uiDrawArc** | – | ✓* (sweep direction fix, kojix2 PR #5 → libui-dev) | ✓ | – | – | – |
| **uiDrawBitmap (raster)** | – | – | ✓ | – | – | – |
| **uiDrawImage** | – | ✓ (dev branch only) | – | – | – | – |
| **OpenGL Area** | – | – | ≈ (extras, GLX) | – | – | – |
| AttributedString / RichText | ✓ | ✓* (9 correctness fixes: insertion order, overlapping attrs, range intersection, grapheme validation, etc.) | ✓ | ✓ | ✓ | – |

### File dialogs

| Feature | libui-ng master | kojix2 main | libui-dev | torial C | torial Zig | Our preamble |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| OpenFile / SaveFile (basic) | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| OpenFolder (basic) | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| OpenFileWithParams | – | – | – | – | ✓ (our ext) | – |
| OpenFolderWithParams | – | – | – | – | ✓ (our ext) | – |
| SaveFileWithParams | – | – | – | – | ✓ (our ext) | – |

### Platform / build

| Feature | libui-ng master | kojix2 main | libui-dev | torial C | torial Zig |
|---|:---:|:---:|:---:|:---:|:---:|
| Win32 backend | ✓ | ✓* | ✓ | ✓ | – |
| GTK3 backend | ✓ | ✓* | ✓ | ✓ | – |
| Cocoa (macOS) backend | ✓ | ✓* | ✓ | ✓ | – |
| GTK4 backend | – | – | – | – | – |
| **Qt5 backend** | – | – | ≈ (49 files, paint works, input incomplete) | – | – |
| Meson build | ✓ | ✓ | ✓ | ✓ | – |
| Zig build.zig | ≈ (broken 0.16) | – | – | ✓ (our fix) | ✓ |
| **InitCommonControls non-fatal** | – | – | – | ✓ (our fix) | ✓ (via dep) |
| Pre-built binaries | – | ✓ (28 assets per release) | – | – | – |
| HiDPI / DPI scaling | – | – | – | – | – |
| Dark mode (Win/Mac) | – | – | – | – | – |
| Thread-safety wrappers (ui_safe.h) | – | – | ✓ (extras) | – | – |
| Unit test suite (attrstr + more) | – | ✓ | – | – | – |

---

---

## kojix2/libui-ng — complete fix inventory

**111 commits ahead of libui-ng/master. Last pushed 2026-05-24.**
**Only 3 of these are in petabyt/libui-dev. The other ~108 are exclusively in kojix2/libui-ng.**

Fork description: "Our primary focus is on building and distribution rather than development."
This undersells it — the commit log shows substantial original correctness work.

### Windows-specific (D2D / Win32)

The Windows category is the most extensive and the most valuable for us (Win32 is our
primary dev platform). Most of these are error-handling hardening that prevents silent
failures and resource leaks:

- **uiEntry UTF-16 caret position fix** — caret lands at wrong position when text contains non-ASCII
- **uiEntry / uiMultilineEntry `SetText` EM_SETSEL sentinel** — robustness fix for end-of-text selection
- **Window text length handling** — robust against large/unusual title strings
- **Area: DIP-scaled double-click distance** — double-click detection correct at non-100% DPI
- **Area: scroll coordinates in DIPs** — scroll events use device-independent pixels
- **Area: clip drawing to update rect** — prevents rendering artefacts outside dirty region
- **Area: inside-state on mouse enter** — fixes hover detection when cursor enters window from outside
- **Area: input without render target** — guard against crash when area receives input before first paint
- **Area: reject resizing non-scrolling areas** — prevents invalid state
- **Arc drawing sweep direction** — matches Unix/Mac direction (PR #5, also in libui-dev)
- **uiAreaScrollTo implementation** — programmatic scroll (was a stub; now real)
- **uiImageAppend: WIC failure handling** — safe error path when Windows Imaging Component fails
- **uiImageAppend: HBITMAP cleanup** — prevents GDI handle leak on failure
- **Table image list cleanup** — fixes GDI object leak in Windows table widget
- **Table: indeterminate progress row shift** — rendering fix
- **Table: timer ID mismatch** (PR #3, also in libui-dev)
- **Table: null-terminate display text** — prevents potential overread
- **ColorButton: brush creation failure** — safe error path
- **Font dialog: DirectWrite guard** — prevents crash on font dialog failure
- **Direct2D comprehensive hardening** (~20 commits):
  - HWND render target creation/recreation error paths
  - DC render target error paths
  - Path creation failure guards
  - Clip path and clip layer error handling
  - Drawing state block error handling
  - Text layout creation failure guards
  - COM out-parameter initialization
  - Render target leak fix in uiArea
- **uiTimer: clean up all timers on `uiUninit`** — prevents dangling timer callbacks after shutdown
- **Allocator: detect invalid pointers before map lookup** — prevents crash on corrupted state
- **Allocator: zero-size handling** — safe behavior for zero-byte allocations
- **Hollow brush: stop deleting stock object** — Windows stock objects must not be deleted (was a GDI bug)
- **WM_WININICHANGE: erase registrations on unregister** — prevents stale message handlers
- **Reject freeing table models still in use** — prevents use-after-free
- **uiColorButton underline color attribute release** — prevents COM leak

### Darwin/macOS-specific

- **Text centering via CTFrame constraint width** (PR #342, closed without merge upstream)
- **ColorButton: init order + callback safety** — crash prevention during init
- **ColorButton: deactivate on dealloc** — prevents callback into freed object
- **Prevent menu items after finalization** — prevents crash when app adds menu items too late
- **MultilineEntry: suppress changes while editing** — prevents spurious callbacks
- **MultilineEntry: apply disabled state** — disabled state was silently ignored on macOS
- **Area tracking and button masks** — fixes mouse button state tracking
- **Menu item checked state** — explicit set vs. toggle
- **Table: column/cell view/grid empty cell view leaks** — NSView memory leaks
- **Table: selection index set release** — NSIndexSet leak
- **ColorButton color conversion guard** — safe path on NULL/invalid NSColor
- **NULL CoreGraphics colors in attributed strings** — prevents crash on unusual system configs
- **Clear temporary font attrs** — prevents stale attribute state
- **Clean up active timers during uninit** — prevents dangling timer callbacks
- **Font variation axes release** — prevents CFArray leak
- **Matrix invertibility check by determinant** — numerically correct guard for singular matrices
- **Tab page identifier release** — CFString leak
- **Combobox: unbind contentValues on destroy** — KVO cleanup prevents crash on dealloc
- **uiImageAppend: avoid NULL bitmap writes** — prevents crash on failed image conversion
- **Stroked path creation guard** — safe error path
- **Form spinbox baseline alignment** — visual alignment fix
- **Spinbox enable/disable** — was silently ignored on macOS
- **RadioButtons enable/disable propagation** — state change didn't propagate to child buttons

### Unix/GTK-specific

- **DateTimePicker segfault on destroy** (use-after-free on widget teardown; also PR #4 → libui-dev)
- **DateTimePicker: NULL mouse guard** (most recent commit, 2026-05-24)
- **DateTimePicker: AM/PM state on SetTime** — 12-hour clock state was wrong after programmatic set
- **Image append failure handling** — safe error path
- **Timer source cleanup on uninit** — prevents GLib source leak
- **Table selection snapshot ownership** — prevents use-after-free
- **Image append input validation** — reject invalid dimensions/stride early
- **Reject freeing table models in use** — mirrors the Win32 fix
- **Redraw areas on size allocation** — areas weren't repainting on resize
- **uiAreaScrollTo implementation** — programmatic scroll (stub → real)
- **Table progress state across row changes** — indeterminate state lost on row update

### Cross-platform

- **RadioButtons: validate index** (all 3 platforms) — out-of-range index crashes prevented
- **Slider tooltip** (from mohad12211, upstream PR #305 not merged) — tooltip showing current value

### New features (dev branch only)

- **`uiImageView` widget** — native image display widget, all 3 platforms (~650 lines new C across
  darwin/imageview.m, unix/imageview.c, windows/imageview.cpp). PR #334, closed without merge.
- **`uiDrawImage`** — draw an image into a `uiArea` drawing context

### PR history (kojix2 → libui-ng/master)

| PR | Content | Outcome |
|---|---|---|
| #342 | darwin: text centering fix | Closed, NOT merged |
| #341 | windows: arc sweep direction | Closed, NOT merged |
| #339 | unix: DateTimePicker segfault | Closed, NOT merged |
| #334 | uiImageView new widget | Closed, NOT merged |
| #324 | windows: progress bar timer ID | Closed, NOT merged |
| #291 | windows: static lib suffix | Closed, NOT merged |
| #272 | windows: separator orientation | **Merged** 2024-05-03 |
| #271 | windows: time string length | **Merged** 2024-05-03 |
| #269 | ci: actions version | **Merged** 2024-02-06 |
| #215/#214/#150 | CI improvements | **Merged** various |

All substantive bug-fix and feature PRs have been rejected by the upstream maintainer.
The upstream is not just quiescent — it appears to actively not accept external fixes.
kojix2's fork is therefore the canonical correct version of the C library.

---

## Recommended fork strategy

Given the above, our current approach of rebasing `torial/libui-ng` on `libui-ng/master`
is wrong. The correct strategy:

**Option A (rebase on kojix2):** Rebase `torial/libui-ng` (wp-2025) on top of
`kojix2/libui-ng` main. We'd bring in all 111 bug fixes plus retain our 2 original
commits (InitCommonControls non-fatal, Zig build fix). This is the recommended path.

**Option B (cherry-pick):** Selectively cherry-pick the most important kojix2 fixes
into our current wp-2025 branch. More surgical but requires ongoing maintenance
divergence.

**On the Zig bindings:** `torial/zig-libui-ng` currently pins `desttinghim/libui-ng`
(not kojix2's C library). To pick up kojix2's fixes, the `build.zig.zon` dependency
in our Zig bindings needs to point at a `kojix2/libui-ng` release tag or commit hash.

---

## What our preamble implements vs stubs

The ~300-line libui-ng preamble in `src/CodeGen.zig` wires the Zebra `GuiContext` API to
libui-ng widgets via a retained-mode adapter (frame 0 = creation, frames 1+ = event-driven).

### Fully implemented
- Window creation + close handler
- VBox/HBox layout with stack (32-deep push/pop)
- Button → `_LuiMut.clicked` latch
- Checkbox → `_LuiMut.checked`
- Slider → `_LuiMut.sval` (0–1000 integer, remapped to f64 range)
- Entry (single-line) → `_LuiMut.text_buf`
- MultilineEntry → `_LuiMut.text_buf`
- Label (dynamic text updates every frame via `SetText`)
- Separator (horizontal)
- Timer heartbeat (100 ms poll tick keeps `uiMainStep` unblocking)
- Scintilla CodeEditor (Windows-only, via `sci` module)

### No-ops (Zebra API exists; libui-ng not wired)

These call through `_GuiBackend` fn-pointers but the libui-ng implementation is a no-op.
Implementing them in the preamble is the work needed to close each gap.

| Zebra call | libui-ng equivalent | Notes |
|---|---|---|
| `g.sameLine()` | – | libui-ng has no inline layout; HBox is the correct answer |
| `g.spacing()` | – | Could use a fixed-height label or padding |
| `g.indent()` / `g.unindent()` | – | Could use a nested HBox with padding |
| `g.beginPanel()` / `g.endPanel()` | `uiGroup` | Labelled container — straightforward |
| `g.beginWindow()` / `g.endWindow()` | `uiWindow` | Multi-window; non-trivial lifecycle |
| `g.selectable(l)` | No direct equivalent | Could use button with styling |
| `g.textColored(r,g,b,a,s)` | No colour on Label | Falls back to plain `_lui_text` |
| `g.beginTable()` … | `uiTable` + `uiTableModel` | Complex but fully bound in our Zig layer |
| `g.beginChild()` / `g.endChild()` | ScrollingArea | Reasonable mapping |
| `g.treeNode()` / `g.treePop()` | No equivalent | Would need a recursive HBox pattern |
| `g.setColor()` / `g.setColorsDark()` | No runtime theming API | libui-ng uses OS theme |
| `g.scaleAllSizes()` | `uiSetDpiScale(?)` | No equivalent in libui-ng yet |
| `g.getDpi()` | No API | Returns 1.0 |
| All `g.lowLevel.*` draw calls | `uiArea` + `uiDrawPath` | Area is bound; preamble never creates one |

---

## The 9 missing Zig bindings (vs our C fork headers)

These functions exist in `ui.h` in `torial/libui-ng` but are not yet declared in
`torial/zig-libui-ng/src/ui.zig`:

| Function | Widget | Priority |
|---|---|---|
| `uiTabSelected(t)` | Tab | Medium — needed for programmatic tab selection |
| `uiTabSetSelected(t, n)` | Tab | Medium |
| `uiTabOnSelected(t, f, data)` | Tab | **High** — callback added Aug 2024, standard UX |
| `uiGridDelete(g, c)` | Grid | Low — rarely needed |
| `uiGridNumChildren(g)` | Grid | Low |
| `uiDrawTransform(c, m)` | Area | Low — drawing not yet wired |
| `uiDrawClip(c, path)` | Area | Low |
| `uiDrawSave(c)` | Area | Low |
| `uiDrawRestore(c)` | Area | Low |

---

## What libui-dev adds that we should pull eventually

These are in `petabyt/libui-dev` but not in any other repo. Ordered by value to us:

### High value — pull when needed

1. **`uiEntryPlaceholder` / `uiEntrySetPlaceholder`** — greyed hint text. All three
   platforms implemented. Simple to add to our C fork (`ui.h` + 3 platform files).
   Useful for any form UI.

2. **`uiEditableComboboxPlaceholder` / `...SetPlaceholder`** — same for editable combobox.

3. **`uiDateTimePickerDestroy`** (kojix2 PR #4) — canonical destructor was missing.
   Should pull; prevents a memory leak when date picker widgets are removed.

4. **Thread-safety wrappers (`extras/ui_safe.h`)** — queues UI calls from non-main
   threads. Essential for any Zebra GUI app that updates UI from a background
   thread (network response, timer callback). Worth pulling into our fork when
   Zebra gets async/await or multi-threaded GUI patterns.

### Medium value — track, pull later

5. **`uiDrawArc`** (kojix2 PR #5) — arc drawing primitive for the Path API.
   Needed once we wire Area draw into the Zebra low-level API.

6. **`uiDrawBitmap` API** — new raster image drawing layer for Area surfaces.
   `uiNewDrawBitmap`, `uiDrawBitmapUpdate`, `uiDrawBitmapDraw`, `uiDrawFreeBitmap`.
   Clean API design. Pull when we want image display in draw surfaces.

7. **Table progress-bar column** (kojix2 PR #3) — `uiTableValueType` extended with
   a progress bar display column type. Useful for file manager / task UIs.

### Low value / speculative

8. **OpenGL Area** (`extras/openglarea_orig.c`) — `uiNewOpenGLArea` via GLX on Unix.
   Lives in extras, not integrated into main build. Pull if we ever want GPU rendering
   in a native window (unlikely — we have the GLFW/ImGui path for that).

---

## Future value items (don't need now, worth tracking)

### Qt5 backend (libui-dev)

49 C++ files in `ui/qt5/`. State: paint/draw works, input event translation is
incomplete (Qt key codes → `uiAreaKey`, scroll handling), window resize propagation
is a stub. Estimated 2–4 days of C++ work to complete. 

**Why it matters:** eliminates the GTK3 dependency on Linux, enabling deployment on
systems without a GTK runtime (servers, embedded, minimal distros). Also opens
Qt-themed apps.

**Decision:** Track in this doc. Do not port until GTK3 becomes a real deployment
pain point.

### GTK4 backend

Nobody has attempted this in any fork. GTK3 is deprecated on Fedora 40+ and Ubuntu
24.04 ships with GNOME/GTK4 as default. This is a multi-week project (different
widget lifecycle, different drawing model). **Highest long-term risk for libui-ng
relevance on Linux.**

### HiDPI / DPI scaling (Windows)

Issue #294 in libui-ng: controls and text pixelated at Windows display scaling >100%.
Win10/11 defaults to 125–150% on modern laptops. No fix in any fork. Requires
`SetProcessDpiAwarenessContext` + manifest. **Will bite users on modern hardware.**

### Dark mode

No fork has dark mode. Windows: `DWMWA_USE_IMMERSIVE_DARK_MODE`. macOS: system
handles it for most widgets but some need explicit handling. Long-term UX debt.

### `uiInitOptions` NULL crash fix (Issue #308)

Passing NULL to `uiInit` crashes; it should use defaults. One-line fix on all three
platforms. Trivial to include in our fork at any time.

### Zebra port of libui-ng

The user has asked whether libui-ng could eventually be ported to Zebra. The library
is ~15,000 lines of C (plus platform backends). Key blockers:
- Requires `^T` (heap pointer) types for widget tree — **already supported in Zebra**
- Requires C FFI for OS calls (Win32/GTK/Cocoa) — Zebra has `zig_lit` escape hatch
- Callbacks with void* userdata — manageable with Zebra's `capture` blocks
- Multi-platform `#ifdef` structure — would need Zebra compile-time conditions

Verdict: possible but low priority. The C library is stable and our Zig bindings
insulate us from it. A Zebra port would be a good stress-test of the language but
offers no immediate value.

---

## Decisions (2026-05-25)

**Fork strategy confirmed:**
- Rebased on kojix2/main (111 fixes) — merged as `wp-2025-v2` branch in `torial/libui-ng`
- libui-dev non-Qt additions merged directly into `wp-2025-v2` (not a separate repo — C extensions can't be truly additive, single C fork is cleaner to pin)
- `torial/zig-libui-ng` updated to pin `wp-2025-v2`; all 9 missing bindings added
- `zebra-language/src/main.zig` updated to emit the new `zig-libui-ng` commit hash

**DPI scaling:** tracked as future task; Windows manifest for better UI controls pending (see future section)

**Dark mode:** 1.5 release target; user doesn't use dark mode personally

**GTK4 backend:** explicitly deferred — low priority

**Qt5 backend:** monitor libui-dev for progress; don't implement

**libui-ng Zebra port:** `zig_lit`-dependent parts tracked as 1.5 release item

**Issue #308** (uiInit NULL crash): fixed in wp-2025-v2 ✓

---

## Recommended action list

### Completed (2026-05-25)

- [x] Rebase `torial/libui-ng` on kojix2/main — `wp-2025-v2` branch
- [x] Add placeholder text (uiEntry + uiEditableCombobox) from libui-dev into C fork
- [x] Add `uiDrawBitmap` declarations to `ui.h` from libui-dev
- [x] Copy `ui_safe.h` thread-safety wrappers from libui-dev
- [x] Fix Issue #308 (uiInit NULL crash) — all 3 platforms
- [x] Update `torial/zig-libui-ng` to pin new C fork + add 9 missing bindings:
  - uiTabSelected / uiTabSetSelected / uiTabOnSelected
  - uiGridDelete / uiGridNumChildren
  - uiDrawTransform / uiDrawClip / uiDrawSave / uiDrawRestore
  - uiEntryPlaceholder / uiEntrySetPlaceholder
  - uiEditableComboboxPlaceholder / uiEditableComboboxSetPlaceholder
- [x] Update `zebra-language/src/main.zig` pin to new `zig-libui-ng` commit

### Next: preamble wiring

- [ ] Wire `uiGroup` (Group) into libui-ng preamble as `g.beginPanel()` / `g.endPanel()`
- [ ] Wire `uiProgressBar` into preamble (bound in Zig, never exposed to Zebra)
- [ ] Wire `uiTable`/`uiTableModel` to Zebra's `g.beginTable()` (Zig bindings already have it)
- [ ] Wire `uiScrollingArea` to Zebra's `g.beginChild()` / `g.endChild()`
- [ ] Wire `uiCombobox` / `uiEditableCombobox` / `uiRadioButtons` / `uiSpinbox` into preamble

### Track for future

- [ ] **DPI scaling (Windows):** Win11 defaults to 125–150% scaling; controls look pixelated.
  Requires `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` in
  `uiInit` + a Windows application manifest embedded in the generated binary.
  Add manifest first (trivial, improves visual quality of existing controls).
- [ ] **Dark mode:** 1.5 release target; no urgency
- [ ] **`uiDrawArc` implementations** — already declared in kojix2; pull sweep-fix when Area drawing is wired
- [ ] **`uiDrawBitmap` platform implementations** — declarations in ui.h; C implementations deferred
- [ ] **libui-ng port to Zebra** — parts needing `zig_lit` escape: Win32/Cocoa API calls.
  1.5 release item. Lower priority than llama.cpp port.
- [ ] **Thread-safety wrappers** (`ui_safe.h`) — wire into generated GUI projects when async/multi-thread GUI is needed

### Monitor

- [ ] Qt5 backend (libui-dev) — monitor petabyt activity for completion
- [ ] GTK4 backend — watch libui-ng issue tracker; high long-term Linux risk
- [ ] libui-ng/master activity — if still silent by 2027, consider petabyt/libui-dev as C upstream

### Architecture note

libui-ng/master has been inactive since Aug 2024 with no maintainer response to any
issue. If this continues to 2027, consider adopting `petabyt/libui-dev` as our primary
C upstream (rebasing `wp-2025` onto it). The 49-file Qt5 branch and drawing extras
suggest libui-dev is where real development lives.

---

## Appendix: our preamble function → libui-ng mapping

| Zebra `GuiContext` method | Preamble function | libui-ng call | Status |
|---|---|---|---|
| `g.text(s)` | `_lui_text` | `uiLabel.New` + `SetText` | ✓ |
| `g.separator()` | `_lui_sep` | `uiSeparator.New(.Horizontal)` | ✓ |
| `g.button(l)` | `_lui_button` | `uiButton.New` + `OnClicked` | ✓ |
| `g.checkbox(l, v)` | `_lui_checkbox` | `uiCheckbox.New` + `OnToggled` | ✓ |
| `g.slider(l, v, lo, hi)` | `_lui_slider` | `uiSlider.New` + `OnChanged` | ✓ |
| `g.input(l, v)` | `_lui_input` | `uiEntry.New` + `OnChanged` | ✓ |
| `g.inputMultiline(l, v)` | `_lui_input_ml` | `uiMultilineEntry.New` + `OnChanged` | ✓ |
| `g.beginHBox(id, s)` | `_lui_begin_hbox` | `uiBox.New(.Horizontal)` | ✓ |
| `g.endHBox()` | `_lui_end_hbox` | pop stack | ✓ |
| `g.beginVBox(id, s)` | `_lui_begin_vbox` | `uiBox.New(.Vertical)` | ✓ |
| `g.endVBox()` | `_lui_end_vbox` | pop stack | ✓ |
| `g.sameLine()` | `_lui_noop_void` | – | no-op |
| `g.spacing()` | `_lui_noop_void` | – | no-op |
| `g.indent()` / `g.unindent()` | `_lui_noop_void` | – | no-op |
| `g.beginPanel(l)` | `_lui_noop_bool` | should be `uiGroup` | **stub** |
| `g.endPanel()` | `_lui_noop_void` | – | **stub** |
| `g.beginWindow(l)` | `_lui_noop_bool` | should be `uiWindow` | **stub** |
| `g.endWindow()` | `_lui_noop_void` | – | **stub** |
| `g.selectable(l)` | `_lui_selectable` | no equivalent | **stub** |
| `g.textColored(r,g,b,a,s)` | `_lui_text_colored` | falls back to Label | **degraded** |
| `g.beginTable(id, cols)` | `_lui_begin_table` | should be `uiTable` | **stub** |
| `g.tableSetupColumn(l)` | `_lui_table_setup_col` | – | **stub** |
| `g.tableHeadersRow()` | `_lui_noop_void` | – | **stub** |
| `g.tableNextRow()` | `_lui_noop_void` | – | **stub** |
| `g.tableNextColumn()` | `_lui_table_next_col` | – | **stub** |
| `g.endTable()` | `_lui_noop_void` | – | **stub** |
| `g.beginChild(id)` | `_lui_begin_child` | should be `uiScrollingArea` | **stub** |
| `g.endChild()` | `_lui_noop_void` | – | **stub** |
| `g.treeNode(l)` | `_lui_noop_bool` | no equivalent | **stub** |
| `g.treePop()` | `_lui_noop_void` | – | **stub** |
| `g.setColor(…)` | `_lui_set_color` | no runtime theming | **stub** |
| All `g.lowLevel.*` | `_lui_ll_noop_*` | `uiArea` / `uiDrawPath` | **no-op** |
| `g.codeEditor()` | `_code_editor_render` | Scintilla / `sci` module | ✓ Win-only |
