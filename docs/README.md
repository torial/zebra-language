<!-- doc-status: live -->
# docs/ — what lives where

Reorganised 2026-09-09 (Fable 5.1, at Sean's request). Three kinds of document, three
places, so a reader can tell a live reference from a design record from history:

| where | what | linted by `tools/doc_lint.py`? |
|---|---|---|
| `docs/*.md` | **live references** — how to build, debug, test, work on the compiler; the GUI quickstart; the principles; the NEXT_STEPS chain (`NEXT_STEPS_to_0.9`, `_to_1.0`, `_post_1.0` — kept live until that release completes, then archived); the selfhost journal and stdlib roadmap | yes |
| `docs/design/*.md` | **design records** — the reasoning behind a subsystem (string ownership, extern FFI, the runtime module, single-file emit, the GUI MVU loop, DynLib plugins, concurrency allocation, regen authority, the ORM, the Node addon, dynamic interop). Stable once written; update when the design changes | yes |
| `docs/archive/*.md` | **history** — dated audits, triages, checklists and plans whose content has landed or been superseded. Kept for the record; not linted, so a stale link inside one is not a gate failure | no |

The root keeps only what a newcomer or contributor must see first: `README.md`,
`QUICKSTART.md`, `CHANGELOG.md`, `STYLE_GUIDE.md`, and the working set `CLAUDE.md`,
`NEXT_STEPS.md`, `BUGS.md`, `BUGS_FIXED.md` (the last two are pinned there by a dozen
tool paths — do not move them).

Release naming, so it is not lost again: the public release is **0.9** (internally the
push is called 1.0), tagged with the toolchain it was tested against, e.g.
`0.9_zig0.16`. See `NEXT_STEPS.md`.
