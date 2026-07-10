#!/usr/bin/env python3
"""Smoke test for `zebra lsp` — drives the server over stdio with a real
JSON-RPC (Content-Length framed) conversation and checks the responses.

Verifies: initialize handshake, publishDiagnostics on didOpen (a doc with a type
error), clean diagnostics on didChange to a valid doc, and shutdown/exit.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZEBRA = os.path.join(ROOT, "zig-out", "bin", "zebra.exe")


def frame(obj):
    body = json.dumps(obj).encode("utf-8")
    return b"Content-Length: %d\r\n\r\n%s" % (len(body), body)


def read_message(stream):
    # Read headers until blank line.
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if line == "":
            break
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    n = int(headers.get("content-length", 0))
    body = stream.read(n)
    return json.loads(body.decode("utf-8"))


def main():
    if not os.path.exists(ZEBRA):
        print("FAIL: zebra.exe not built", file=sys.stderr)
        return 1

    proc = subprocess.Popen(
        [ZEBRA, "lsp"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )

    bad_src = "def main()\n    var x: int = \"oops\"\n"
    good_src = ("class Point\n    var x: int\n    def getX(): int\n        return .x\n"
                "def main()\n    print(42)\n")
    uri = "file:///tmp/lsp_test.zbr"

    convo = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "text": bad_src}}},
        {"jsonrpc": "2.0", "method": "textDocument/didChange",
         "params": {"textDocument": {"uri": uri},
                    "contentChanges": [{"text": good_src}]}},
        {"jsonrpc": "2.0", "id": 3, "method": "textDocument/documentSymbol",
         "params": {"textDocument": {"uri": uri}}},
        {"jsonrpc": "2.0", "id": 4, "method": "textDocument/formatting",
         "params": {"textDocument": {"uri": uri}, "options": {"tabSize": 4, "insertSpaces": True}}},
        {"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": {}},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    for m in convo:
        proc.stdin.write(frame(m))
    proc.stdin.flush()
    proc.stdin.close()

    passed = 0
    failed = 0

    def check(cond, name):
        nonlocal passed, failed
        if cond:
            print("  PASS: %s" % name); passed += 1
        else:
            print("  FAIL: %s" % name); failed += 1

    # Expected reply sequence: initialize result, didOpen diagnostics (>=1),
    # didChange diagnostics (0), shutdown result.
    init = read_message(proc.stdout)
    check(init and init.get("id") == 1 and "capabilities" in init.get("result", {}),
          "initialize response has capabilities")

    diag_open = read_message(proc.stdout)
    check(diag_open and diag_open.get("method") == "textDocument/publishDiagnostics"
          and len(diag_open["params"]["diagnostics"]) >= 1,
          "didOpen publishes >=1 diagnostic")
    if diag_open and diag_open["params"]["diagnostics"]:
        d0 = diag_open["params"]["diagnostics"][0]
        check("range" in d0 and "severity" in d0 and "message" in d0
              and d0["range"]["start"]["line"] == 1,   # 0-based: source line 2
              "diagnostic has LSP range/severity/message, 0-based line")

    diag_change = read_message(proc.stdout)
    check(diag_change and diag_change.get("method") == "textDocument/publishDiagnostics"
          and len(diag_change["params"]["diagnostics"]) == 0,
          "didChange to valid source clears diagnostics")

    docsym = read_message(proc.stdout)
    syms = docsym.get("result", []) if docsym else []
    names = {s["name"] for s in syms}
    check(docsym and docsym.get("id") == 3 and "Point" in names and "main" in names,
          "documentSymbol returns top-level Point + main")
    point = next((s for s in syms if s["name"] == "Point"), None)
    child_names = {c["name"] for c in point["children"]} if point else set()
    check(point and point["kind"] == 5 and "x" in child_names and "getX" in child_names,
          "class Point (kind 5) has field x + method getX as children")

    fmt = read_message(proc.stdout)
    fmt_edits = fmt.get("result", []) if fmt else []
    check(fmt and fmt.get("id") == 4 and len(fmt_edits) == 1
          and "newText" in fmt_edits[0] and "class Point" in fmt_edits[0]["newText"],
          "formatting returns a full-document TextEdit")

    shut = read_message(proc.stdout)
    check(shut and shut.get("id") == 2, "shutdown response")

    proc.wait(timeout=10)
    print("lsp server smoke: %d/%d passed" % (passed, passed + failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
