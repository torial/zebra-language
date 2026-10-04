#!/usr/bin/env bash
# win_sema_check.sh — the Windows leg of tools/cross_sema_check.sh (2026-09-07; folded into
# it 2026-10-04, which added the Linux targets). Kept so its documented usage still works.
# Usage: tools/win_sema_check.sh [file.zbr ...]
exec bash "$(dirname "$0")/cross_sema_check.sh" --target x86_64-windows-gnu "$@"
