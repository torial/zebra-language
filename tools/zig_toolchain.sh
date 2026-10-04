#!/usr/bin/env bash
# The repo's PINNED Zig (docs/design/zig017_migration.md, Phase B). SOURCE it:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/zig_toolchain.sh"
#
# It puts the pinned zig first on PATH and exports ZEBRA_ZIG, so every `zig` a tool runs
# AND every zig the compiler runs (main.zbr zigExe() honours ZEBRA_ZIG) is the same one.
#
# The pin is `.zig-version` at the repo root. `ZEBRA_ZIG_VERSION` overrides it explicitly
# (regen_recover --from an older commit uses that commit's pin). Resolution, first match:
#   1. $ZEBRA_ZIG_DIR            an explicit directory holding zig[.exe]
#   2. ~/.zvm/<version>/         a local zvm install (the machine DEFAULT, ~/.zvm/bin, is
#                                 deliberately NOT consulted: it is shared with other
#                                 projects and may lag the pin)
#   3. `zig` already on PATH     CI puts the downloaded toolchain there
# The candidate's `zig version` must EQUAL the pin, or this REFUSES (exit 2): a gate measured
# with the wrong zig is not a result, and nothing downstream could tell.
#
# Replaces 20 copies of `export PATH="/c/Users/Sean/.zvm/bin:$PATH"` -- an AMBIENT choice
# (whatever the shared default happened to be) that would have kept every tool on 0.16
# after the pin moved, silently.
_zt_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${ZEBRA_ZIG_VERSION:-}" ]; then
    ZIG_PIN="$ZEBRA_ZIG_VERSION"
elif [ -f "$_zt_root/.zig-version" ]; then
    ZIG_PIN="$(tr -d ' \r\n' < "$_zt_root/.zig-version")"
else
    echo "zig_toolchain: no .zig-version at $_zt_root and ZEBRA_ZIG_VERSION unset" >&2
    exit 2
fi
_zt_exe=""
for _zt_d in "${ZEBRA_ZIG_DIR:-}" "$HOME/.zvm/$ZIG_PIN" "/c/Users/Sean/.zvm/$ZIG_PIN"; do
    [ -n "$_zt_d" ] || continue
    for _zt_n in zig.exe zig; do
        if [ -x "$_zt_d/$_zt_n" ]; then _zt_exe="$_zt_d/$_zt_n"; break 2; fi
    done
done
if [ -z "$_zt_exe" ]; then
    _zt_exe="$(command -v zig 2>/dev/null || true)"
fi
_zt_got=""
[ -n "$_zt_exe" ] && _zt_got="$("$_zt_exe" version 2>/dev/null | tr -d '\r')"
if [ "$_zt_got" != "$ZIG_PIN" ]; then
    echo "zig_toolchain: the pinned Zig is $ZIG_PIN but the best candidate is '${_zt_exe:-none}' (version '${_zt_got:-none}')." >&2
    echo "  Install it (zvm install $ZIG_PIN), or set ZEBRA_ZIG_DIR to a directory holding Zig $ZIG_PIN." >&2
    exit 2
fi
export PATH="$(dirname "$_zt_exe"):$PATH"
export ZEBRA_ZIG="$_zt_exe"
export ZIG_PIN
unset _zt_root _zt_d _zt_n _zt_got
