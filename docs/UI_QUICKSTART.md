<!-- doc-status: live -->
# Zebra GUI — libui-ng Backend Quick Reference

This document is agent-facing. It covers how to write Zebra programs that use
the **libui-ng native GUI backend** (`--gui-backend=libui_ng`). For the full
widget API see QUICKSTART.md §30.

---

## What is the libui-ng backend?

`libui-ng` is a cross-platform native GUI library (Win32/Cocoa/GTK). It gives
Zebra apps real OS windows, buttons, menus, and a code editor (via Scintilla).

The backend is **retained-mode**: widgets are created once on the first frame
and updated in place on subsequent frames. This is different from an immediate-mode
backend, which re-creates the widget hierarchy every frame.

### Invocation

```bash
zig build run -- myapp.zbr --gui-backend=libui_ng
```

The Zebra compiler scaffolds a `<stem>_gui_libui_ng/` project directory
alongside the source file, writes a `build.zig.zon` pinned to the
`torial/zig-libui-ng` fork (`main` branch), and invokes `zig build run`.
(The scaffold's `build.zig`/`build.zig.zon`/`app.manifest` are rewritten on
every run, so a changed dependency pin is picked up automatically — no need to
delete the project directory.)

---

## Architecture: MVU (required)

The libui-ng backend requires the **6-argument MVU form** of `Gui.run`:

```zebra
Gui.run(title: str, width: int, height: int, init, update, view)
```

- `init()` — returns the initial model (called once at startup)
- `update(model, msg)` — pure function: old model + message → new model
- `view(g, model)` — renders widgets; calls `g.send(msg)` to dispatch

The 4-argument frame-callback form (`Gui.run(title, w, h, frame_fn)`) was retired on
2026-09-21; `Gui.run` takes the six MVU arguments and refuses anything else.

---

## Layout: HBox / VBox

libui-ng organises widgets in horizontal and vertical boxes. Widgets are
**appended once** (frame 0) and cannot be repositioned.

```zebra
def view(g: Gui, m: Model)
    # Toolbar row — buttons side by side
    g.beginHBox("toolbar", false)
    g.button("Open", Msg.open)
    g.button("Save", Msg.save)
    g.endHBox()

    g.separator()

    # Main area — two panels side by side, filling height
    g.beginHBox("main", true)

    g.beginVBox("left_panel", true)
    g.text("File: " + m.filepath)
    g.endVBox()

    m.editor.render(g, "##editor", 0, 0)   # Scintilla fills remaining space

    g.endHBox()
```

### `g.beginHBox(id: str, stretch: bool)` / `g.endHBox()`

Creates a **horizontal box** (row of widgets). `stretch: true` means this row
fills available height in its parent VBox. Use `false` for toolbar rows.

### `g.beginVBox(id: str, stretch: bool)` / `g.endVBox()`

Creates a **vertical box** (column of widgets). `stretch: true` means this
column fills available width in its parent HBox.

### Rules

- `id` must be unique within the window. It is used to identify the box across
  frames (the box is created on first call and reused thereafter).
- Layout is **stable**: call `beginHBox`/`endHBox` in the same order every
  frame. Do not add conditional layout switches (create all boxes unconditionally,
  then conditionally show/hide content by using state flags).
- `g.sameLine()` is a no-op in libui-ng. Use `beginHBox`/`endHBox` instead.

---

## Widget reference (libui-ng specifics)

| Widget                           | Notes                                                          |
|----------------------------------|----------------------------------------------------------------|
| `g.text(s)`                      | Label. Text updated each frame.                                |
| `g.button(label, msg)`           | Sends `msg` on click. Keyed by its label. (`action` until 2026-09-21; the bool `button`, `buttonId`, `checkbox`, `input` are gone.) |
| `g.toggle(label, checked, on)`   | Checkbox; `on: def(b: bool): Msg` is called when it flips. The model drives it. |
| `g.field(label, text, on)`       | Entry; `on: def(s: str): Msg` on every change.                  |
| `g.password(label, text, on)` / `g.search(label, text, on)` | `field` on a masked / search-styled entry (`uiNewPasswordEntry`, `uiNewSearchEntry`). |
| `g.slider(label, value, min, max, on)` | `on: def(v: float): Msg` as it moves. The model drives it; range set at creation. (Message form since 2026-09-22.) |
| `g.inputMultiline(label, text, on)` | Multi-line entry; `on: def(s: str): Msg` on every change. Fills its box; size with `minSize`. |
| `g.combobox(label, items, sel, on)` / `g.spinbox(label, value, min, max, on)` | `on: def(i: int): Msg`. The model drives both. |
| `g.radio(label, items, sel, on)`  | One radio button per item (`uiRadioButtons`); `on: def(i: int): Msg`. The model drives the selection. |
| `g.separator()`                  | Horizontal separator rule.                                     |
| `g.textColored(r,g,b,a, s)`      | Text only (color ignored).                                     |
| `g.beginTable` / table ops       | `uiTable`, text columns, rows diffed per frame (QUICKSTART §30). |
| `g.childWindow(id, w, h, fn)`    | No-op. Use `beginVBox`/`endVBox` instead.                      |
| `g.panel`, `g.window`            | No-op in libui-ng.                                             |

