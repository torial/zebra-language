#!/usr/bin/env bash
# output_sweep.sh — THE BEHAVIOUR GATE: does the corpus still produce the RIGHT OUTPUT?
#
# WHY THIS EXISTS
# ---------------
# Every other heavy gate asks a question about COMPILABILITY:
#
#   compile_check / full_sweep / divergence  ->  "does the emitted Zig compile?"
#   bootstrap_check (round-trip)             ->  "is the compiler self-consistent?"
#   smoke (bare `smoke` helper, 101 files)   ->  "did the front end error?"  (emit only —
#                                                 it does not even compile the result)
#
# None of them RUNS a program and looks at what it printed. So a bug whose symptom is
# valid Zig that produces the WRONG OUTPUT is invisible to all of them, at any corpus
# size. BUG-226 is the receipt: `for t in s.tokenize(",")` typed its loop element wrongly
# and emitted `{any}` instead of `{s}`, printing `{ 97 }` where `a` was meant. Perfectly
# good Zig. It would have survived every tier indefinitely.
#
# Measured 2026-07-29, which is what motivated this tool: of the 335 corpus files known
# to emit+compile clean, only 126 had their behaviour checked by anything (`smoke_run`
# expected-output compares plus 8 `zebra test` files). 209 compile-clean files had their
# behaviour checked by NOTHING.
#
# WHAT IT CAN AND CANNOT TELL YOU
# -------------------------------
# It is a GOLDEN baseline, so it records CURRENT behaviour — bugs included. It catches
# REGRESSIONS, not existing wrongness. That is the same limitation full_sweep_baseline
# has, and that gate is still the most valuable one in the set. Do not read a green
# output-sweep as "the corpus behaves correctly"; read it as "the corpus behaves as it
# did when the baseline was taken."
#
#   bash tools/output_sweep.sh --update-baseline   # record current behaviour (runs 3x)
#   bash tools/output_sweep.sh --gate              # FAIL on any output diff vs baseline
#   bash tools/output_sweep.sh --only bug226       # tight loop on a substring
#
# NONDETERMINISM IS DERIVED, NEVER HAND-MAINTAINED — BY TWO MECHANISMS
# ---------------------------------------------------------------------
# Clocks, RNG, ports, temp paths, thread interleaving and address printing all make an
# output legitimately vary. A hand-written skip list rots silently and quietly shrinks
# coverage, so both mechanisms below are derived and regenerated on every re-baseline:
#
#   1. BY CAUSE (capability_reason) — anything that reaches the NETWORK is excluded
#      structurally, before it is ever run. This exists because mechanism 2 provably
#      cannot cover it: http_test/https_test were sampled three times, agreed three
#      times (the remote was 503 throughout), and failed on the very next gate run
#      with a 200. Repeated identical failure is indistinguishable from determinism.
#   2. BY OBSERVATION (3 samples) — for local nondeterminism we cannot classify.
#
# Volatile FIELDS (durations) are normalised in `norm()` rather than excluded, which
# keeps the surrounding structure under test instead of dropping the whole file.
#
# The order matters: cause first, because it needs no samples and skips the work.
#
# Gate runs execute each file ONCE (determinism was already established at baseline time),
# which is what keeps the gate to roughly half the baselining cost.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"
export PATH="/c/Users/Sean/.zvm/bin:$PATH"

ZEBRA="$REPO/zig-out/bin/zebra.exe"
BASELINE="$REPO/tools/output_baseline.txt"
EXCLUSIONS="$REPO/tools/output_baseline_excluded.txt"
CANDIDATES="$REPO/tools/full_sweep_baseline.txt"   # the emit+compile-clean set
PER_FILE_LINES=60          # keep the manifest reviewable...
TIMEOUT_SECS=25            # ...and a hung server/REPL test from wedging the sweep

GATE=0; UPDATE=0; ONLY=""; SHOW=0; MODE="default"; MODE_FLAGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --gate) GATE=1 ;;
        --update-baseline) UPDATE=1 ;;
        --only) ONLY="${2:-}"; shift ;;
        --show) SHOW=1 ;;
        --mode) MODE="${2:-default}"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# A2 — THE MODE DIFFERENTIAL.
