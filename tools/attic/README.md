<!-- doc-status: live -->
# tools/attic — finished one-shot migrations

Scripts here **did their job and will not be run again**. They are kept, not deleted,
because each is the executable record of a migration the corpus actually went through,
and reading one is the fastest way to understand why the code looks the way it does.

They live in a subdirectory for one reason: **`tools/` should list what you might reach
for.** With these mixed in, `ls tools/` is a history lesson rather than a menu, and every
scan (`hazard_lint`, a grep for prior art, a new session orienting itself) pays for them.

## What is here

| script | did | retired |
|---|---|---|
| `migrate_colon_syntax.py` | converted the corpus to the `:` type-annotation syntax | 2026-04-20 |
| `branch_to_if_is.py` | rewrote `branch` statements to `if … is …` where the arm count made it clearer | 2026-04-20 |
| `sweep_class_main.py` | moved `main` out of `class Program` into a bare `def main()` | 2026-05-05 |
| `book_deindent_main.py` | de-indented book code samples after the same change | 2026-05-05 |
| `sweep_implicit_try.py` | added explicit `?` at call sites when §28b made implicit propagation an error | 2026-07-02 |

## Retired with the bootstrap (2026-09-15, `docs/design/bootstrap_sunset.md` Step 2)

Not migrations -- instruments whose subject was the second compiler. Each compared the
selfhost against `zebra-bootstrap`, and a comparison with one side gone reports nothing.

| script | was | why it stopped meaning anything |
|---|---|---|
| `selfhost_divergence_check.sh` | the `selfhost-div` daily gate: both compilers read the compiler's own modules and must agree | the gated half ("the compiler refuses its own source") is round-trip Step 1; the informational half was the bootstrap's coverage decaying, which is now complete |
| `lint_interp_escape.py` | the `interp-escape` static gate: `${...}` plus `\"` in one string, which the bootstrap double-escaped (BUG-216) | the bootstrap no longer emits anything that ships |
| `diagnostic_parity.py` | which bootstrap diagnostics never reached the selfhost | no second diagnostic set to be behind |
| `triage_diagnostic_candidates.py` | ran a minimal program per parity candidate through BOTH compilers | same |
| `scaling_probe.py` | selfhost vs bootstrap compile time against program size | the selfhost-only half is `--jobs`-shaped timing anyone can take with `time`; keep here as the last record of the two curves |

## Criteria for moving something here

All four, checked rather than assumed:

1. it is a **one-shot** migration or spike, not a tool you would run again;
2. **nothing references it** — no script, no build file, no *live* document (a mention in
   `docs/SCRIPTING_TOOLS.md`, the catalogue, is expected and gets its path updated);
3. it has not been touched in **at least a month**;
4. moving it breaks nothing — `doc_lint` D1 will tell you immediately if a document still
   points at the old path, which is how the references above were found and fixed.

Things that look retired and are **not**: `pub_mark_preamble.py` and `rtsplit_spike.py`
(both cited by `docs/runtime_module_design.md`, and one by `NEXT_STEPS.md`). Recency and
a live citation both outrank a retired-sounding name.
