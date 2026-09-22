#!/usr/bin/env python3
# pins: BUG-430  (the drive-path leg; real on Windows, SKIPs and says so elsewhere)
"""`zebra lsp` sees the `use` graph around a document, not only OPEN documents.

    py tools/lsp_workspace_smoke.py [path/to/zebra]

Found by zebra-ide's rename_workspace_test (2026-09-08): with only main.zbr open, a
rename at the call site of an imported `area` came back for ONE file and Definition
answered null. Controls (the references / definition / rename-from-main cases were seen
RED on the 09-07 server through zebra-ide's probes; the dependents case and the
other.zbr exclusion were written with the fix and not flipped):
  * references from main.zbr (geo.zbr NOT open) = def + use in geo, import + call in main
  * definition from main.zbr lands in geo.zbr (an unopened module)
  * rename from main.zbr edits BOTH files
  * rename from geo.zbr (the module; main.zbr NOT open) reaches its dependent main.zbr
  * a sibling that does not `use` geo (other.zbr, which has its own `area`) is NOT touched
Exit 0 on all-pass; 1 otherwise. Stdlib only.
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
zebra = sys.argv[1] if len(sys.argv) > 1 else next(
    p for p in (os.path.join(ROOT, "zig-out", "bin", "zebra.exe"), os.path.join(ROOT, "zig-out", "bin", "zebra")) if os.path.exists(p))

ws = tempfile.mkdtemp(prefix="zebra_lsp_ws_")
geo = "def area(s: int): int\n    return s * s\n\ndef perimeter(s: int): int\n    return 4 * area(s) / s\n"
main = "use geo exposing area\n\ndef main()\n    var total: int = 0\n    total = total + area(3)\n    print(total.toString())\n"
other = "def area(x: int): int\n    return x\n"
for name, text in (("geo.zbr", geo), ("main.zbr", main), ("other.zbr", other)):
    with open(os.path.join(ws, name), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
def uri_of(name):
    p = os.path.join(ws, name).replace("\\", "/")
    return "file:///" + p.lstrip("/")
U = {n: uri_of(n) for n in ("geo.zbr", "main.zbr", "other.zbr")}

def frame(o):
    b = json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n" % len(b) + b
def run(msgs):
    r = subprocess.run([zebra, "lsp"], input=b"".join(frame(m) for m in msgs), capture_output=True, timeout=120)
    out, replies, i = r.stdout, {}, 0
    while True:
        h = out.find(b"Content-Length:", i)
        if h < 0: break
        e = out.find(b"\r\n\r\n", h); n = int(out[h + 15:e].strip()); body = out[e + 4:e + 4 + n]; i = e + 4 + n
        m = json.loads(body)
        if "id" in m: replies[m["id"]] = m
    return replies

fails = 0
def check(cond, label):
    global fails
    print(("  PASS: " if cond else "  FAIL: ") + label)
    if not cond: fails += 1

# main.zbr open, geo.zbr and other.zbr NOT open
call_line, call_col = 4, main.split("\n")[4].index("area(")
rep = run([
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": U["main.zbr"], "languageId": "zebra", "version": 1, "text": main}}},
    {"jsonrpc": "2.0", "id": 2, "method": "textDocument/references", "params": {"textDocument": {"uri": U["main.zbr"]}, "position": {"line": call_line, "character": call_col}, "context": {"includeDeclaration": True}}},
    {"jsonrpc": "2.0", "id": 3, "method": "textDocument/definition", "params": {"textDocument": {"uri": U["main.zbr"]}, "position": {"line": call_line, "character": call_col}}},
    {"jsonrpc": "2.0", "id": 4, "method": "textDocument/rename", "params": {"textDocument": {"uri": U["main.zbr"]}, "position": {"line": call_line, "character": call_col}, "newName": "surface"}},
    {"jsonrpc": "2.0", "id": 5, "method": "shutdown", "params": {}},
])
refs = rep.get(2, {}).get("result") or []
by_uri = {}
for loc in refs: by_uri.setdefault(loc["uri"], []).append((loc["range"]["start"]["line"], loc["range"]["start"]["character"]))
check(sorted(by_uri.get(U["geo.zbr"], [])) == [(0, 4), (4, 15)], f"references reach the unopened module geo.zbr (got {by_uri.get(U['geo.zbr'])})")
check(sorted(by_uri.get(U["main.zbr"], [])) == [(0, 17), (4, 20)], f"references in main.zbr = import + call (got {by_uri.get(U['main.zbr'])})")
check(U["other.zbr"] not in by_uri, "other.zbr (does not use geo) is not searched")
d = rep.get(3, {}).get("result")
check(isinstance(d, dict) and d.get("uri") == U["geo.zbr"] and d["range"]["start"]["line"] == 0, f"definition lands in geo.zbr line 0 (got {d})")
ch = (rep.get(4, {}).get("result") or {}).get("changes", {})
check(set(ch.keys()) == {U["geo.zbr"], U["main.zbr"]}, f"rename from main.zbr edits geo.zbr + main.zbr only (got {sorted(ch.keys())})")
check(len(ch.get(U["geo.zbr"], [])) == 2 and len(ch.get(U["main.zbr"], [])) == 2, "rename edits: 2 in geo.zbr, 2 in main.zbr")

# geo.zbr open, main.zbr NOT open: the dependents direction
rep = run([
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": U["geo.zbr"], "languageId": "zebra", "version": 1, "text": geo}}},
    {"jsonrpc": "2.0", "id": 2, "method": "textDocument/rename", "params": {"textDocument": {"uri": U["geo.zbr"]}, "position": {"line": 0, "character": 4}, "newName": "surface"}},
    {"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}},
])
ch = (rep.get(2, {}).get("result") or {}).get("changes", {})
check(set(ch.keys()) == {U["geo.zbr"], U["main.zbr"]}, f"rename from geo.zbr reaches its unopened dependent main.zbr, not other.zbr (got {sorted(ch.keys())})")

# BUG-430: a client that spells the open document `file://C:/x` (two slashes; the spec
# form is `file:///C:/x`) must get the disk-resolved modules spelled the SAME way, because
# LSP compares URIs as strings and the client's edit list otherwise drops them (zebra-ide's
# rename_workspace_test on torial: geo.zbr's edit named `file:///C:/...` beside the client's
# `file://C:/.../main.zbr`). ONLY A DRIVE PATH CAN DISCRIMINATE: without a drive letter the
# two-slash form is a RELATIVE path (`file://tmp/x` -> `tmp/x`), which the server spells back
# with two slashes whether or not the fix is present -- measured, red-check 2026-09-21. So the
# leg runs where it means something and says SKIP elsewhere rather than printing a pass.
wsf = ws.replace("\\", "/")
if len(wsf) > 1 and wsf[1] == ":":
    U2 = {n: "file://" + wsf + "/" + n for n in ("geo.zbr", "main.zbr")}
    rep = run([
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": U2["main.zbr"], "languageId": "zebra", "version": 1, "text": main}}},
        {"jsonrpc": "2.0", "id": 2, "method": "textDocument/rename", "params": {"textDocument": {"uri": U2["main.zbr"]}, "position": {"line": call_line, "character": call_col}, "newName": "surface"}},
        {"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}},
    ])
    ch = (rep.get(2, {}).get("result") or {}).get("changes", {})
    check(set(ch.keys()) == {U2["geo.zbr"], U2["main.zbr"]}, f"BUG-430: a two-slash client URI gets its unopened module spelled the same way (got {sorted(ch.keys())})")
    total = 8
else:
    print("  SKIP: BUG-430 leg needs a drive-letter path (two-slash form is relative here; cannot discriminate)")
    total = 7

print(f"lsp workspace smoke: {total - fails}/{total} passed")
sys.exit(1 if fails else 0)
