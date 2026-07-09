// Zebra VS Code extension — thin Language Server client.
//
// It launches the compiler's built-in server (`zebra lsp`) over stdio and lets
// VS Code render its diagnostics.  All the language logic lives in the compiler;
// this file is just the wiring.

const { workspace, window } = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

/** @type {import('vscode-languageclient/node').LanguageClient | undefined} */
let client;

function activate(context) {
  const config = workspace.getConfiguration("zebra");
  const serverPath = (config.get("serverPath") || "zebra").trim();

  // `zebra lsp` speaks JSON-RPC over stdio.
  const server = {
    command: serverPath,
    args: ["lsp"],
    transport: TransportKind.stdio,
  };

  /** @type {import('vscode-languageclient/node').ServerOptions} */
  const serverOptions = { run: server, debug: server };

  /** @type {import('vscode-languageclient/node').LanguageClientOptions} */
  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "zebra" }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher("**/*.zbr"),
    },
    outputChannelName: "Zebra Language Server",
  };

  client = new LanguageClient(
    "zebra",
    "Zebra Language Server",
    serverOptions,
    clientOptions
  );

  client.start().catch((err) => {
    window.showErrorMessage(
      `Zebra: failed to start the language server ('${serverPath} lsp'). ` +
        `Set 'zebra.serverPath' to your zebra executable. ${err}`
    );
  });

  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
