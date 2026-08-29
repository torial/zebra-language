<!-- doc-status: historical -->
# Zebra → 1.0: a clear-eyed roadmap  — ARCHIVED 2026-08-29

> **Archived, not deleted.** Its content was integrated on 2026-08-29 and its own
> framing pointer had gone false: it says "NEXT_STEPS.md remains the authoritative
> per-item queue", and NEXT_STEPS.md is now a router over five files.
>
> Where each part went:
> * the reframe ("not what is left to write, but what gates declaring the surface
>   stable") → the header of `NEXT_STEPS_to_1.0.md`
> * the honest risks → `docs/PRINCIPLES.md`
> * the post-1.0 deferral list (WASM/Http/Zig-builtins at 1.5, kernel + VCS at 2.0)
>   → `NEXT_STEPS_post_1.0.md`
> * real-world validation via the GameEngine → `NEXT_STEPS_post_1.0.md`, marked
>   **deferred by decision** rather than stalled (Sean, 2026-08-29: the engine work
>   is paused pending a personal-review pre-0.9 state and is the intended first
>   tire-kick after)
> * the API freeze → folded into §15, which already carried it
>
> **Two of its pre-flight items are now resolved and are NOT open questions:**
> BUG-139 is closed, and "bootstrap-vs-selfhost textual divergence — reconcile or
> declare a non-goal" is answered by the bootstrap being retired (see
> `NEXT_STEPS_to_0.9.md`, "FREEZE THE BOOTSTRAP"). Its BUG-221 blocker is also fixed,
> which is what makes its "one technical bug plus the freeze" conclusion land on
> just the freeze.
>
> Read it for the 2026-06-23 snapshot; do not act from it.

*Drafted 2026-06-23. A strategy view, not a feature list — `NEXT_STEPS.md`
remains the authoritative per-item queue.*

## The headline

**Zebra is feature-complete for 1.0.** The honest blocker is no longer "build
the remaining features" — it is "**lock down, validate, and prove** what already
exists." Reading `NEXT_STEPS.md` end-to-end, essentially every item on the 0.11
→ 1.0 checklist is `[x]`: generics, contracts, the full stdlib (Math/Json/
DateTime/CSV/Hash/Random/Arg/Terminal/Log/Uri/Compress/Mime/Timer/Regex/Http/
Tcp/Udp/Net/File/sys/Gui/Reflect/SIMD), self-hosting + byte-identical bootstrap
round-trip, source-mapped errors, type aliases + refinement types, WebSocket,
channels, the `allocate`/`<-` memory model, REPL, debugger/DAP, build system.

So the roadmap question is **not** "what's left to write" — it's "**what gates
declaring the surface stable**." That reframes the work from *milestones* to a
*freeze checklist* plus *one real-world validation*.

## Where 1.0 actually stands

| Pillar | State |
|---|---|
| Language features (generics, contracts, unions, optionals, interfaces/mixins, `^T`, tuples, refinement types) | ✅ shipped |
| Stdlib breadth | ✅ shipped (28+ modules) |
| Self-hosting | ✅ `zebra.exe` IS the selfhost binary (Phase 22); round-trip byte-identical |
| Error experience | ✅ **materially improved 2026-06** — carets for parse/undefined-name/type-mismatch; method/field-not-found humanized (no Zig leak); arg-count + forgot-parens warnings; precise spans |
| Toolchain (REPL, debugger, build system, `--target` flags) | ✅ shipped |
| **Real-world validation** | 🟡 **the open frontier** — see below |
| **API freeze + stability promise** | 🔲 not yet declared |
| **Docs reconciled to reality** | 🟡 QUICKSTART current; the book needs a verification pass |

## The actual gate to 1.0 (a definition of done)

These are the things that genuinely must be true before flipping the "1.0 stable"
switch — not new features, but commitments and proofs:

1. **API freeze + a written stability promise.** Declare the public surface
   (syntax + stdlib signatures) frozen; commit to no breaking changes without a
   2.0. The CHANGELOG already covers 0.1 → 1.0; this is the policy statement on
   top of it. *This is the single most important 1.0 act and it is currently
   undone.*

2. **Pre-flight cleanup of the known-deferred-but-1.0-relevant items:**
   - **Selfhost `_initIo` propagation gap** (`NEXT_STEPS.md` Open Bugs) — harmless
     today, but flagged "track for 1.0 pre-flight." Either fix (emit a propagating
     `_initIo` in `generateModuleWith`) or consciously sign off that no transitive
     dep does `_io` I/O.
   - **Bootstrap-vs-selfhost *textual* divergence (Issue B)** — functional
     equivalence is guaranteed by the A==B gate; byte-identical emit is optional.
     Decide explicitly: reconcile, or document as a permanent non-goal.
   - **Open-bug triage** — BUG-014 (regex per-quantifier lazy) is explicitly
     post-1.0; BUG-026 is deferred-unless-reproduced; BUG-139 (default cue-init
     params not filled at omitting call sites) is a real latent gap worth a
     decision. Confirm none are 1.0 blockers in writing.

3. **Doc reconciliation.** The book (`zebra-language-book`) was written
   aspirationally and may reference changed syntax/APIs; it needs a pass against
   the current compiler before it can back a 1.0 "learn Zebra" claim. QUICKSTART
   is current and can anchor that pass.

4. **Real-world validation — the GameEngine port.** This is the proof that Zebra
   is usable for a substantial real program, and it is where the *next genuinely
   important bugs live*. Status: the translator corpus is **1482/1581 (93.8%)
   front-end-clean**, but that metric only measures *compiles*, not *runs*. The
   honest next frontier is **runtime**: do real `monster_mayhem` scripts actually
   *behave* when ticked through the engine? Front-end completeness has hit its
   long-tail ceiling (the remaining ~99 are a 47-way grab-bag, not a leverage
   point); pushing runtime correctness is higher-value and surfaces gaps the
   front-end probe is structurally blind to.

## Recommended sequence

1. **Runtime validation pass** (highest value): get a handful of real game
   scripts running end-to-end through the engine's tick loop; treat each runtime
   gap as a prioritized bug. This both advances the actual goal (Nathaniel's game)
   and produces the real-world evidence a 1.0 claim needs.
2. **1.0 freeze checklist** (the items in "definition of done" §1–3): mechanical,
   bounded, mostly decisions + a doc pass.
3. **Book reconciliation** as a parallel doc track.
4. *Then* tag 1.0.

Everything else in `NEXT_STEPS.md` — WASM (1.5), Http server ergonomics (1.5),
Zig-builtin access (1.5), the kernel track (2.0), the VCS, the MVU IDE — is
explicitly post-1.0 and should stay there. Resist the temptation to pull any of
it forward; the 1.0 win is *stability + proof*, not *more surface*.

## Honest risks / open questions

- **"Done" is a judgment call, not a checklist outcome.** The features are there;
  whether the *quality bar* (error UX, doc accuracy, edge-case robustness) clears
  "recommend this to a stranger" is the subjective gate. The 2026-06 error-
  experience work moved this materially, but `concept_zebra-learner-readiness`
  still lists honest caveats worth re-auditing before the freeze.
- **The GameEngine is both the validation and a risk.** If runtime reveals deep
  engine-API or language gaps, those could be real 1.0 blockers. Better to find
  them now (runtime pass) than after a stability promise.
- **Single-maintainer stability promises are heavy.** Freezing the API is a
  commitment to *not* fix design warts later without a major bump. Worth a
  deliberate "are we happy with this surface forever?" review (the
  `concept_zebra-language-warts` audit is the input) before §1.
