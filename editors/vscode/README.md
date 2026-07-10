# Zebra for VS Code

Language support for [Zebra](../../README.md) (`.zbr`) files:

- **Live diagnostics** — errors and warnings as you type, from the compiler's
  own front-end (parse → resolve → typecheck), served by `zebra lsp`.
- **Hover** — the signature of the symbol under the cursor (`def foo(a: int): str`,
  `class Point`, `var x: int`).
- **Go-to-definition** (F12) — jump to a symbol's declaration.
- **Signature help** — while typing a call, shows the function/method's parameter
  list with the current argument highlighted (triggers on `(` and `,`).
- **Completion** — language keywords + the program's declared symbols
  (functions, types, methods, fields), with kinds and signatures. After `.` it
  narrows to the receiver's members (`self.`/`this.`/`.` → the enclosing type;
  a type name → its members/variants; an annotated or constructed local → its
  type's members).
- **Outline / breadcrumbs** — document symbols for classes, functions, fields, etc.
- **Formatting** — via `zebra fmt` (enable `editor.formatOnSave` for format-on-save).
- **Syntax highlighting** — comments, strings, keywords, types, numbers.
- Comment toggling, bracket matching, indentation.

The extension is a thin client: it launches `zebra lsp` (a subcommand of the
compiler) over stdio and lets VS Code render the diagnostics it publishes. All the
language logic lives in the compiler, so the editor experience tracks the compiler
exactly.

## Prerequisites

1. A built `zebra` executable — from the repo root:
   ```
   zig build            # produces zig-out/bin/zebra.exe
   ```
2. Node.js (only to install the client library):
   ```
   cd editors/vscode
   npm install
   ```

## Point the extension at your build

Either put `zig-out/bin` on your `PATH`, or set the path explicitly in VS Code
settings (`settings.json`):

```json
{
  "zebra.serverPath": "C:/Projects/zebra-language/zig-out/bin/zebra.exe"
}
```

## Run it (development)

1. Open the `editors/vscode` folder in VS Code.
2. Press **F5** ("Run Extension"). A second VS Code window ("Extension
   Development Host") opens with the extension loaded.
3. Open any `.zbr` file. Introduce an error (e.g. `var x: int = "oops"`) and you
   should see a red squiggle with the compiler's message; fix it and the squiggle
   clears.

To watch the protocol traffic, set `"zebra.trace.server": "verbose"` and check
**Output → Zebra Language Server**.

## Package it (optional)

```
npm install -g @vscode/vsce
vsce package        # produces zebra-language-<version>.vsix
```
Then **Extensions → … → Install from VSIX** in VS Code.

## How it works

- `extension.js` — starts a `vscode-languageclient` `LanguageClient` that spawns
  `zebra lsp` and speaks JSON-RPC over stdio.
- `zebra lsp` (in `selfhost/main.zbr`) — reads `Content-Length`-framed requests,
  runs the front-end in-process on the document buffer, and pushes
  `textDocument/publishDiagnostics`. It advertises `textDocumentSync: 1` (full
  document sync).

## Current scope & limitations

- Hover / definition / completion are **name-based** (top-level decls + class
  members), not yet scope-aware (locals/shadowing) or cross-file. Member
  completion after `.` resolves the receiver's type by a lightweight text search
  (explicit annotation / constructor init / enclosing type), not full inference —
  so a receiver whose type is only inferred from an expression won't resolve yet.
- Go-to-definition and documentSymbol positions come from **real source spans**
  the parser now records on each declaration (name-precise). Text search remains a
  fallback only for the rare case where a position wasn't captured (e.g. mid-edit).
- The formatter (`zebra fmt`) normalizes whitespace: tabs→spaces, trailing-
  whitespace trim, blank-line trim, and collapses runs of interior spaces between
  tokens to one — while preserving the content of strings (regular, raw, no-sub,
  triple-quoted multi-line) and `#` comments byte-for-byte. It does not re-indent
  to a canonical nesting depth yet (leading indentation is left as written).
- Numeric JSON-RPC request ids; full-document sync.
