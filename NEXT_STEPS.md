<!-- doc-status: live -->
# Zebra — Next Steps

**This file is a map, not a queue.** It was a single 3,845-line document until
2026-08-29, which meant it could not do the job its own header claimed: CLAUDE.md
says *"read this before generating a new task list"*, and nobody reads 3,845 lines.
It also mixed three genuinely different questions, so "what are our principles?"
was answerable only by reading the whole thing.

**Update the file that matches the KIND of thing you are recording**, not the one
that matches the conversation you were having. The measurements that prompted this
split had been filed under the brainstorm that produced them rather than under what
they were, which is exactly how they became hard to find.

| file | answers | update it when |
|---|---|---|
| [docs/PRINCIPLES.md](docs/PRINCIPLES.md) | **how do we decide?** | a rule, gate, axis, tension or system-concept claim changes |
| [docs/archive/FINDINGS.md](docs/archive/FINDINGS.md) | **what do we already know?** | you measured something, so nobody re-derives it |
| [docs/NEXT_STEPS_to_0.9.md](docs/NEXT_STEPS_to_0.9.md) | **what is next before public release?** | work that gates 0.9 |
| [docs/NEXT_STEPS_to_1.0.md](docs/NEXT_STEPS_to_1.0.md) | **what is next before the freeze?** | work that gates 1.0 |
| [docs/NEXT_STEPS_post_1.0.md](docs/NEXT_STEPS_post_1.0.md) | **what is deliberately deferred?** | something is parked past 1.0 ON PURPOSE |

That last distinction carries weight: **parked-by-decision and stalled look
identical from outside**, and only one of them is a problem. The repo already marks
this for gates (`@boundary-pending` pins a known-broken probe; `pin_daily` marks a
gate red on purpose) and had no equivalent for work. Anything deferred should say
so, and say why, or the next reader tidies it into a backlog item.

> **Milestone cumulative semantics:** each milestone is *additive*. A feature
> labeled 0.14 lands at 0.14 and is then part of the **1.0 stability commitment**
> (1.0 = everything delivered 0.1 → 0.15, locked). Same rule for 2.0 (kernel
> track = 1.0 + the 2.0 additions). "What blocks 1.0" = everything labeled for any
> 0.x milestone not yet shipped + stable. Public release = **0.9** (ready-for-
> others, not-yet-1.0). Internally the same push is called "1.0"; the public tag
> carries the toolchain as a suffix, e.g. `0.9_zig0.16`, because a Zebra release is
> only meaningful against the Zig it was tested with (Sean, 2026-09-09).
> Authoritative version-by-version breakdown: `wiki/pages/projects/project_zebra.md`.

**Bug detail lives in `BUGS.md` / `BUGS_FIXED.md`; per-phase history in
`docs/SELFHOST_JOURNAL.md` and `CHANGELOG.md`; cross-project concepts in the wiki.**
