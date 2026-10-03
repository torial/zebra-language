#!/usr/bin/env python3
# pins: BUG-511 a client that closes stdin right after its last requests gets every reply (run under load to see the race)
"""Smoke test for `zebra lsp` — drives the server over stdio with a real
JSON-RPC (Content-Length framed) conversation and checks the responses.

Verifies: initialize handshake, publishDiagnostics on didOpen (a doc with a type
error), clean diagnostics on didChange to a valid doc, and shutdown/exit.
"""
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZEBRA = os.path.join(ROOT, "zig-out", "bin", "zebra.exe")
if not os.path.exists(ZEBRA) and os.path.exists(os.path.join(ROOT, "zig-out", "bin", "zebra")):
    ZEBRA = os.path.join(ROOT, "zig-out", "bin", "zebra")   # Linux build (2026-09-08)


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
    # class Point{ x, getX }; helper(); main() calls helper() — a real reference
    # for go-to-definition. Line indices (0-based):
    #  0 class Point         5 def helper(): int
    #  1     var x: int      6     return 1
    #  2     def getX(): int 7 def main()
    #  3         return .x   8     print(helper())
    #  4 (blank)
    #  9 def add(a: int, b: int): int
    # 10     return a + b
    # 11 def caller()
    # 12     print(add(1, 2))   ← signatureHelp fired inside this call
    good_src = ("class Point\n    var x: int\n    def getX(): int\n        return .x\n\n"
                "def helper(): int\n    return 1\n"
                "def main()\n    print(helper())\n"
                "def add(a: int, b: int): int\n    return a + b\n"
                "def caller()\n    print(add(1, 2))\n")
    uri = "file:///tmp/lsp_test.zbr"  # hazard-ok:H12 a URI sent to the server with the text inline; no file is written
    # `helper` in the call on line 8 spans cols 10..15 → point at char 12.
    HELPER_USE = {"line": 8, "character": 12}

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
        {"jsonrpc": "2.0", "id": 5, "method": "textDocument/hover",
         "params": {"textDocument": {"uri": uri}, "position": HELPER_USE}},
        {"jsonrpc": "2.0", "id": 6, "method": "textDocument/definition",
         "params": {"textDocument": {"uri": uri}, "position": HELPER_USE}},
        {"jsonrpc": "2.0", "id": 7, "method": "textDocument/completion",
         "params": {"textDocument": {"uri": uri}, "position": HELPER_USE}},
        # Member completion: the leading-dot `.x` inside getX (line 3) completes to
        # the enclosing class Point's members (x, getX), NOT global keywords.
        {"jsonrpc": "2.0", "id": 8, "method": "textDocument/completion",
         "params": {"textDocument": {"uri": uri}, "position": {"line": 3, "character": 16}}},
        # Signature help inside `add(1, |2)` — cursor on the 2nd arg (char 17).
        {"jsonrpc": "2.0", "id": 9, "method": "textDocument/signatureHelp",
         "params": {"textDocument": {"uri": uri}, "position": {"line": 12, "character": 17}}},
        # Unknown request must get a MethodNotFound error, not silence.
        {"jsonrpc": "2.0", "id": 10, "method": "textDocument/foldingRange",
         "params": {"textDocument": {"uri": uri}}},
        {"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": {}},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    # Diagnostics are debounced: didChange no longer publishes immediately — a
    # ~200ms lull flushes the coalesced result.  Send through didChange, then
    # pause past the debounce window so the clean diagnostics are published before
    # the follow-up requests.  This keeps the reply order stable AND proves the
    # flush is timer-driven (didOpen still publishes immediately; didChange waits).
    stage1 = convo[:4]    # initialize, initialized, didOpen, didChange
    stage2 = convo[4:]    # documentSymbol ... shutdown, exit
    for m in stage1:
        proc.stdin.write(frame(m))
    proc.stdin.flush()
    # WAIT FOR THE FLUSH, do not sleep a fixed time. The debounce fires only after a lull
    # in INPUT; a fixed 0.6 s pause expired while a loaded server was still compiling the
    # didOpen, the stage-2 requests then arrived back to back, and the lull never came --
    # the clean diagnostics were never published (2026-09-30, 5 of 5 red with six cores
    # busy). Reading stage 1's replies until the SECOND publishDiagnostics arrives is the
    # lull, whatever the load. A watchdog kills a server that never flushes, so the gate
    # fails instead of hanging.
    import threading
    watchdog = threading.Timer(60.0, proc.kill)
    watchdog.start()
    early = []
    n_diag = 0
    while n_diag < 2:
        m = read_message(proc.stdout)
        if m is None:
            break
        early.append(m)
        if m.get("method") == "textDocument/publishDiagnostics":
            n_diag += 1
    for m in stage2:
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

    # Read EVERYTHING up to the shutdown reply, then match RESPONSES by id and take
    # diagnostics notifications in arrival order. The first version read replies in a
    # fixed sequence and slept 0.6 s to let the debounced diagnostics land first; under
    # load (a FULL tier beside it, 2026-09-30) the server took longer than that, the
    # clean diagnostics arrived after the documentSymbol reply, and the gate died on a
    # KeyError -- 2 of 3 runs red, 5 of 5 green idle. A reply order the protocol does not
    # promise is not something to assert. (Bounded: a server that never answers shutdown
    # ends at EOF when it exits.)
    msgs = list(early)
    while True:
        m = read_message(proc.stdout)
        if m is None:
            break
        msgs.append(m)
        if m.get("id") == 2 and "method" not in m:
            break
    by_id = {m["id"]: m for m in msgs if "id" in m and "method" not in m}
    diags = [m for m in msgs if m.get("method") == "textDocument/publishDiagnostics"]
    init = by_id.get(1)
    check(init and init.get("id") == 1 and "capabilities" in init.get("result", {}),
          "initialize response has capabilities")

    diag_open = diags[0] if len(diags) > 0 else None
    check(diag_open and diag_open.get("method") == "textDocument/publishDiagnostics"
          and len(diag_open["params"]["diagnostics"]) >= 1,
          "didOpen publishes >=1 diagnostic")
    if diag_open and diag_open["params"]["diagnostics"]:
        d0 = diag_open["params"]["diagnostics"][0]
        check("range" in d0 and "severity" in d0 and "message" in d0
              and d0["range"]["start"]["line"] == 1,   # 0-based: source line 2
              "diagnostic has LSP range/severity/message, 0-based line")

    diag_change = diags[1] if len(diags) > 1 else None
    check(diag_change and diag_change.get("method") == "textDocument/publishDiagnostics"
          and len(diag_change["params"]["diagnostics"]) == 0,
          "debounced didChange flushes clean diagnostics after the lull")

    docsym = by_id.get(3)
    syms = docsym.get("result", []) if docsym else []
    names = {s["name"] for s in syms}
    check(docsym and docsym.get("id") == 3 and "Point" in names and "main" in names,
          "documentSymbol returns top-level Point + main")
    point = next((s for s in syms if s["name"] == "Point"), None)
    child_names = {c["name"] for c in point["children"]} if point else set()
    check(point and point["kind"] == 5 and "x" in child_names and "getX" in child_names,
          "class Point (kind 5) has field x + method getX as children")

    fmt = by_id.get(4)
    fmt_edits = fmt.get("result", []) if fmt else []
    check(fmt and fmt.get("id") == 4 and len(fmt_edits) == 1
          and "newText" in fmt_edits[0] and "class Point" in fmt_edits[0]["newText"],
          "formatting returns a full-document TextEdit")

    hov = by_id.get(5)
    hov_val = ""
    if hov and isinstance(hov.get("result"), dict):
        hov_val = hov["result"].get("contents", {}).get("value", "")
    check(hov and hov.get("id") == 5 and "def helper(): int" in hov_val,
          "hover on a call shows the function signature")

    defn = by_id.get(6)
    dloc = defn.get("result") if defn else None
    check(defn and defn.get("id") == 6 and isinstance(dloc, dict)
          and dloc.get("uri") == uri and dloc["range"]["start"]["line"] == 5,
          "go-to-definition of helper() jumps to its declaration (line 5)")

    comp = by_id.get(7)
    items = comp.get("result", []) if comp else []
    labels = {it["label"] for it in items} if isinstance(items, list) else set()
    check(comp and comp.get("id") == 7
          and {"helper", "Point", "getX"}.issubset(labels)   # declared symbols
          and "class" in labels,                              # a keyword
          "completion offers declared symbols + keywords")

    mcomp = by_id.get(8)
    mitems = mcomp.get("result", []) if mcomp else []
    mlabels = {it["label"] for it in mitems} if isinstance(mitems, list) else set()
    check(mcomp and mcomp.get("id") == 8
          and {"x", "getX"}.issubset(mlabels)   # enclosing class members
          and "class" not in mlabels,           # narrowed — no global keywords
          "member completion after `.` narrows to the enclosing type's members")

    sig = by_id.get(9)
    sresult = sig.get("result") if sig else None
    sig_ok = False
    if isinstance(sresult, dict) and sresult.get("signatures"):
        s0 = sresult["signatures"][0]
        sig_ok = (s0.get("label") == "def add(a: int, b: int): int"
                  and len(s0.get("parameters", [])) == 2
                  and sresult.get("activeParameter") == 1)
    check(sig and sig.get("id") == 9 and sig_ok,
          "signature help shows `add` params with the 2nd arg active")

    unknown = by_id.get(10)
    check(unknown and unknown.get("id") == 10
          and isinstance(unknown.get("error"), dict)
          and unknown["error"].get("code") == -32601,
          "unknown request returns MethodNotFound (-32601), not silence")

    shut = by_id.get(2)
    check(shut and shut.get("id") == 2, "shutdown response")

    watchdog.cancel()
    proc.wait(timeout=10)
    print("lsp server smoke: %d/%d passed" % (passed, passed + failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