#
# These emit/build modes must all produce the SAME program behaviour; they differ in how
# the code is packaged, not in what it means. So they are compared against the SAME
# baseline rather than each getting one of their own — which is the whole trick, and the
# reason this cost almost nothing to add. A difference IS the bug.
#
# Until now these axes were only ever compared for COMPILABILITY (compile_check runs the
# corpus with --no-runtime-module and checks it still builds). Nothing checked that they
# still *behave* the same.
case "$MODE" in
    default)  MODE_FLAGS="" ;;
    inline)   MODE_FLAGS="--no-runtime-module" ;;   # inline runtime instead of zebra_rt.zig
    turbo)    MODE_FLAGS="--turbo" ;;               # contracts stripped
    release)  MODE_FLAGS="--release" ;;             # LLVM path instead of the fast backend
    *) echo "unknown --mode: $MODE (default|inline|turbo|release)" >&2; exit 2 ;;
esac
# --turbo is the interesting one: it removes contract checks, so a DIFFERENCE here means
# a contract would have fired in the default build — i.e. the program relies on a check
# that release builds do not perform. That is a finding, not noise.
# --release additionally exercises a different BACKEND (LLVM), so it is much slower to
# build; expect it to be used with --only or run rarely.

# Checked HERE, before any work is done. The first version of this guard sat after the
# main loop, so it refused only AFTER running the whole corpus — a check that takes 13
# minutes to say "no" is a check people route around. It also came within one kill of
# overwriting the default baseline with turbo output.
if [ "$UPDATE" = 1 ] && [ "$MODE" != "default" ]; then
    echo "REFUSING: --update-baseline is only valid in the default mode." >&2
    echo "The baseline defines DEFAULT behaviour, and every other mode is compared" >&2
    echo "against it. Recording mode '$MODE' into it would silently redefine the" >&2
    echo "reference — after which the differential could never find anything." >&2
    exit 2
fi

# The vacuity control FOR THIS TOOL. If `run_one` ever stops capturing program output —
# a changed chatter prefix, a compiler that writes to a different stream, a filter that
# eats too much — every entry becomes the empty string, every entry then MATCHES, and the
# gate is green forever while measuring nothing. An empty output is legitimate for a few
# fixtures, so this is a proportion check rather than a per-file error: past this share,
# refuse to write a baseline that probably records silence.
MAX_EMPTY_FRACTION_PCT=25

[ -x "$ZEBRA" ] || { echo "no compiler at $ZEBRA — run \`zig build\` first" >&2; exit 2; }
[ -f "$CANDIDATES" ] || { echo "no $CANDIDATES — run full_sweep.sh --update-baseline" >&2; exit 2; }

OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT

# Strip the compiler's own progress chatter so the manifest holds PROGRAM output only.
# Without this, every entry would carry the emitted .zig path — which is a temp dir and
# therefore itself nondeterministic, and would exclude the entire corpus.
run_one() { # $1 = test/foo.zbr ; echoes program output, or a classification token
    local zbr="$1" raw rc
    # $MODE_FLAGS is unquoted deliberately: it is either empty or a single flag, and an
    # empty quoted "" would be passed to the compiler as a bogus argument.
    raw=$(timeout "$TIMEOUT_SECS" "$ZEBRA" $MODE_FLAGS "$zbr" 2>&1); rc=$?
    if [ "$rc" -eq 124 ]; then printf '<<TIMEOUT>>'; return; fi
    printf '%s' "$raw" | grep -vE '^wrote |^compiling:|^ *parsing\.\.\.|^ *parsed OK|^ *resolved OK'
}

