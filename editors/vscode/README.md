# Zebra for VS Code

Language support for [Zebra](../../README.md) (`.zbr`) files:

- **Live diagnostics** — errors and warnings as you type, from the compiler's
  own front-end (parse → resolve → typecheck), served by `zebra lsp`.
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

- Diagnostics only (no hover / go-to-definition / completion yet — planned).
- Numeric JSON-RPC request ids.
- Full-document sync (the whole buffer is re-checked on each change; fine for the
  file sizes involved).
