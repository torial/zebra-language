<!-- doc-status: live -->
# Deferred past 1.0 — on purpose

**Everything here is parked by decision, not by neglect.** The distinction matters
because the two are indistinguishable from outside, and a reader who cannot tell
will either revive the wrong thing or apologise for it in a status report.

`docs/archive/ROADMAP_TO_1.0.md` was explicit about this and the wording is worth keeping:
*"the 1.0 win is stability + proof, not more surface. Resist the temptation to pull
any of it forward."*

## Parked for 1.5

- **WASM target**
- **Http server ergonomics**
- **Zig-builtin access**
- **`§28e` `str` ownership spec** — exists to ground the *1.5* `str_view` design;
  it sat in the 1.0 blocker list for a while on no stated grounds.

## Parked for 2.0

- **The kernel track**
- **A VCS written in Zebra** (Pijul-shaped; Sean's long-standing interest)

## Parked with no milestone

- **The GameEngine runtime-validation pass.** **Deferred BY DECISION (Sean,
  2026-08-29): the engine work is paused while Zebra reaches a personal-review
  pre-0.9 state, and it is the intended first tire-kick once that lands.** Recorded
  this way deliberately -- the corpus is 93.8% front-end-clean, but that metric
  measures *compiles*, not *runs*, and the runtime frontier is where the next real
  bugs are. A future reader seeing "stalled" would misread a choice as neglect.

## Tooling & LSP polish (mostly post-1.0 ergonomics)

- [ ] **LSP follow-ups** (epic is Phases 1–4h done; see Completed-recent): scope-aware
  locals / shadowing / cross-file resolution; per-document-VERSION parse cache
  (blocked only by AST/arena lifetime, not concurrency); member-completion dedup;
  VS Code click-test + `.vsix` package/publish.
- [ ] **Formatter re-indent** to canonical 4-space nesting (needs INDENT/DEDENT +
  continuation handling; natural follow-on now the string-safe scanner exists).
- [ ] **IDE** — advance one stalled ZebraIDE experiment (tree widget / Debug button
  DAP client via `zebra debug --listen PORT`); install LLDB on Windows to test the
  debugger end-to-end.
- [ ] **N-API follow-ups** — cross-platform `.node` (Linux undefined-symbol default;
  macOS `-undefined dynamic_lookup`) + doc; richer `test/node_addon` matrix.
---

**Where things live** — this file is one of five; see [NEXT_STEPS.md](NEXT_STEPS.md)
for the map.

| file | answers |
|---|---|
| [docs/PRINCIPLES.md](docs/PRINCIPLES.md) | how do we decide? |
| [docs/FINDINGS.md](docs/FINDINGS.md) | what do we already know? |
| [NEXT_STEPS_to_0.9.md](NEXT_STEPS_to_0.9.md) | what is next, before public release? |
| [NEXT_STEPS_to_1.0.md](NEXT_STEPS_to_1.0.md) | what is next, before the freeze? |
| [NEXT_STEPS_post_1.0.md](NEXT_STEPS_post_1.0.md) | deliberately deferred past 1.0 |
