#!/usr/bin/env bash
# extern_check.sh — the FFI red-team suite (BUG-258).
#
# INTENT-AUTHORED, like boundary_check and for the same reason: every expectation
# in test/extern/ was written from docs/extern_ffi_design.md BEFORE the feature
# existed, and committed RED. A suite written after the implementation can only
# ever confirm what the compiler already does. If you ever find yourself editing
# an expectation to match observed output, stop -- that converts this into a
# golden baseline with extra steps, and the repo already has three of those.
#
# DIRECTIVES (first matching line of each .zbr):
#   # @extern accepts               -> front end must ACCEPT it (`-c` exits 0)
#   # @extern rejects <text>        -> front end must REFUSE, naming <text>
#   # @extern runs                  -> must build and run; stdout must EQUAL .expected
#   # @extern emits <text>          -> emitted Zig must CONTAIN <text>
#   # @extern emits-not <text>      -> emitted Zig must NOT contain <text>
# `emits` / `emits-not` may appear more than once in a file.
#
# CHECKED BOTH COMPILERS until 2026-09-16 (the bootstrap was the regen authority and
# the one that accepted `extern` and emitted `unreachable; // abstract`, output that
# COMPILES). The bootstrap is gone -- bootstrap_sunset.md Step 3 -- so the `boot`
# leg went with it; the loops below keep their shape for one compiler.
set -uo pipefail
cd "$(dirname "$0")/.."

SELF="zig-out/bin/zebra.exe"; [ -x "$SELF" ] || SELF="zig-out/bin/zebra"
DIR="test/extern"
ONLY="${1:-}"

[ -x "$SELF" ] || { echo "extern-check: $SELF not built"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; CHECKED=0
NOTE=()

red()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
grn()  { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }

# emit SRC OUT -> writes emitted Zig, echoes the path, or returns non-zero.
# Never echoes a fallback path: a caller that greps a file which does not exist
# would find nothing and read that as "the forbidden string is absent", which is
# the reassuring answer. Absence of output must not look like a clean result.
emit() {
    local compiler="$1" src="$2" tag="$3"
    local out="$WORK/$tag"; mkdir -p "$out"
    "$SELF" --output-dir "$out" "$src" >/dev/null 2>&1
    local base; base="$(basename "$src" .zbr)"
    [ -f "$out/$base.zig" ] || return 1
    printf '%s' "$out/$base.zig"
}

check_one() {
    local zbr="$1" base; base="$(basename "$zbr" .zbr)"
    local kind arg
    kind="$(grep -m1 -oE '^# @extern [a-z-]+' "$zbr" | awk '{print $3}')"
    if [ -z "$kind" ]; then
        red "$base (no '# @extern' directive — the runner cannot know what to assert)"
        return
    fi
    CHECKED=$((CHECKED+1))

    case "$kind" in
      accepts)
        for c in self; do
            local bin="$SELF"
            if "$bin" -c "$zbr" >/dev/null 2>&1; then grn "$base [$c] accepted"
            else red "$base [$c] REJECTED but should be accepted"; fi
        done ;;
      rejects)
        arg="$(grep -m1 '^# @extern rejects ' "$zbr" | sed -E 's/^# @extern rejects[[:space:]]*//')"
        for c in self; do
            local bin="$SELF"
            local out; out="$("$bin" -c "$zbr" 2>&1)"
            if [ -n "$out" ] && printf '%s' "$out" | grep -qi -- "$arg"; then
                grn "$base [$c] refused, naming '$arg'"
            elif "$bin" -c "$zbr" >/dev/null 2>&1; then
                red "$base [$c] ACCEPTED but should be refused"
            else
                red "$base [$c] refused but did not name '$arg'"
            fi
        done ;;
      runs)
        local exp="$DIR/$base.expected"
        if [ ! -f "$exp" ]; then red "$base (@extern runs with no .expected)"; return; fi
        # 2>&1 IS REQUIRED, not defensive habit. Zebra's `print` writes to
        # STDERR -- confirmed against a standalone compiled exe, so it is
        # language behaviour and not a `zebra run` artifact. Capturing only
        # stdout yields an empty string for a program that printed correctly,
        # and this runner would then report a PASSING regression guard as a
        # failure. `output_sweep.sh:142` and `selfhost_smoke.sh:181` both merge
        # for the same reason; matching them keeps one convention.
        local got; got="$("$SELF" run "$zbr" 2>&1 | tail -n "$(wc -l < "$exp")")"
        if [ "$got" = "$(cat "$exp")" ]; then grn "$base [self] output matches"
        else red "$base [self] output differs (want '$(tr '\n' '|' < "$exp")' got '$(printf '%s' "$got" | tr '\n' '|')')"; fi ;;
      emits|emits-not)
        local f
        for c in self; do
            if ! f="$(emit "$c" "$zbr" "$base.$c")"; then
                red "$base [$c] produced no emitted Zig — cannot assert its shape"
                continue
            fi
            local ok=1
            while IFS= read -r line; do
                local want; want="$(printf '%s' "$line" | sed -E 's/^# @extern emits[[:space:]]*//')"
                grep -qF -- "$want" "$f" || { red "$base [$c] emit MISSING '$want'"; ok=0; }
            done < <(grep '^# @extern emits ' "$zbr")
            while IFS= read -r line; do
                local bad; bad="$(printf '%s' "$line" | sed -E 's/^# @extern emits-not[[:space:]]*//')"
                grep -qF -- "$bad" "$f" && { red "$base [$c] emit CONTAINS forbidden '$bad'"; ok=0; }
            done < <(grep '^# @extern emits-not ' "$zbr")
            [ "$ok" = 1 ] && grn "$base [$c] emit shape correct"
        done ;;
      *)
        red "$base (unknown @extern kind '$kind')" ;;
    esac
}

echo "── extern/FFI red-team (BUG-258)"
shopt -s nullglob
for zbr in "$DIR"/*.zbr; do
    [ -n "$ONLY" ] && [[ "$zbr" != *"$ONLY"* ]] && continue
    check_one "$zbr"
done

# A suite that checked nothing must not print a pass. The probes are tracked
# files; if the glob comes back empty the directory is gone or the runner is
# being run from the wrong place, and either way it has no findings to report.
echo
if [ "$CHECKED" -eq 0 ]; then
    echo "extern-check: NO PROBES FOUND in $DIR — refusing to report"
    exit 1
fi
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mextern-check: %d/%d assertions pass across %d probe(s)\033[0m\n' "$PASS" "$((PASS+FAIL))" "$CHECKED"
    exit 0
fi
printf '\033[31mextern-check: %d of %d assertions FAILED across %d probe(s)\033[0m\n' "$FAIL" "$((PASS+FAIL))" "$CHECKED"
exit 1
