#!/usr/bin/env bash
# Phase 0 N-API spike — proven build recipe.
#
# Produces spike/hello_napi.node, a Node native addon loadable via require().
# Verified 2026-06-29 on Windows + Node v24.13.0 + Zig 0.16: `node test.js`
# prints "spike: ok".  This is the recipe Phase 5 (`zebra --target node-addon`)
# will reproduce from the compiler.
#
# Prereq (one-time): fetch Node headers + node.lib into the node-gyp cache:
#   npx --yes node-gyp install
#
# Zig must be on PATH (this repo uses /c/Users/Sean/.zvm/bin/zig.exe).
set -euo pipefail
cd "$(dirname "$0")"

NODE_VER="$(node -p 'process.version.slice(1)')"          # e.g. 24.13.0
CACHE_UNIX="$HOME/AppData/Local/node-gyp/Cache/$NODE_VER"
CACHE="$(cygpath -m "$CACHE_UNIX" 2>/dev/null || echo "$CACHE_UNIX")"   # C:/… form for zig
INC="$CACHE/include/node"
# node-gyp caches node.lib under <arch>/ (x64 here); allow an explicit override.
NODELIB="${ZEBRA_NODE_LIB:-$CACHE/x64/node.lib}"

[ -f "$INC/node_api.h" ] || { echo "Node headers missing at $INC — run: npx --yes node-gyp install" >&2; exit 1; }
[ -f "$NODELIB" ]        || { echo "node.lib missing at $NODELIB — set ZEBRA_NODE_LIB or run node-gyp install" >&2; exit 1; }

# -dynamic → shared lib; link node.lib (import lib for node.exe's N-API exports);
# -femit-bin names the output .node directly (it is a PE DLL Node dlopen()s).
zig build-lib hello_napi.zig -dynamic -lc \
  -I"$INC" "$NODELIB" \
  -femit-bin=hello_napi.node

echo "built hello_napi.node — verify with:  node test.js"
