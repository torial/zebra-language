#!/usr/bin/env bash
# node_addon_test.sh — end-to-end test for `zebra --target node-addon`.
#
# For each positive fixture in test/node_addon/<name>.zbr: build it to a .node
# and run test/node_addon/<name>.check.js, which require()s the addon and
# asserts.  For the negative fixture (bad.zbr) the build must FAIL.
#
# NOT wired into `zig build test`: it needs Node + the node-gyp headers (fetch
# once via `npx --yes node-gyp install`), which aren't present everywhere.  Run
# it on demand from the repo root.  Uses the selfhost zebra.exe by default;
# override with ZEBRA=... (e.g. zig-out/bin/zebra-bootstrap.exe).
#
#   tools/node_addon_test.sh            # uses zig-out/bin/zebra.exe
#   ZEBRA=zig-out/bin/zebra-bootstrap.exe tools/node_addon_test.sh
set -u

ZEBRA="${ZEBRA:-zig-out/bin/zebra.exe}"
DIR="test/node_addon"
POS="math strings"
fail=0

if ! command -v node >/dev/null 2>&1; then
    echo "node_addon_test: 'node' not found on PATH — skipping (install Node + 'npx node-gyp install')"
    exit 0
fi

# Clean any prior generated artifacts (gitignored) so a stale .node can't mask a failure.
rm -f "$DIR"/*.node "$DIR"/*.d.ts
for name in $POS; do rm -f "$DIR/$name.js"; done

for name in $POS; do
    echo "── $name"
    if ! "$ZEBRA" --target node-addon "$DIR/$name.zbr" >/tmp/na_$name.log 2>&1; then
        echo "  FAIL: build of $name.zbr failed"; tail -5 /tmp/na_$name.log; fail=1; continue
    fi
    if ! node "$DIR/$name.check.js"; then
        echo "  FAIL: $name.check.js assertions failed"; fail=1
    fi
done

# Negative: bad.zbr must NOT build.
echo "── bad (expect build failure)"
if "$ZEBRA" --target node-addon "$DIR/bad.zbr" >/tmp/na_bad.log 2>&1; then
    echo "  FAIL: bad.zbr built but should have been rejected (non-exportable param type)"; fail=1
else
    echo "  ok: bad.zbr correctly rejected"
fi

# Clean generated artifacts.
rm -f "$DIR"/*.node "$DIR"/*.d.ts
for name in $POS; do rm -f "$DIR/$name.js"; done

if [ "$fail" -eq 0 ]; then echo "node-addon tests: PASS"; else echo "node-addon tests: FAIL"; fi
exit $fail
