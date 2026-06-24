# Stdlib API freeze-regret audit

*Drafted 2026-06-24, ahead of the 1.0 API freeze. The freeze rule is "add but
never remove," so every wart locked here is permanent. This audit flags the
stdlib surfaces most likely to cause regret, tiered by urgency, with a concrete
recommendation each. **These are recommendations for Sean to ratify — none are
applied yet** (they touch the about-to-be-frozen surface, which is his call).*

Scope note: the **language** surface is in good shape — the `concept_zebra-
language-warts` audit's open items (visibility, compound-assign, `def name:T`,
for-destructuring) all shipped in the 0.13/1.0 windows; only `^T` friction remains
as accepted permanent "managed friction." The risk that remains is in the
**stdlib API**, which that audit never covered. Surface examined: QUICKSTART §31
+ the `selfhost/stdlib_preamble.zig` implementations.

---

## Tier 1 — Fix before freeze (genuine regret if locked)

### A1. Two types for "list of strings": `[]str` vs `List(str)`
**Finding (verified in preamble).** `Net.resolve`, `re.findAll`, `re.groups`
return `[]const []const u8` (a raw Zig slice, surfaced as `[]str`), while
`File.readLines`, `File.listDir`, `sys.args` return `List(str)`. These are
*different types with different APIs*: `[]str` uses `.len` / `[i]`; `List(str)`
uses `.count()` / `.at(i)`. A user cannot write one helper that consumes "a list
of strings" from both. It also re-exposes the raw-slice indexing path that
BUG-141 just had to special-case for `List`.
**Why it's regret:** the split is arbitrary (same concept, two shapes) and
freezing it forces every downstream user to branch on which stdlib call produced
the value, forever.
**Recommendation:** unify on `List(str)` (the owned, idiomatic collection) for
*every* stdlib call that returns a string sequence. This is the single
highest-value pre-freeze fix. (Moderate compiler change: the three call sites'
return-type + codegen; verify against smoke + corpus.)
**STATUS: DONE (2026-06-24).** The three now return `List(str)`. Verified on both
compilers + gate + smoke. Note: `Reflect.fieldNames`/`fieldTypes` also return
`[]str` and were *not* swept (out of the ratified A1 scope) — a small remaining
inconsistency to consider before freeze if reflection is meant to be 1.0-stable.

### A2. Sentinel returns where an optional is correct
**Findings.** `File.modtime(path) → int` returns **`-1` on a missing file**;
`Mime.lookup(name) → str` returns **`""`** on an unknown extension; `Csv` field
access (`t.row(i).field(name)) → str`) returns **`""`** on a missing column.
**Why it's regret:** sentinels are the canonical frozen-API trap — callers
hard-code `== -1` / `== ""` checks, so you can never migrate to `?` without
breaking them. Zebra already has first-class optionals and leads with them
elsewhere (`sys.getenv → str?`, `Uri.parse → UriResult?`).
**Recommendation:** change these to `int?` / `str?` *before* freeze. They are
the inconsistent outliers in an otherwise optional-first stdlib.

### A3. `Random` is process-global mutable state
**Finding (verified).** `Random.seed/randInt/...` operate on a module-global
`var _rng_inst` + `_rng_ready` flag. **Not thread-safe** (a data race the moment
two `sys.go`/`ThreadPool` tasks draw numbers) and not isolatable (no way to seed
a local stream for a deterministic sub-computation without disturbing global
state).
**Why it's regret:** the global-only surface is a permanent thread-safety
footgun, and "seed affects everyone" is surprising. Channels/ThreadPool make
concurrency a first-class story, so a global PRNG is an odd island.
**Recommendation:** add an **instance** form now — `var rng = Random.new(seed)`;
`rng.int(lo, hi)` / `rng.float()` / `rng.bool()` / `rng.bytes(n)` — as the
primary API. Keep the `Random.*` statics as a convenience backed by a
**thread-local** instance (kills the data race without changing call sites).
Shipping the instance form pre-freeze means it's part of the stable surface;
retrofitting it later leaves the unsafe global as the "obvious" choice forever.

---

## Tier 2 — Decide + document before freeze (convention locks)

### B1. Parser error-handling is inconsistent
`Json.parse → JsonValue?` and `Uri.parse → UriResult?` are optional, but
`Csv.parse → CsvTable` is non-optional (throws? never fails?). Pick one parser
convention (recommend: all parsers return optional, malformed → `nil`) and apply
it uniformly so users learn one rule.

### B2. Connection/IO optionals discard the failure reason
`Http.get → HttpResponse?`, `Tcp.connect → TcpConn?`, `Ws.connect → WsConn?` all
collapse DNS failure / connection-refused / timeout / TLS error to a single
`nil`. If a reason is ever wanted, it requires `throws` or `Result(T,E)` — a
return-type change. **Decide now:** accept reason-less `?` for 1.0 (fine for many
uses; `r.status` still carries HTTP status), but document the intent, and
consider reserving a `*Try`/`throws` variant name so the richer form is additive
later rather than a rename.

### B3. Surprising-but-defensible semantics to lock loudly
- `Random.randInt(lo, hi)` is **inclusive** `[lo, hi]` (matches Python `randint`;
  surprises those expecting half-open). Document prominently.
- `Atomic.add/sub` return the **old** value (fetch-and-add). Footgun for those
  expecting the new value. Document; consider `addFetch`/`fetchAdd` naming clarity.

### B4. `File.listDir` vs `Dir.*`
Directory *listing* lives on `File` (`File.listDir`) while create/delete/exists
live on `Dir`. Mildly incoherent and frozen forever. **Recommendation:** add a
`Dir.list` alias now (keep `File.listDir` working).

---

## Tier 3 — Safe to freeze as-is (improvements are additive, not breaking)

- **`str` is always owned (no `str_view`/borrowed slice).** Flagged elsewhere as
  the biggest structural string gap, but adding `str_view` at 1.5 is purely
  additive — owned `str` can freeze. Caveat to record: zero-copy parsing APIs
  (HTTP headers, CSV/JSON tokenizing) will need *new* overloads, not changes to
  existing ones.
- **`List(byte)` for binary** (`Random.bytes`, `Compress.gzip/gunzip`): heavyweight
  but workable; a dedicated `Bytes` type is additive later.
- **`Atomic` supports only `int`/`bool`:** more types are additive.
- **Module naming convention** — `Csv`/`Json`/`Http`/`Uri`/`Mime`/`Ws`/`Tcp`/`Udp`
  use Title-case-initialism (not all-caps). This is **consistent and good** — lock
  it explicitly as the naming rule so future modules follow it.

---

## Meta-recommendation

Before flipping the freeze switch, do one **consistency sweep** with two themes:
1. **Container return types** — unify string-sequence returns on `List(str)` (A1).
2. **Absence representation** — optionals over sentinels everywhere (A2).

Those two cover the bulk of the "would be embarrassing in 1.0" surface. The rest
of Tier 2 is decisions to write down; Tier 3 is genuinely fine to lock. None of
the language-level features need rework — the regret risk is concentrated in a
handful of stdlib signatures, which is a good place to be on the eve of 1.0.
