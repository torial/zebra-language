#!/usr/bin/env bash
# bump_libui_pin.sh — point the generated libui_ng project at a new zig-libui-ng commit.
#
#   bash tools/bump_libui_pin.sh <commit-sha>       (after `git push` in zig-libui-ng)
#
# Fetches the package with Zig to learn its content hash, rewrites the url + hash in
# selfhost/main.zbr luiBuildZon(), regenerates selfhost/*.zig and rebuilds. Then run
# `zebra --gui-backend=libui_ng examples/tabs_sci_smoke.zbr` as the witness.
# Why a script: the hash is Zig's, not git's; guessing it produces a project that
# fails to fetch with a message that names neither file.
set -eu
cd "$(dirname "$0")/.."
sha=${1:?usage: bump_libui_pin.sh <commit-sha>}
url="git+https://github.com/torial/zig-libui-ng?ref=main#$sha"
echo "── fetching $url"
hash=$(zig fetch "$url" 2>&1 | tail -1)
case "$hash" in bindings_libui_ng-*) ;; *) echo "zig fetch did not return a package hash: $hash"; exit 1;; esac
echo "── hash $hash"
py - "$url" "$hash" <<'PY'
import re, sys
url, h = sys.argv[1], sys.argv[2]
p = "selfhost/main.zbr"; s = open(p, encoding="utf-8").read()
s2 = re.sub(r'\.url  = "git\+https://github\.com/torial/zig-libui-ng\?ref=main#[0-9a-f]+"', f'.url  = "{url}"', s, count=1)
s2 = re.sub(r'\.hash = "bindings_libui_ng-[^"]+"', f'.hash = "{h}"', s2, count=1)
assert s2 != s, "pin not found in luiBuildZon"
open(p, "w", encoding="utf-8").write(s2)
print("── selfhost/main.zbr updated")
PY
bash tools/bootstrap_check.sh --update | tail -1
zig build
echo "── done: pin = $sha ($hash). Witness: zebra --gui-backend=libui_ng examples/tabs_sci_smoke.zbr"
