# vendor/

Third-party libraries maintained as local forks. Each subdirectory contains a
copy of an upstream project, with Zebra-specific modifications applied on top.

## Policy

- Local modifications go directly in the subdirectory — do not submit upstream
  unless the change is genuinely general-purpose.
- When pulling upstream changes: fetch into a temp branch, cherry-pick or merge
  onto the local copy, resolve conflicts, update the `Upstream-Commit` line below.
- Do NOT add build artifacts, `.zig-cache/`, or compiled outputs here.

## Contents

### ImGuiColorTextEdit

**Upstream:** https://github.com/pthom/ImGuiColorTextEdit  
**Upstream-Commit:** `19cedec`  
**License:** MIT (see `ImGuiColorTextEdit/LICENSE`)

A C++17 rewrite of the ImGuiColorTextEdit syntax-highlighted code editor widget.
Used in ZebraIDE for the code editing pane.

**Zebra-specific files (do not upstream):**

| File | Purpose |
|------|---------|
| `ZebraLanguage.h` | Header for the Zebra language definition |
| `ZebraLanguage.cpp` | Keyword list, type names, `^`/`?` custom tokenizer |

**Planned additions:**

| Feature | File(s) | Status |
|---------|---------|--------|
| Error marker gutter | `ZebraLanguage.cpp` + shim | Pending |
| `// zbr: N` gutter annotation | shim | Pending |
| Code folding API | `TextEditor.h/.cpp` | Pending — pthom has no fold support yet |
| Fold range provider | `ZebraFolding.h/.cpp` | Pending |

**Integration:** The editor is compiled as C++ source alongside the zgui project
(added to `build.zig` when GUI backend is glfw). The Zig shim calls `ZebraLanguage()`
on editor creation and `SetLanguage()` to activate Zebra highlighting.
