# Decision: keep the bootstrap as the independent regen authority

**Status:** accepted (2026-07-22)
**Context:** raised after BUG-181 was resolved (the selfhost `zebra.exe` can now
self-compile `selfhost/main.zbr`), which reopened the single-file Phase 5/6 question:
should we make the selfhost the regeneration authority, or teach the bootstrap the
single-file mechanism, so we can ship the selfhost as one file?

---

## Decision

1. **Keep `zebra-bootstrap.exe` (the Zig-implemented `src/` compiler) as the regen
   authority**, emitting the committed `selfhost/*.zig` in **multi-file** mode, as today.
2. **Do NOT make the selfhost the sole regen authority.**
3. **Do NOT add the single-file mechanism to the bootstrap right now.**
4. **De-scope single-file Phase 5/6** (retiring the per-module `selfhost/*.zig`,
   flipping the selfhost's own build to single-file). Single-file remains a *shipped
   feature* (`--single-file`, default-off), verified on the real compiler by
   `tools/selfcompile_check.sh`, not the selfhost's mandatory self-build format.

## Why (the load-bearing reasoning)

**Single-file does not force the authority question.** The regen authority's job is
"produce a working `zebra.exe` from `selfhost/*.zbr`." The bootstrap already does that in
multi-file, and `--single-file` is default-off, so the bootstrap compiling the selfhost
source is independent of single-file. A multi-file-built `zebra.exe` is fully functional,
*including* its single-file capability. The only thing that forces the question is Phase 5's
cosmetic sub-goal of committing one file instead of nine — a modest cleanup (the measured
compile win was ~noise, see `single_file_emit_design.md` §3) that must not override a trust
decision.

**The independent bootstrap is the trusting-trust defense, and it just paid off.** An
implementation in a *different language* is immune to self-propagating codegen bugs and
serves as an independent witness to the selfhost's correctness. BUG-181 was exactly this: 8
selfhost codegen divergences that the bootstrap *masked in the committed files and made
detectable by divergence.* Those bugs affected user programs, not just self-compile.

**"Selfhost as sole authority" is the worst-of-both-worlds.** It is self-referential (a
selfhost codegen bug propagates into the committed artifact and survives future regens), and
it does **not** let us retire the bootstrap: recovering from a bad `selfhost/main.zig` commit
still needs an independent way to rebuild `zebra.exe`. So we would keep the bootstrap's
maintenance cost while throwing away its witness value. (The only real escape is replacing
the bootstrap seed with a *frozen released `zebra.exe` binary* à la Rust/Go — a much larger
change that moves the trust surface onto a binary blob; out of scope here.)

**Timing.** The independent witness is most valuable while codegen is churning and divergence
is likely — i.e. pre-1.0, now. Post-1.0, when the compiler is stable, the bootstrap becomes
freezeable and the calculus flips. This is the wrong moment to trade it away.

**Single-file's real value is already delivered.** F5 closed, one shared preamble, the
namespaced-module architecture, multi-module merge at parity — all shipped in Phases 1–4.
Phase 5/6 adds only "one file instead of nine," which is not worth spending trust capital
*or* adding permanent bootstrap dual-maintenance.

## Consequences

- The committed `selfhost/*.zig` stays multi-file, bootstrap-produced. The round-trip
  (`bootstrap_check.sh`) and divergence checks continue to work as-is.
- `--single-file` is a user-facing feature (default-off). `tools/selfcompile_check.sh`
  keeps the selfhost's self-compile working as a regression gate.
- The bootstrap continues to require dual-maintenance of *codegen features* (not single-file)
  to stay equivalent to the selfhost — this is the accepted cost of the witness, and the
  reason a periodic selfhost↔bootstrap **convergence sweep** is worthwhile (BUG-181 showed the
  vein is real).
- Optional, cheap, aligned: build a `zebra.exe` from the selfhost's own **single-file**
  self-emit and run the suite against the multi-file build; they must agree. This turns
  self-hosting into a *second independent build path* (a stability asset) without changing
  authority.

## Revisit when

- **Post-1.0 / codegen stabilizes** → consider freezing the bootstrap (or replacing it with a
  released-binary seed) and promoting the selfhost.
- **The 9-file review/build burden actually bites** in day-to-day work → then the single-artifact
  milestone earns its cost, and the *correct* way to get it is **bootstrap Phase 2** (Option A),
  because it preserves the independent witness for the single-file path too. Treat that as an
  aesthetic/ergonomic want to be named explicitly, not an engineering need.
