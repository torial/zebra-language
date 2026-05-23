# Zebra GUI — libui-ng Backend Quick Reference

This document is agent-facing. It covers how to write Zebra programs that use
the **libui-ng native GUI backend** (`--gui-backend=libui_ng`). For the full
widget API see QUICKSTART.md §30.

---

## What is the libui-ng backend?

`libui-ng` is a cross-platform native GUI library (Win32/Cocoa/GTK). It gives
Zebra apps real OS windows, buttons, menus, and a code editor (via Scintilla).

The backend is **retained-mode**: widgets are created once on the first frame
and updated in place on subsequent frames. This is different from the ImGui/glfw
backend, which re-creates the widget hierarchy every frame.

### Invocation

```bash
zig build run -- myapp.zbr --gui-backend=libui_ng
```

The Zebra compiler scaffolds a `<stem>_gui_libui_ng/` project directory
alongside the source file, writes a `build.zig.zon` pinned to the
`torial/zig-libui-ng` fork (zig-0.16 branch), and invokes `zig build run`.
**Delete the project directory if you change the Scintilla package hash.**

---

## Architecture: MVU (required)

The libui-ng backend requires the **6-argument MVU form** of `Gui.run`:

```zebra
Gui.run(title: str, width: int, height: int, init, update, view)
```

- `init()` — returns the initial model (called once at startup)
- `update(model, msg)` — pure function: old model + message → new model
- `view(g, model)` — renders widgets; calls `g.send(msg)` to dispatch

The legacy 4-argument frame-callback form (`Gui.run(title, w, h, frame_fn)`)
is not recommended for libui-ng.

---

## Layout: HBox / VBox

libui-ng organises widgets in horizontal and vertical boxes. Widgets are
**appended once** (frame 0) and cannot be repositioned.

```zebra
def view(g: Gui, m: Model)
    # Toolbar row — buttons side by side
    g.beginHBox("toolbar", false)
    if g.button("Open"):  g.send(Msg.open)
    if g.button("Save"):  g.send(Msg.save)
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
| `g.button(label)`                | Returns `true` once per click. Label is immutable (part of ID). |
| `g.checkbox(label, value)`       | Returns new state. Value synced to OS checkbox.                |
| `g.slider(label, value, min, max)` | Returns current value. Range is set at creation time.        |
| `g.input(label, value)`          | Single-line entry. Returns current text each frame.            |
| `g.inputMultiline(label, val, w, h)` | Multi-line entry. `w`/`h` args ignored (fills box).       |
| `g.separator()`                  | Horizontal separator rule.                                     |
| `g.selectable(label)`            | No-op in libui-ng (returns false). Use `g.button` instead.     |
| `g.textColored(r,g,b,a, s)`      | Text only (color ignored).                                     |
| `g.beginTable` / table ops       | No-op. Render as a VBox of buttons for MVP.                    |
| `g.childWindow(id, w, h, fn)`    | No-op. Use `beginVBox`/`endVBox` instead.                      |
| `g.panel`, `g.window`            | No-op in libui-ng.                                             |

**Widget IDs:** Interactive widget IDs are the `label` string. If two widgets
share a label they share state — prefix with `##` to hide the label and make
the ID unique, e.g. `g.input("##filepath", m.filepath)`.

---

## CodeEditor (Scintilla)

The `CodeEditor` widget wraps **Scintilla** in the libui-ng backend:

```zebra
struct Model
    var editor: ^CodeEditor = CodeEditor.forZebra()
    var output_editor: ^CodeEditor = CodeEditor()

def init(): Model
    var m = Model()
    m.editor.setText(File.read("main.zbr"))
    m.output_editor.setReadOnly(true)
    return m

def view(g: Gui, m: Model)
    g.beginHBox("main", true)
      m.editor.render(g, "##editor", 0, 0)
    g.endHBox()
```

- `CodeEditor()` — plain editor
- `CodeEditor.forZebra()` — editor with Zebra syntax preset (not yet wired in libui-ng MVP, falls back to plain)
- `editor.render(g, id, w, h)` — creates the Scintilla widget on first call and appends it to the current box with `.stretch`. Width/height args are ignored.
- `editor.setText(s)` — replace content
- `editor.getText()` — retrieve current content
- `editor.setReadOnly(v: bool)` — toggle editing
- `editor.getCursorLine() / getCursorCol()` — current caret position (1-based)
- `editor.setCursorPosition(line, col)` — jump to line/col (col ignored in MVP)
- `editor.setErrorMarkers(diags)` — no-op in MVP

**Important:** The `^` (heap-indirection) prefix on the field type is required:
```zebra
var editor: ^CodeEditor = CodeEditor.forZebra()   # correct
var editor: CodeEditor  = CodeEditor.forZebra()    # wrong — struct copy breaks widget
```

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

- **No dynamic layout**: All boxes are created on frame 0. Conditional
  `beginHBox`/`beginVBox` calls (different branches of an if) will cause
  layout corruption.
- **No tables**: `beginTable`/`tableNextRow` etc. are no-ops. Use a VBox of
  buttons or text labels as a workaround.
- **No colour**: `textColored` renders without colour.
- **No selectable**: `g.selectable` always returns false. Use `g.button`.
- **No fixed widths**: `beginVBox` fills its share of the parent HBox. Fixed
  pixel widths are not supported.
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
    if g.button("+"):  g.send(Msg.inc)
    if g.button("-"):  g.send(Msg.dec)
    g.endHBox()

def main()
    Gui.run("Counter", 300, 150, init, update, view)
```

---

## Package hashes (2026-05-22)

Pinned in `src/main.zig` `gui_libui_ng_project_build_zig_zon`:

| Dependency    | Commit    | Hash                                                              |
|---------------|-----------|-------------------------------------------------------------------|
| zig-libui-ng  | `d99a49c` | `bindings_libui_ng-0.1.0-p2CY9QkWGgBjeLI8hICTNlxLEjcSbkLLJCh3-CHi11Kj` |

The fork is `torial/zig-libui-ng` branch `zig-0.16`. It vendors Scintilla 5.5.2
sources and `libui_scintilla/win.cxx`. For platform support:
- **Windows**: Win32, Scintilla WinAPI backend, `imm32` linked
- **Linux/macOS**: GTK3/Cocoa — Scintilla GTK/Cocoa backends not yet vendored;
  code editor falls back to `MultilineEntry`
