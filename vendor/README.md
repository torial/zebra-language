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

### ImGuiColorTextEdit — REMOVED 2026-08-29

Vendored for ZebraIDE's code-editing pane, which was built on the Dear ImGui GUI
backend. That backend was retired (NEXT_STEPS, "RETIRE THE IMGUI GUI BACKEND") and
the 43 vendored files went with it, along with `vendor/fonts` (36 files, 15 MB) which
nothing surviving referenced.

The capability is not lost: `--gui-backend=libui_ng` provides a real Scintilla-backed
code editor, and `tui`/`stub` carry a text-buffer stub. What went with imgui is the
low-level draw API (`g.ll.*`), which has no replacement.

