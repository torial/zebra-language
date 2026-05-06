# Zebra IDE

A self-hosted IDE written in Zebra, using the Dear ImGui GUI backend.
Demonstrates stateful GUI, subprocess integration, file I/O, and diagnostic
parsing — all in Zebra itself.

## Files

```
IDE/
├── ZebraIDE.zbr       — The full IDE (ready to use)
├── ZebraIDE.zig       — Generated Zig (build artifact, gitignored)
├── samples/
│   ├── hello.zbr      — Clean program for testing
│   └── error.zbr      — Program with errors for testing
└── archive/           — Historical files (no longer current)
    ├── COMPILER_ISSUES.md    — Bug tracker from before Phase 21 (all fixed)
    ├── ProxyIDE.zbr          — Mock-compiler IDE demo (superseded by ZebraIDE)
    └── ProxyIDE_console.zbr  — Console-mode variant of ProxyIDE
```

## Running ZebraIDE

```bash
zebra --gui-backend=glfw IDE/ZebraIDE.zbr
```

Requires the glfw backend, which is built automatically via `compileGuiProject`
in `src/main.zig`. On first run the project directory `IDE/ZebraIDE_gui/` is
created; subsequent runs reuse it (incremental build via `zig build`).

## Features

- **Open / Save** — load and write `.zbr` files
- **Check (F5)** — invokes `zebra -c <file>` as a subprocess via `sys.run`;
  displays diagnostics with line:col in the panel
- **Run (F9)** — invokes `zebra <file>` and captures stdout/stderr in the
  output pane
- **Code editor** — `CodeEditor` widget backed by `GuiContext.codeEditorFn`;
  switchable per backend (currently maps to `inputTextMultiline`)
- **Diagnostics panel** — error/warning list with icon, line:col, message
- **Persistent state** — `IDEState` and `CodeEditor` kept alive across frames
  via `capture` block

## Architecture

```
Main.main
└── Gui.run("Zebra IDE", 1000, 750, frame)
    └── frame: def(g: Gui) [capture state, editor, inited]
        ├── Main.renderToolbar(g, state, editor)
        ├── Main.renderBody(g, state, editor)
        │   ├── editor.render(g, "##code", 700, 500)
        │   └── g.panel("##diags", ...) → diagnostic list
        └── Main.renderOutput(g, state)
            └── readonly CodeEditor for output display
```

`CompilerBridge` drives all compiler interactions:

| Method | Does |
|--------|------|
| `check(filepath)` | Runs `zebra -c <file>`, returns `List(IDEDiagnostic)` |
| `runFile(filepath)` | Runs `zebra <file>`, returns stdout or stderr |
| `parseOutput(raw)` | Splits stderr into `IDEDiagnostic` list |
| `parseLine(ln)` | Parses a single `file:line:col: kind: msg` line |

## GUI Backend

ZebraIDE uses the `_GuiBackend` fn-ptr isolation layer. Swapping
`_gui_active_backend` changes the renderer without touching any Zebra code.

The `CodeEditor` widget is backed by **BalazsJako/ImGuiColorTextEdit** via a
thin C shim (`src/TextEditorC.h` / `src/TextEditorC.cpp`). The GLFW backend
calls `te_c.te_render()` directly from `_code_editor_render()`, bypassing the
`_GuiBackend` fn-ptr table. The stub backend falls back to `inputMultiline`.

The vendored C++ files live in `vendor/ImGuiColorTextEdit/`. The project
`build.zig` was patched at `TextEditor.cpp` adoption to add:
- `addCSourceFiles` for `TextEditor.cpp` + `TextEditorC.cpp`
- `addIncludePath` for zgui's `libs/imgui/` headers
- `linkLibCpp()` for the C++ standard library

## Key Language Features Exercised

- `capture` block for per-frame persistent state
- `sys.run(argv)` subprocess execution → `SysRunResult`
- `File.read` / `File.write` / `File.exists`
- `CodeEditor` builtin widget type
- `g.panel(label, callback)` child window with lambda
- `List(IDEDiagnostic)` typed collection
- `str.split`, `str.trim`, `str.indexOf`, `str.substring`, `str.toInt`
- String interpolation: `"${state.filepath} *"`

## Historical Notes

`archive/COMPILER_ISSUES.md` documents the compiler bugs that blocked ZebraIDE
during development (Phases 1–20). All listed issues are resolved as of
Phase 21. `archive/ProxyIDE.zbr` was the working mock-compiler demo used while
those fixes were pending.
