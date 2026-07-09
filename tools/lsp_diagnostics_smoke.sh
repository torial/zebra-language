#!/usr/bin/env bash
# Smoke test for the `zebra diagnostics <file> --out <json>` seam (the LSP
# diagnostics foundation).  Runs the compiler's front-end on fixtures with known
# issues and checks the emitted JSON.  Uses --out (a file) rather than stdout,
# because `print` lands on stderr on the Windows fast-backend build.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZEBRA="$ROOT/zig-out/bin/zebra.exe"
TMP="${TMPDIR:-/tmp}/lsp_diag_$$"
mkdir -p "$TMP"
PASS=0
FAIL=0

check() {
  local name="$1" file="$2" pattern="$3"
  local out="$TMP/$name.json"
  "$ZEBRA" diagnostics "$ROOT/test/lsp/$file" --out "$out" >/dev/null 2>&1
  if [[ ! -s "$out" ]] && [[ "$pattern" != "^\[\]$" ]]; then
    echo "  FAIL: $name (no output file)"; FAIL=$((FAIL+1)); return
  fi
  local content; content="$(cat "$out" 2>/dev/null)"
  if echo "$content" | grep -qE "$pattern"; then
    echo "  PASS: $name"; PASS=$((PASS+1))
  else
    echo "  FAIL: $name — expected /$pattern/, got: $content"; FAIL=$((FAIL+1))
  fi
}

echo "lsp diagnostics smoke:"
# Type error → a diagnostic mentioning the mismatch, positioned on line 2.
check type_error   type_error.zbr   '"line":2.*"severity":"error".*type mismatch'
# Syntax error → a diagnostic on the malformed signature.
check syntax_error syntax_error.zbr '"severity":"error"'
# Clean file → empty array.
check clean        clean.zbr        '^\[\]$'

rm -rf "$TMP"
echo "lsp diagnostics smoke: $PASS/$((PASS+FAIL)) passed"
[[ "$FAIL" -eq 0 ]]