**Widget IDs:** Interactive widget IDs are the `label` string. If two widgets
share a label they share state — prefix with `##` to hide the label and make
the ID unique, e.g. `g.field("##filepath", m.filepath, on)`.

---

## CodeEditor (Scintilla)

The `CodeEditor` widget wraps **Scintilla** in the libui-ng backend:

```zebra
class Model
    var editor: CodeEditor? = nil
    var output_editor: CodeEditor? = nil

def init(): Model
    var m = Model()
    m.editor = CodeEditor.forZebra()
    m.output_editor = CodeEditor()
    m.editor!.setText(File.read("main.zbr"))
    m.output_editor!.setReadOnly(true)
    return m

def view(g: Gui, m: Model)
    using g.hbox("##main", true)
        m.editor!.render(g, "##editor", 0, 0)
```

- `CodeEditor()` — plain editor
- `CodeEditor.forZebra()` — editor with the Zebra syntax preset (see below; in the libui-ng backend it is the same as `CodeEditor()`, because the preset is applied to every editor)
- `editor.render(g, id, w, h)` — creates the Scintilla widget on first call and appends it to the current box with `.stretch`. Width/height args are ignored.
- `editor.setText(s)` — replace content
- `editor.getText()` — retrieve current content
- `editor.setReadOnly(v: bool)` — toggle editing
- `editor.getCursorLine() / getCursorCol()` — current caret position (1-based)
- `editor.setCursorPosition(line, col)` — jump to line/col (col ignored in MVP)
- `editor.setErrorMarkers(diags)` — no-op in MVP

### Syntax highlighting, and why there is no lexer (libui-ng)

Every editor created by the libui-ng backend gets a line-number margin, a
monospace font, caret-line highlight, a 4-space tab and a dark palette, and its
text is syntax-highlighted as Zebra on `setText`.

**No Scintilla lexer is involved, and that is forced rather than chosen.** The
vendored Scintilla is version 5, which moved every lexer out of the core into
Lexilla, and Lexilla is not vendored — the header carries `SCI_SETILEXER` and no
`SCI_SETLEXER` or `SCLEX_*`. So the obvious approach, `SCI_SETLEXER` with
`SCLEX_PYTHON`, would **silently do nothing**: an unrecognised message id is not
an error in Scintilla, the text simply stays unstyled, which looks exactly like a
styler that ran and found nothing to style.

Instead the text is styled directly with `SCI_STARTSTYLING` / `SCI_SETSTYLING`
from a small Zebra tokenizer in `selfhost/gui_libui_ng_section.zig`. It is a real
Zebra tokenizer rather than another language's lexer wearing Zebra's keyword
list, so "Zebra syntax highlighting" is an accurate description of it. The
keyword set was taken from the compiler's keyword table (`selfhost/Token.zbr`).

Two limits, stated rather than discovered:

- **It styles on `setText`, not as you type.** There is no incremental re-lex and
  none is pretended; a buffer the user has edited keeps the styling it was given.
  Wiring `SCN_STYLENEEDED` is the fix if that ever matters.
- **It applies to every editor, including a read-only output pane.** `forZebra()`
  and `CodeEditor()` both reach the same constructor, so an editor holding build
  output is styled as though it were Zebra source. Distinguishing them means
  giving the two factories different lowerings in both compilers.

`examples/scintilla_editor.zbr` is a working editor built on this:

```bash
zebra --gui-backend=libui_ng examples/scintilla_editor.zbr
```

Run it from the repo root — its file buttons resolve paths relative to the
working directory, and it says so in the status line when one is missing rather
than opening an empty editor that looks like a working one.

