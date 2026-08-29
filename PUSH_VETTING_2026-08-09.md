# Push vetting — 2026-08-09 (Fable, overnight)

**This file is UNTRACKED on purpose.** It will not be pushed. Delete it when done.
Nothing was pushed anywhere tonight; nothing was modified to "fix" the items below
— they are for your decision, because the clean fixes rewrite unpushed history and
that's your call, not mine.

## TL;DR — this is now a MULTI-REPO report; read the per-repo files too

Correcting my own first draft, which said "only zebra-language can be pushed, so
all vetting is about this repo." That was true about *mechanism* (the others have
no remote) and wrong about *risk*: you said this session the Graze app "could be in
a Mosaic github project with the content," so **graze and mosaic are named publish
targets** and I vetted them properly. "No remote yet" is the state on the eve of
adding one — not a reason to skip the repo carrying the most sensitive content.

| repo | remote? | verdict | the item that matters |
|---|---|---|---|
| **mosaic** | none yet | **REVIEW before public** | `data/raw/` = **190 MB / 971 third-party corpora → LICENSING** (DSS/CUC/Ge'ez/Brenton). See `C:/Projects/mosaic/PUSH_VETTING_2026-08-09.md` |
| **graze** | none yet | clean (2 "your call" items) | screenshots + an elthgar.com note I added. See `C:/Projects/graze/PUSH_VETTING_2026-08-09.md` |
| **zebra-sprocket** | none yet | see below (not separately scanned; small) | interim FTS5 patch; private toolchain vendored |
| **zebra-language** | `torial/zebra-language` | **the one with a remote** — details below | tracked `.claude/` config + pervasive `C:/Users/Sean` paths |

**The single sharpest finding across all repos** is not personal content at all:
mosaic ships **190 MB of third-party textual corpora** whose licenses may forbid
redistribution. That's a legal review, and it's in the repo you're most likely to
publish first. Read the mosaic report.

- **My one commit tonight in zebra-language (`208a7e6`, NEXT_STEPS) is clean** — no
  personal content in its diff (only the author line, which is your git config).
- **The personal content is pre-existing**, spread across the **45 unpushed
  commits**. It is baked into history, so removing it from the working tree does
  **not** keep it private on a push — see "The history problem" below.
- **The decision that changes everything: is `torial/zebra-language` going to be
  PUBLIC or PRIVATE?** If private (your own account), almost all of this is fine —
  your name in your own repo is expected. If public, it needs cleanup first.

## Findings, by severity (assuming a PUBLIC push)

### CRITICAL — should not be public regardless
- **`.claude/settings.local.json` is tracked** (39 lines, contains `/c/Users/Sean`
  paths and your local Claude Code permission allow-list). This is machine-local
  config; it does not belong in any shared repo. Fix: gitignore `.claude/` and
  `git rm --cached` it.

### HIGH — username leak, pervasive
- **`C:/Users/Sean` / `/c/Users/Sean` is hardcoded in ~30 files**, almost the whole
  `tools/` directory (`gates.sh`, `doctor.sh`, `compile_check.sh`, `rebuild.sh`,
  `mutation_check.py`, `stdlib_sig_check.py`, … each once), plus `spike/build_spike.sh`
  and `QUICKSTART.md`. A public push exposes your username in path strings
  everywhere. Fix: parameterize (`$HOME`, a `ZEBRA_ROOT` env var, or relative
  paths). This is also just good hygiene — those scripts aren't portable as-is.
- **`docs/emit_compile_triage_errors_2026-07-16.txt`** — a raw triage dump, dozens
  of `C:\Users\Sean\AppData\Local\Temp\...` paths. Probably shouldn't be in the
  repo at all (working artifact). Siblings: `boundary_triage.md`,
  `emit_compile_triage.md/.pdf`, `full_sweep_triage.md` — your call whether these
  belong in a shipped repo.

### REVIEW — your call, not clearly wrong
- **262 `Sean` references.** Most are legitimate design-decision attributions in
  `BUGS.md` / `NEXT_STEPS.md` ("Sean's decision, 2026-08-04: …") — fine for an
  open project, arguably good provenance. A few are personal-machine anecdotes,
  e.g. `BUGS.md:893` "while Sean was freeing disk space; the machine had reached
  40 GB free". Harmless but personal-flavored.
- **Wiki path pointers** — `docs/JJ-Quickstart.md` and `QUICKSTART.md` reference
  `C:/Users/Sean/wiki/pages/...`. They point at your private wiki (dead links for
  anyone else); reveal structure, leak nothing sensitive.
- **No secrets found** — no API keys, tokens, private keys, or `.env` content. Good.

## The history problem (read before you push)

All of the above lives in the **45 commits that have never been pushed**. `git rm`
in a new commit removes a file *going forward* but leaves its content in the 45
historical commits — and those get pushed too on first push. To actually keep it
private on a public push you'd either:
  1. **Squash the 45 into a clean single (or few) commit(s)** before first push
     (simplest for a first publish), or
  2. **`git filter-repo`** to scrub paths/files across history (surgical, keeps
     granular history), or
  3. **Accept it** — correct if the repo is private, or if you don't mind your
     name/paths being public.

I did **not** do any of these — they rewrite history and that's your decision.

## Suggested path if going PUBLIC (not executed)

1. `echo '.claude/' >> .gitignore && git rm -r --cached .claude`
2. Parameterize the `C:/Users/Sean` paths in `tools/` and `spike/` (a `ZEBRA_ROOT`
   env var read at the top of each script is the least-churn fix).
3. Decide on the `docs/*triage*` dumps (remove or keep).
4. Squash-before-first-push (option 1) so none of the above is in public history.

If going **PRIVATE**: just do step 1 (the `.claude` config), the rest is optional.

— Fable
