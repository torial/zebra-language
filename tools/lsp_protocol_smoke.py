#!/usr/bin/env python3
"""Protocol-level smoke for `zebra lsp` over stdio (the seam zebra-ide's LSP client uses).

    py tools/lsp_protocol_smoke.py [path/to/zebra]

Controls, each of which was seen RED before it went green (2026-09-06):
  * framing: a pipe delivering several messages at once must not lose any (BUG-334:
    per-call stdin read-ahead swallowed the request; the server answered nothing)
  * references on `area` in examples/showcase.zbr: exactly its def + its one call;
    the word inside the string literal "total area:" must NOT count
  * rename to a non-identifier is refused (null), rename to an identifier edits both
Exit 0 on all-pass; 1 otherwise. Stdlib only.
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
zebra = sys.argv[1] if len(sys.argv) > 1 else next(
    p for p in (os.path.join(ROOT, "zig-out", "bin", "zebra.exe"), os.path.join(ROOT, "zig-out", "bin", "zebra")) if os.path.exists(p))
src = os.path.join(ROOT, "examples", "showcase.zbr")
uri = "file:///" + src.replace("\\", "/").lstrip("/")
text = open(src, encoding="utf-8").read()
lines = text.split("\n")
def_line = next(i for i, l in enumerate(lines) if l.startswith("def area("))
call_line = next(i for i, l in enumerate(lines) if "total + area(s)" in l)
str_line = next(i for i, l in enumerate(lines) if '"total area:' in l)
call_col = lines[call_line].index("area(")

def frame(o):
    b = json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n" % len(b) + b
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {"uri": uri, "languageId": "zebra", "version": 1, "text": text}}},
    {"jsonrpc": "2.0", "id": 2, "method": "textDocument/references", "params": {"textDocument": {"uri": uri}, "position": {"line": call_line, "character": call_col}, "context": {"includeDeclaration": True}}},
    {"jsonrpc": "2.0", "id": 3, "method": "textDocument/rename", "params": {"textDocument": {"uri": uri}, "position": {"line": call_line, "character": call_col}, "newName": "not an ident"}},
    {"jsonrpc": "2.0", "id": 4, "method": "textDocument/rename", "params": {"textDocument": {"uri": uri}, "position": {"line": call_line, "character": call_col}, "newName": "surface"}},
    {"jsonrpc": "2.0", "id": 5, "method": "shutdown", "params": {}},
]
# All messages in ONE write: that is the framing control (several frames in one pipe read).
r = subprocess.run([zebra, "lsp"], input=b"".join(frame(m) for m in msgs), capture_output=True, timeout=120)
out = r.stdout
replies = {}
i = 0
while True:
    h = out.find(b"\r\n\r\n", i)
    if h < 0: break
    n = int([l for l in out[i:h].decode().split("\r\n") if l.lower().startswith("content-length")][0].split(":")[1])
    body = json.loads(out[h + 4:h + 4 + n]); i = h + 4 + n
    if "id" in body: replies[body["id"]] = body

fails = []
def check(cond, label):
    print(("  PASS: " if cond else "  FAIL: ") + label)
    if not cond: fails.append(label)

check(1 in replies and 5 in replies, "framing: initialize and shutdown both answered from one pipe write")
caps = replies.get(1, {}).get("result", {}).get("capabilities", {})
check(caps.get("referencesProvider") is True and caps.get("renameProvider") is True, "capabilities advertise references + rename")
refs = replies.get(2, {}).get("result") or []
got = sorted((x["range"]["start"]["line"], x["range"]["start"]["character"]) for x in refs)
check(got == sorted([(def_line, 4), (call_line, call_col)]), f"references on area = def + call only (got {got})")
check(all(x["range"]["start"]["line"] != str_line for x in refs), "occurrence inside the string literal is NOT a reference")
check(replies.get(3, {}).get("result") is None, "rename to a non-identifier is refused")
ch = (replies.get(4, {}).get("result") or {}).get("changes", {})
edits = ch.get(uri, [])
check(len(edits) == 2 and all(e["newText"] == "surface" for e in edits), f"rename edits both occurrences ({len(edits)} edits)")
print(f"lsp protocol smoke: {6 - len(fails)}/6 passed")
sys.exit(1 if fails else 0)