# EXCLUDE BY CAUSE, not only by observation.
#
# Sampling cannot establish determinism for a program whose output depends on the world
# outside this machine. Proven the hard way on 2026-07-30: http_test and https_test were
# sampled THREE times during baselining and agreed every time — because the remote server
# was returning 503 on all three. The very next gate run got 200 and failed. Three
# identical failures look exactly like determinism.
#
# So anything that reaches the network is excluded structurally, whatever the samples say.
# Over-excluding a handful of files is far cheaper than a gate that fails for reasons
# nobody controls: a behaviour gate that cries wolf gets re-baselined without being read,
# and then it is worth nothing. Sampling still handles the residual (local nondeterminism
# we cannot classify), and volatile FIELDS are normalised rather than excluded.
capability_reason() { # $1 = path to .zbr; echoes a reason, or nothing
    local body
    body=$(cat "$1" 2>/dev/null)
    case "$body" in
        *Http.*|*Https.*|*Tcp.*|*Udp.*|*WebSocket*|*Ws.*|*".serve("*)
            printf '(network: contacts a remote host — outcome not ours to control)' ;;
        # SECOND MODALITY of the same rule, found 2026-07-30 by the A2 differential.
        # dir_walk_test counts the files under examples/ and reported 1900 vs 1901 — not
        # a mode difference at all, but a file added to the repo between the baseline and
        # the run. Three consecutive samples agree happily, because the filesystem is
        # stable across seconds and changes across hours. Enumerating the filesystem is
        # therefore external state, exactly like a remote host.
        *"Dir.walk("*|*"Dir.list("*|*listDir*|*"Dir.entries("*)
            printf '(filesystem enumeration: counts files that change as the repo does)' ;;
    esac
}

norm() { # collapse what varies between runs on the same machine
    # DURATIONS are normalised deliberately. A profiler reporting "0.008 ms" vs "0.010 ms"
    # is not a behaviour change and can never be asserted on — what is testable is the
    # STRUCTURE of the report (which functions, how many calls), which survives this. The
    # first baseline missed profile_attr_test because both of its two runs happened to be
    # equally fast, and the very first real gate run then failed on it. Normalising the
    # value is the actual fix; more samples (below) only reduce the odds.
    sed -E 's#[A-Za-z]:[\\/][^ ")]*#<PATH>#g
            s#0x[0-9a-fA-F]{6,}#<ADDR>#g
            s#[0-9]+\.[0-9]+ *(ms|us|µs|ns)\b#<TIME> \1#g
            s#[0-9]+ *(ms|us|µs|ns)\b#<TIME> \1#g'
}

mapfile -t NAMES < <(grep -vE '^\s*(#|$)' "$CANDIDATES" | sort -u)
[ -n "$ONLY" ] && mapfile -t NAMES < <(printf '%s\n' "${NAMES[@]}" | grep -F "$ONLY")
[ "${#NAMES[@]}" -gt 0 ] || { echo "no candidates matched" >&2; exit 2; }

echo "── output sweep (${#NAMES[@]} candidates) ──"
[ "$UPDATE" = 1 ] && echo "   baselining: each file runs 3x; any difference = auto-excluded"

: > "$OUT/manifest.txt"; : > "$OUT/excluded.txt"; : > "$OUT/diffs.txt"
n_ok=0; n_excl=0; n_diff=0; n_missing=0; n_empty=0; n_timeout=0; n_cap=0
CAP_SKIPPED=""

# At GATE time the derived exclusions must be honoured by NAME, before running anything.
# Without this they execute on every gate run, produce output that matches no baseline
# entry, and get reported as "new files" — five lines of misleading noise per run for
# files that were deliberately excluded, plus the wasted time. Noise is how a gate's
# output stops being read, which is the slow version of the failure this whole tier
# exists to prevent. (During --update-baseline the list is being REGENERATED, so it is
# deliberately not consulted.)
EXCLUDED_NAMES=""
if [ "$UPDATE" != 1 ] && [ -f "$EXCLUSIONS" ]; then
    EXCLUDED_NAMES=" $(grep -v '^#' "$EXCLUSIONS" | cut -f1 | tr '\n' ' ')"
fi
n_skipped=0

