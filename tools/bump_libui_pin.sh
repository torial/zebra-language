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
export PYTHONIOENCODING=utf-8   # the heredoc prints a box-drawing dash; a cp1252 console took the whole script down on it
cd "$(dirname "$0")/.."
sha=${1:?usage: bump_libui_pin.sh <commit-sha>}
url="git+https://github.com/torial/zig-libui-ng?ref=main#$sha"
echo "── fetching $url"
hash=$(zig fetch "$url" 2>&1 | tail -1)
case "$hash" in bindings_libui_ng-*) ;; *) echo "zig fetch did not return a package hash: $hash"; exit 1;; esac
echo "── hash $hash"
"${PYTHON:-python}" - "$url" "$hash" <<'PY'
import re, sys
url, h = sys.argv[1], sys.argv[2]
p = "selfhost/main.zbr"; s = open(p, encoding="utf-8", newline="").read()
pat_url = r'\.url  = "git\+https://github\.com/torial/zig-libui-ng\?ref=main#[0-9a-f]+"'
assert re.search(pat_url, s), "pin not found in luiBuildZon"
s2 = re.sub(pat_url, f'.url  = "{url}"', s, count=1)
s2 = re.sub(r'\.hash = "bindings_libui_ng-[^"]+"', f'.hash = "{h}"', s2, count=1)
if s2 == s:
    print("── selfhost/main.zbr already at this pin (a previous run rewrote it); continuing")
else:
    # newline="" on BOTH ends: the .zbr tokenizer is LF-only, and until 2026-09-22 this
    # write used the platform default, so on Windows the first successful run left
    # main.zbr CRLF, bootstrap_check refused it, and the RE-run tripped the (then
    # unconditional) assertion because the pin was already in place -- two errors,
    # neither naming the cause. H1 in hazard_lint, in a heredoc it does not scan.
    open(p, "w", encoding="utf-8", newline="").write(s2)
    print("── selfhost/main.zbr updated")
PY
bash tools/bootstrap_check.sh --update | tail -1
zig build
echo "── done: pin = $sha ($hash). Witness: zebra --gui-backend=libui_ng examples/tabs_sci_smoke.zbr"