**Important — how to hold an editor handle** (corrected 2026-07-28; the previous
advice here did not compile):

```zebra
class Model
    var editor: CodeEditor? = nil     # correct: optional field, assigned in init
```

A `CodeEditor` is a live widget handle, so the model must refer to *the* editor
rather than a copy of it. Two consequences:

1. **Use a `class`, not a `struct`.** A struct model is copied into `update`, so
   mutations through it are discarded.
2. **Assign in `init`, do not use a field default.** A field initialiser that
   calls `CodeEditor.forZebra()` fails to compile — the emitted Zig needs a
   comptime-known struct default and a widget handle is not one:

```zebra
var editor: ^CodeEditor = CodeEditor.forZebra()   # ✗ error: unable to resolve comptime value
var editor: CodeEditor  = CodeEditor.forZebra()   # ✗ same, and copies the handle
var editor: CodeEditor? = nil                     # ✓ then `m.editor = CodeEditor.forZebra()` in init
```

Verified against the current compiler in all three forms. ZebraIDE (removed with the
imgui backend, 2026-08-29) used
the working form for all four of its editors.

---

## Background polling (build tasks, debug processes)

libui-ng's event loop is blocking. A **100ms timer** fires automatically to
wake the loop even when the user is idle — this is how `BuildTask.poll()` and
`DebugTask.poll()` stay alive without CPU burn.

In MVU, use `g.send(Msg.poll_frame)` at the top of `view` to trigger polling
on every frame:

```zebra
def view(g: Gui, m: Model)
    g.send(Msg.poll_frame)   # triggers update each frame even without user input
    ...

def update(m: Model, msg: Msg): Model
    branch msg
        on Msg.poll_frame
            m.registry.pollAll()
            return m
        ...
```

---

## Limitations (MVP)

- **Layout is dynamic** (since 2026-09-17): a box, line, panel or page that the
  view emits conditionally is inserted where it appears and removed when it
  stops; keyed widgets (`##id`, a label) keep their identity when they move.
- **Tables are lists**: `beginTable`/`tableNextRow`/`g.text` cells only (no
  widgets in cells); `tableSelectedRow` / `tableActivatedRow` read the user.
- **No colour**: `textColored` renders without colour.
- **Widths are hints**: `beginVBox` fills its share of the parent HBox; give a
  pane a floor with `g.minSize(id, w, h)` (a minimum, never a fixed size).
- **No syntax highlighting**: `CodeEditor.forZebra()` does not yet wire Scintilla
  lexer in the libui-ng backend. Plain editing works.

---

## Minimal MVU example

```zebra
# counter_libui.zbr
# Run: zig build run -- counter_libui.zbr --gui-backend=libui_ng

struct Model
    var count: int

union Msg
    inc
    dec

def init(): Model
    return Model(count: 0)

def update(m: Model, msg: Msg): Model
    branch msg
        on Msg.inc  return Model(count: m.count + 1)
        on Msg.dec  return Model(count: m.count - 1)

def view(g: Gui, m: Model)
    g.text("Count: " + m.count.toString())
    g.separator()
    g.beginHBox("btns", false)
    g.button("+", Msg.inc)
    g.button("-", Msg.dec)
    g.endHBox()

def main()
    Gui.run("Counter", 300, 150, init, update, view)
```

---

## Package hashes (2026-07-27)

Pinned in `selfhost/main.zbr` `luiBuildZon()` (the single source of truth):

| Dependency    | Commit     | Hash                                                                |
|---------------|------------|--------------------------------------------------------------------|
| zig-libui-ng  | `8677b01`  | `bindings_libui_ng-0.1.0-p2CY9cIOQgD6ELPBtySSzOXKEbM3EBCHC0aB6xktF89h` |
| libui-ng (transitive) | `85976bc` | `N-V-__8AAJUpKQC_gvsKqMnq2StXzP7vXUVZ-2SFoxrur37u`                 |

The fork is `torial/zig-libui-ng` branch `main` (consolidated 2026-07-27; the
old `zig-0.16` / `wp` branches are deleted). It vendors Scintilla 5.5.2
sources and `libui_scintilla/win.cxx`. For platform support:
- **Windows**: Win32, Scintilla WinAPI backend, `imm32` linked
- **Linux/macOS**: GTK3/Cocoa — Scintilla GTK/Cocoa backends not yet vendored;
  code editor falls back to `MultilineEntry`