for name in "${NAMES[@]}"; do
    zbr="test/$name.zbr"
    [ -f "$zbr" ] || { n_missing=$((n_missing+1)); continue; }
    case "$EXCLUDED_NAMES" in
        *" $name "*) n_skipped=$((n_skipped+1)); continue ;;
    esac

    # Capability exclusion is checked BEFORE running: it needs no samples, and at gate
    # time it also saves actually making the network calls.
    cap=$(capability_reason "$zbr")
    if [ -n "$cap" ]; then
        n_cap=$((n_cap+1)); n_excl=$((n_excl+1))
        [ "$UPDATE" = 1 ] && printf '%s\t%s\n' "$name" "$cap" >> "$OUT/excluded.txt"
        # Remember it: a name newly excluded by CAPABILITY may still be present in an
        # older baseline, and the "vanished" check would then fail the gate for a file we
        # deliberately stopped measuring. Recording it is honest (it IS no longer
        # measured) without being a failure.
        CAP_SKIPPED="$CAP_SKIPPED $name"
        continue
    fi

    out1=$(run_one "$zbr" | norm)

    # A file that never terminates is excluded rather than baselined AS a timeout.
    # Recording "<<TIMEOUT>>" would assert only that it still hangs, cost TIMEOUT_SECS on
    # every gate run, and make the verdict sensitive to machine load — a flaky gate is a
    # gate people learn to ignore. These are the server/network fixtures (http, https,
    # server, ws_smoke); they need a harness that can drive and stop them, which is a
    # different tool from this one.
    if [ "$out1" = "<<TIMEOUT>>" ]; then
        n_timeout=$((n_timeout+1))
        [ "$UPDATE" = 1 ] && printf '%s\t(no output within %ss — never terminates)\n' \
            "$name" "$TIMEOUT_SECS" >> "$OUT/excluded.txt"
        n_excl=$((n_excl+1)); continue
    fi

    if [ "$UPDATE" = 1 ]; then
        # THREE samples, not two. Two was the original design and it demonstrably let a
        # flaky file through on the first attempt (profile_attr_test — two equally-fast
        # runs). A sampling filter is probabilistic by nature, so this reduces the escape
        # rate rather than eliminating it; the real defence is normalising the volatile
        # field, and an escapee shows up as a gate failure naming the file, which is a
        # recoverable outcome rather than a silent one.
        out2=$(run_one "$zbr" | norm)
        out3=$(run_one "$zbr" | norm)
        if [ "$out1" != "$out2" ] || [ "$out1" != "$out3" ]; then
            [ "$out1" = "$out2" ] && out2="$out3"
            # Derived exclusion. Record WHY, so the list is auditable rather than magic.
            reason=$(diff <(printf '%s' "$out1") <(printf '%s' "$out2") 2>/dev/null \
                     | grep -m1 -E '^[<>]' | cut -c1-100)
            [ -z "$reason" ] && reason="(differs, no line-level diff — length only)"
            printf '%s\t%s\n' "$name" "$reason" >> "$OUT/excluded.txt"
            n_excl=$((n_excl+1)); continue
        fi
    fi

    [ -z "$out1" ] && n_empty=$((n_empty+1))
    if [ "$SHOW" = 1 ]; then
        printf '── %s ──\n' "$name"
        printf '%s\n' "$out1" | head -6 | sed 's/^/    /'
    fi

    # Cap the stored text so the manifest stays reviewable, but hash the FULL output so a
    # change past the cap still fails the gate. Reviewable diff AND complete coverage.
    full_hash=$(printf '%s' "$out1" | sha1sum | cut -c1-12)
    {
        printf '=== %s sha1=%s ===\n' "$name" "$full_hash"
        printf '%s\n' "$out1" | head -"$PER_FILE_LINES"
        [ "$(printf '%s\n' "$out1" | wc -l)" -gt "$PER_FILE_LINES" ] \
            && printf '<<truncated at %s lines; sha1 above covers the whole output>>\n' "$PER_FILE_LINES"
    } >> "$OUT/manifest.txt"
    n_ok=$((n_ok+1))
done

if [ "$UPDATE" = 1 ]; then
    # Refuse to record a baseline that is mostly silence — see MAX_EMPTY_FRACTION_PCT.
    if [ "$n_ok" -gt 0 ]; then
        pct=$(( n_empty * 100 / n_ok ))
        if [ "$pct" -gt "$MAX_EMPTY_FRACTION_PCT" ]; then
            echo "REFUSING to write a baseline: $n_empty of $n_ok recorded outputs are EMPTY (${pct}%)." >&2
            echo "That is over the ${MAX_EMPTY_FRACTION_PCT}% threshold and almost certainly means output capture is" >&2
            echo "broken, not that the corpus prints nothing. A baseline of empty strings would" >&2
            echo "match forever and gate nothing. Inspect with: bash tools/output_sweep.sh --show --only <name>" >&2
            exit 2
        fi
    fi
    cp "$OUT/manifest.txt" "$BASELINE"
    sort -o "$OUT/excluded.txt" "$OUT/excluded.txt"
    {
        echo "# DERIVED by tools/output_sweep.sh --update-baseline — do not hand-edit."
        echo "# Files whose output differed between two consecutive runs, with the reason."
        echo "# Regenerated on every re-baseline, so it cannot silently rot."
        cat "$OUT/excluded.txt"
    } > "$EXCLUSIONS"
    echo "baseline updated: $n_ok files recorded -> tools/output_baseline.txt"
    echo "auto-excluded (nondeterministic): $n_excl -> tools/output_baseline_excluded.txt"
    echo "empty-output files: $n_empty of $n_ok (threshold ${MAX_EMPTY_FRACTION_PCT}%) · timeouts: $n_timeout"
    echo "excluded by CAPABILITY (network, cannot be sampled): $n_cap"
    [ "$n_missing" -gt 0 ] && echo "note: $n_missing baseline names had no test/*.zbr"
    exit 0
fi

if [ "$GATE" = 1 ]; then
    [ -f "$BASELINE" ] || {
        echo "no baseline — run: bash tools/output_sweep.sh --update-baseline" >&2; exit 2; }

    # Compare PER FILE, not by diffing the two manifests wholesale. A whole-manifest diff
    # fails every time a test is ADDED — which trains everyone to re-baseline reflexively
    # without reading the delta, and a gate that is always re-baselined is a gate that has
    # stopped being read. So the three cases are kept apart:
    #   changed  -> a real behaviour change. FAILS.
    #   vanished -> a baselined file no longer produces a record. FAILS (it stopped being
    #               measured, which is the vacuity failure this repo keeps rediscovering).
    #   new      -> informational only, never a failure.
    split_manifest() { # $1 = manifest, $2 = dest dir
        mkdir -p "$2"
        awk -v d="$2" '
            /^=== .* sha1=[0-9a-f]+ ===$/ { name=$2; f=d "/" name ".txt"; print > f; next }
            name != "" { print >> (d "/" name ".txt") }
        ' "$1"
    }
    split_manifest "$BASELINE" "$OUT/base"
    split_manifest "$OUT/manifest.txt" "$OUT/cur"

    changed=""; vanished=""; new=""; newly_unmeasured=""
    for f in "$OUT/base"/*.txt; do
        [ -e "$f" ] || continue
        b="$(basename "$f" .txt)"
        if [ ! -f "$OUT/cur/$b.txt" ]; then
            # With --only, the run is deliberately a subset; absence proves nothing.
            # A file skipped by CAPABILITY this run is not "vanished" — it is
            # deliberately no longer measured. Reported below, never a failure.
            case "$CAP_SKIPPED " in
                *" $b "*) newly_unmeasured="$newly_unmeasured $b" ;;
                *) [ -n "$ONLY" ] || vanished="$vanished $b" ;;
            esac
        elif ! cmp -s "$f" "$OUT/cur/$b.txt"; then
            changed="$changed $b"
        fi
    done
    for f in "$OUT/cur"/*.txt; do
        [ -e "$f" ] || continue
        b="$(basename "$f" .txt)"
        [ -f "$OUT/base/$b.txt" ] || new="$new $b"
    done

    [ -n "$new" ] && echo "· new files not in baseline (informational):$new"
    [ -n "$newly_unmeasured" ] && echo "· in baseline but now excluded by capability (re-baseline to drop):$newly_unmeasured"

    if [ -z "$changed" ] && [ -z "$vanished" ]; then
        echo "✓ output-sweep gate PASS — $n_ok files, behaviour identical to baseline" \
             "($n_skipped skipped as nondeterministic)"
        exit 0
    fi
    if [ -n "$vanished" ]; then
        echo "✗ output-sweep: baselined file(s) produced NO record — they stopped being" >&2
        echo "  measured, which is worse than failing:$vanished" >&2
    fi
    if [ -n "$changed" ]; then
        echo "✗ output-sweep: BEHAVIOUR CHANGED in:$changed" >&2
        for b in $changed; do
            echo >&2; echo "── $b ──" >&2
            diff -u "$OUT/base/$b.txt" "$OUT/cur/$b.txt" 2>&1 | head -30 >&2
        done
    fi
    echo >&2
    echo "A diff here is a BEHAVIOUR CHANGE, not a doc chore. Read it before re-baselining:" >&2
    echo "if the new output is correct, --update-baseline locks it in; if not, it is a bug." >&2
    exit 1
fi

echo "$n_ok files ran; $n_missing missing. (pass --gate to compare, --update-baseline to record)"
