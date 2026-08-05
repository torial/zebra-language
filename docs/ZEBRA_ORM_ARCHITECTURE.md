<!-- doc-status: design -->
# Tack — Zebra ORM Architecture Document

**Status:** Draft for review — **§0.5 added 2026-08-01 by Fable with local access to the sprocket fork; several sections corrected against shipped behaviour**
**Audience:** Claude (Opus/Sonnet) implementing the ORM; the Zebra language author
**Working name:** `Tack` (the harness layer between zebra and machine; final naming TBD)
**Companion documents:**
- `ZEBRA_WEB_ARCHITECTURE.md` — this document **resolves** its §4.6 (DB layer) and Open Question #5 (schema source of truth), and rides the same Strategy-B codegen pre-pass (its ADR-6).
- `SPROCKET_RETURNS_TABLE_SPEC.md` — sprocket engine enhancement this design depends on (see §8; degradation path if unimplemented in §8.4).
**Related repos:** `torial/zebra-language`, `torial/sprocket` (SQLite 3.53.3 fork with native stored procedures)

---

## 0.5 Implementation status — verified in the fork, 2026-08-01

*Added by a session with the sprocket repo actually checked out and building.
Where this section contradicts the body of the document, this section is right
and the body has been corrected inline.*

### P0 is DONE. The degradation path in §8.4 is moot.

Everything §8.1 lists as "required from the companion spec" is implemented and
shipped in `torial/sprocket` (fork of SQLite 3.53.3):

| Requirement | State |
|---|---|
| `RETURNS TABLE(...)`, single and multiple, ordered | done |
| body conformance enforced at `CREATE PROCEDURE` across all branches | done (rules R1–R5) |
| declared shape via standard column metadata on `prepare("CALL …")` | done — **with one caveat, below** |
| `PRAGMA proc_list` / `PRAGMA proc_info` introspection | done |
| result-set boundary API | done — `sqlite3_proc_next_resultset()` |

Regression: **0 errors out of 392,950** on `veryquick` (vanilla baseline
0/392,771).

### Caveat that changes §4: prepare only describes the FIRST set

`prepare("CALL p(...)")` reports **set 1 only** through
`sqlite3_column_count/_name/_decltype`. That is deliberate — it makes a CALL
look exactly like a SELECT to existing tooling — but it means the §4 pre-pass
**cannot** learn a multi-set proc's full contract from prepare metadata alone.

Use `PRAGMA proc_info(name)`, which returns
`(resultset_index, position, name, decltype)` with **set 0 = parameters** and
sets 1..n = the declared shapes. That single pragma gives the pre-pass the
whole signature — parameter arity *and* every result shape — in one query, so
§4 step 3 gets simpler for procs, not harder.

### CHANGED 2026-08-05: proc_info sets are SEGMENTS, not declared shapes

*Added by the fork session that made the change, so the pre-pass is not
surprised by it. Supersedes the caveat immediately above where they disagree.*

The paragraph above says `PRAGMA proc_info` returns sets `1..n` = **the declared
shapes**. That was true when written and is no longer. Nested result shapes
landed in the fork on 2026-08-04, and `resultset_index` now counts **segments** —
what `sqlite3_proc_next_resultset()` actually advances through. `proc_list.nresultsets`
counts segments too, so the two agree.

**For everything that does not nest, nothing changed** — a shape is one segment,
both numbers are what they always were, and existing pre-pass logic is correct.

**A shape that nests reports more sets than it has shapes.** A nested table's own
columns are the segment *following* its parent, in declaration order:

| resultset_index | position | name | decltype |
|---|---|---|---|
| 0 | 0 | `pid` | INTEGER |
| 1 | 0 | `id` | INTEGER |
| 1 | 1 | `title` | TEXT |
| 1 | 2 | `comments` | *(empty)* |
| 2 | 0 | `post_id` | INTEGER |
| 2 | 1 | `cid` | INTEGER |

**A nested column is the one with an EMPTY decltype** — unambiguous, because
`CREATE PROCEDURE` requires a type on every scalar column. Declaration order is
what links segment *N* back to the column it belongs to; there is no explicit
field for it.

This is what makes S4 generatable at all: before it, a nested table's columns
were not introspectable, so codegen had nothing to build a child accessor from.
The cost is that a pre-pass counting sets to learn shape arity will over-count on
a nested proc unless it skips segments whose parent column carried an empty
decltype.

**Relevant to S4's proc-author contract (§7):** the fork now *imposes* the child
ordering from the declared `KEY`, so the author no longer writes it and cannot
get it wrong. The debug key-monotonicity assertion in the stitcher is still
worth keeping as a transport check, but it is no longer guarding an author
convention — the convention became structural.

### The engine enforces in-order consumption; §5.3 understated it

§5.3 proposes that advancing set *k+1* before set *k* is exhausted should be a
loud runtime error. The engine is stronger than that: sets **cannot** bleed
together. `sqlite3_step()` returns `SQLITE_DONE` at the end of each declared
set and **keeps returning `SQLITE_DONE`** until the client explicitly calls
`sqlite3_proc_next_resultset()`. Skipping ahead is not possible; forgetting to
advance yields an empty set, never another set's rows.

Consumption pattern the stitcher (§6, S4) must use:

```c
while( sqlite3_step(p)==SQLITE_ROW ){ /* set 1 */ }
while( sqlite3_proc_next_resultset(p)==SQLITE_OK ){
  /* column metadata now describes the next set, which may be a different width */
  while( sqlite3_step(p)==SQLITE_ROW ){ ... }
}
```

**Link statically.** `sqlite3_proc_next_resultset()` is deliberately *not* in
the loadable-extension API table (`sqlite3_api_routines`) — appending a slot in
a fork claims the offset upstream will use for its next API, which would make
an extension built against upstream headers jump into the wrong function.
Reasoning is in the fork's `README-PROCS.md`. Tack links the amalgamation
directly (§4 already assumes this), so it is unaffected; a Tack engine layer
must never be built *as* a loadable extension.

### Measured behaviour that should shape the doctrine

- **A CALL is allocation-identical to the statements it replaces** — 6/15/30
  allocations for 2/5/10 result sets, in both directions. Procs are not a
  memory-overhead tier.
- **Timing overhead is ~0.2 µs per result set**, i.e. negligible in process.
- **Compiled-body caching is conditional.** Bodies are shared across prepares
  only when *self-contained*: non-TEMP, no AUTOINCREMENT tables, no triggers
  fired by body DML, no nested `CALL`. Anything else transparently falls back
  to the per-statement tier. Measured win when it applies: ~1.35× faster
  prepares on an eight-statement body, scaling with body size.
  **Consequence for ADR-T5:** "hot path → proc" only buys the cache if the
  proc is self-contained. A proc that calls another proc gets none of it. The
  pre-pass should lint for this and say so.

### The strongest argument for the proc tier is not performance

Measured against loose prepared statements in-process, procs win by very
little. The durable arguments are:

1. **Data-dependent control flow.** Any batching argument is weak, because
   pipelining supplies batching without procs. What pipelining *cannot* do is
   let request 3 depend on the result of request 2 — that requires a round
   trip unless the logic runs engine-side. `IF` / `WHILE` / `SELECT … INTO` /
   `RAISE(ABORT)` in a body are exactly the branches no transport can flatten.
2. **Atomicity across dependent steps.** Read-a-balance-then-branch-then-write
   is two round trips *with a race window between them*, or one CALL inside one
   statement-journal atom.
3. **A static, machine-readable contract** — which is the whole basis of §4.

ADR-T5's ordering should therefore read **atomic / multi-statement /
data-dependent → proc**, with "hot" demoted to fourth and qualified by the
self-containment rule above.

---

## 0. How to use this document (note to implementing Claude)

Same conventions as the web architecture doc: **DECIDED** items carry rationale in the ADRs and are not to be silently deviated from — surface conflicts with a counter-proposal instead. **OPEN** items are flagged with the phase that must resolve them. Zebra snippets are illustrative; `grammar.txt` and `QUICKSTART.md` in the language repo are authoritative for syntax. The target engine is **sprocket exclusively** — exploit SQLite-isms (RETURNING, upsert, json functions, FTS5) and sprocket-isms (CALL, streaming multi-result procs, compiled-body caching) freely; portability to other databases is a non-goal.

---

## 1. Goals, non-goals, and the EF autopsy

### 1.1 The diseases being designed against

Entity Framework's performance explosion was five compounding decisions, all downstream of one root: **the mapping is resolved at runtime.**

1. Runtime expression-tree → SQL translation per query shape (with a compilation cache that helps until it misses).
2. Snapshot change tracking by default — O(entities × properties) memory and diff CPU paid whether or not you write.
3. Lazy loading — N+1 as the *silent default* rather than a visible mistake.
4. "Any LINQ over any database" — lowest-common-denominator SQL plus surprise client-side evaluation.
5. Reflection-heavy materialization.

Tack's root counter-decision: **all mapping is resolved at compile time** by the Strategy-B pre-pass, validated against the real engine (§4), with exactly one database target. Each disease is cured structurally, not by discipline:

| EF disease | Tack structural cure |
|---|---|
| runtime SQL translation | all static SQL fixed at build time; prepared once, cached by static id |
| snapshot tracking | per-field dirty bitset compiled into setters (§3.3) — no snapshots exist |
| lazy loading | *unrepresentable*: loadedness is in the type system via projections (§3.2, §6) |
| LCD SQL / client eval | single engine; the criteria builder refuses anything it can't lower to SQL (§7) |
| reflection materialization | codegen positional column→field mapping into the request arena (§3.4) |

### 1.2 Goals

- **G1 — Three authoring tiers, one type system:** generated CRUD for the boring 70%; checked SQL for full-power SQL authors; a bounded criteria builder as the no-SQL-required tier and the dynamic-shape mechanism. Plus sprocket procs as equal-citizen typed functions.
- **G2 — Streaming by default.** Reads produce typed streams (iterators), never lists, unless explicitly made concrete (`.collect()`). Memory profile of a read: O(one row) or O(one parent + its children), independent of result-set size.
- **G3 — Build-time truth.** Every static SQL statement, every generated CRUD statement, every `CALL` binding is validated at build time against the actual sprocket engine. SQL errors are compile errors pointing at source.
- **G4 — Injection unrepresentable** across all tiers (bound parameters only; identifiers only from generated compile-time enums; no string-assembled SQL has a blessed path).
- **G5 — Predictable cost.** A developer can read any Tack call site and state the number of statements executed and their shape. No mechanism may execute a query the developer didn't visibly cause.
- **G6 — Frugality**, inherited from the web doc's G3: arena-transient entities, no identity map, no background flushing, bounded statement caches.

### 1.3 Non-goals

- **NG1 — Database portability.** Sprocket/SQLite only, forever. This is load-bearing (it enables §4).
- **NG2 — A general query expression language.** The criteria builder is deliberately bounded (§7); requests to grow it toward LINQ are to be refused and redirected to checked SQL. The refusal is the anti-EF discipline.
- **NG3 — Unit of work / identity map / entity lifecycle events.** Entities are plain arena-transient records. Transactions are explicit (§10).
- **NG4 — Dynamic SQL inside procs** (`EXECUTE IMMEDIATE` etc.). Also refused on the sprocket side — see the enhancement spec's non-goals. Dynamic shape belongs to the criteria builder (§7.4 doctrine).
- **NG5 — Language-grammar integration (V-style `orm` keyword).** Persistent classes are plain Zebra classes + contracts + a lightweight attribute, consumed by the pre-pass. Promotion into the language proper remains possible later, mirroring the web doc's ADR-6 posture.

---

## 2. Layer map

```
┌────────────────────────────────────────────────────────────────┐
│ Application code (.zbr)                                        │
│   persistent classes, checked-SQL functions, criteria sites,   │
│   proc-binding calls                                           │
├────────────────────────────────────────────────────────────────┤
│ T4  Stitch layer: N typed streams → 1 stream of                │
│     parent-with-children (strategy chosen per shape, §6)       │
├──────────────┬──────────────┬──────────────┬───────────────────┤
│ T3a Generated│ T3b Checked  │ T3c Criteria │ T3d Proc bindings │
│     CRUD     │     SQL fns  │     builder  │     (CALL, multi- │
│     (§5.1)   │     (§5.2)   │     (§7)     │      set streams) │
├──────────────┴──────────────┴──────────────┴───────────────────┤
│ T2  Statement layer: prepared-stmt caches (static id + LRU),   │
│     bind/step/column, streaming iterators, arena materializer  │
├────────────────────────────────────────────────────────────────┤
│ T1  Engine: sprocket via C ABI (WAL, one writer + read pool,   │
│     per web doc §4.6); build-time twin instance for validation │
└────────────────────────────────────────────────────────────────┘
```

All four T3 tiers produce the same thing — typed row streams — which is what lets T4 treat "one statement," "two statements," and "one multi-set CALL" as interchangeable stream sources (ADR-T4).

---

## 3. Core model

### 3.1 Persistent classes — DECIDED: plain classes + contracts + attribute

```zebra
# illustrative — align with grammar.txt
@table("posts")                       # name optional; snake_cased class name is default
class Post
    var id as int                     # 'id' is the default key; @key overrides
    var author_id as int  @fk(Author)
    var title as String
    var body as String
    var created_at as Timestamp = now()
    var likes as int = 0
    invariant title.length > 0 and title.length <= 200
```

- Contracts do quadruple duty (extends web doc ADR-5): server-side validation, HTML5 form attributes, WASM client validation, and — new here — **generated `CHECK` constraints** in DDL where the contract is expressible in SQL (length/range/enum checks). Inexpressible contracts remain Zebra-side only; the pre-pass reports which landed where.
- `@fk` declares the relation used by `include` (§6) and criteria relation-walks (§7.2). Relations are metadata, **not** navigable object properties — there is no `post.author` field that might be null-or-loaded. Loadedness lives in projections (§3.2).

### 3.2 Projections — DECIDED: distinct generated types per loaded shape

For each persistent class the pre-pass generates: the base record (all columns), and per-`include`/per-projection variants as distinct types — `Post.Summary(id, title)`, `Post.WithComments(post fields + comments as Stream<Comment>)`. "Which columns and relations did I actually fetch" is answered by the type, never by runtime null-checking. Checked-SQL functions returning partial columns get their own anonymous-but-named result records generated from statement metadata (§4).

### 3.3 Dirty-bitset writes — DECIDED (ADR-T2)

Codegen emits property setters that set a per-field bit in a small bitset carried by the entity (u64 covers 64 columns; wider tables get an array — and a build warning, on taste grounds).

```zebra
post = db.get(Post, 42)?
post.title = "Better title"        # sets bit 2
db.save(post)                      # → UPDATE posts SET title=? WHERE id=?   (dirty fields only)
db.save(post)                      # → no-op (bitset clear after successful save)
```

- Cost: a few bytes per entity, one OR per assignment, zero snapshots, zero diffing. This is a language-author capability EF never had — tracking compiled into the write, not reconstructed at save.
- Fresh (un-fetched) entities save via `db.insert(post)` (full column list, RETURNING id populates the key field). `save` on an entity with no key set is a compile-tier lint where detectable, else a runtime error — **OPEN #4**.
- The UPDATE statement for an arbitrary dirty subset is dynamic in shape; it flows through the same bounded assembly + LRU statement cache as the criteria builder (§7.3). Common cases (single-field updates) hit the cache permanently.
- Coexistence with proc mutations is a **non-problem by construction**: with no identity map, no in-memory entity is ever "tracked as current," so a proc mutating rows cannot create stale-tracking anomalies — entities are explicitly snapshots. (Stated here because it is the first question every EF veteran asks.)

### 3.4 Materialization — DECIDED: positional, arena, streaming

- Generated mapping is positional: column ordinal → field, fixed at build time from statement metadata. No name lookups, no reflection, no per-row allocation beyond the record itself.
- Rows materialize into the caller's arena (the request arena in web contexts, per web doc §3.1). Entity lifetime = arena lifetime; there is nothing to dispose.
- Text/blob columns: **OPEN #5** — copy into arena (safe, simple) vs borrow from SQLite's row buffer for the duration of the step (zero-copy but lifetime-fragile under streaming, where the consumer may hold a row across `next()`). Lean copy-into-arena for v1; measure before optimizing.

---

## 4. Build-time validation — DECIDED: the engine is the type checker (ADR-T1)

The pre-pass does **not** contain a SQL parser or type-inference engine. Instead, at build time it:

1. Spins up an in-memory **sprocket** instance (the twin — same amalgamation the app links).
2. Executes checked-in `schema.sql`, then `procs.sql`.
3. For every static statement in the program — generated CRUD, checked-SQL bodies, `CALL` bindings, criteria base queries — runs `sqlite3_prepare_v2()` and reads result column names/types and bind-parameter counts from statement metadata. **For procs, read `PRAGMA proc_info(name)` instead of the prepare metadata** — prepare describes only the first result set (see §0.5); `proc_info` returns parameters *and* every declared shape in one query.
4. Generates the typed Zebra functions/records from that metadata; any prepare failure is a **compile error** with the SQL, the engine's message, and the source location (source-mapped like ZTL, web doc §4.4).

Properties: syntax errors, missing columns/tables, arity mismatches, and proc signature/shape mismatches are all caught before the program exists; the checker can never drift from engine behavior because it *is* engine behavior; sprocket features (CALL, RETURNS TABLE metadata) are supported automatically the moment the engine supports them. This decision is load-bearing for the entire design and is enabled by NG1.

Type mapping note: SQLite's flexible typing meets Zebra's static typing via declared column type → Zebra type table (INTEGER→int, TEXT→String, REAL→float, BLOB→Bytes, plus NUMERIC/date-ish affinities → **OPEN #6**: Timestamp encoding convention — lean ISO-8601 TEXT, the SQLite idiom, with the criteria builder and generated DDL agreeing). `STRICT` tables are emitted by generated DDL and recommended in the schema style guide.

---

## 5. The authoring tiers

### 5.1 T3a — Generated CRUD

Per persistent class: `db.get(Post, id)`, `db.insert(post)`, `db.save(post)` (dirty-only), `db.delete(Post, id)`, `db.all(Post)` (streaming), plus per-`@fk` child accessors used by the stitcher. All SQL fixed at build time, validated per §4, cached by static id. Upsert: `db.insert(post, on_conflict=...)` lowering to SQLite's native `ON CONFLICT` — **OPEN #7** for exact surface.

### 5.2 T3b — Checked SQL

```zebra
@sql("""
    select p.id, p.title, count(c.id) as comment_count
    from posts p left join comments c on c.post_id = p.id
    where p.created_at > ?
    group by p.id
    order by p.created_at desc
""")
def recent_with_counts(since as Timestamp) as Stream<RecentPostRow>
```

- The pre-pass prepares the body against the twin, verifies bind arity against the signature, and generates `RecentPostRow` from result metadata (or verifies a user-declared record if the return type names one).
- This tier is the pressure-release valve for everything the other tiers refuse. It is a feature, not a fallback: full SQLite power (CTEs, window functions, FTS5, json) with compile-time checking.

### 5.3 T3d — Proc bindings (sprocket as equal citizen)

- Procs live in checked-in `procs.sql` (with tables' `schema.sql`), synced idempotently at startup (§9.2), and are **declared with `RETURNS TABLE`** per the companion sprocket spec.
- The pre-pass prepares `CALL proc(?, ...)` against the twin; from the declared shape(s) it generates a typed Zebra function. Single-result-set procs return `Stream<Row>`; multi-set procs return a generated struct of ordered streams:

```zebra
# generated from: CREATE PROCEDURE post_with_comments(pid INTEGER)
#   RETURNS TABLE(...post cols...) RETURNS TABLE(...comment cols...)
result = db.post_with_comments(42)
for p in result.set1 ...        # must be consumed in declared order
for c in result.set2 ...
```

- **In-order consumption is enforced:** advancing set *k+1* before set *k* is exhausted is a loud runtime error, never silent buffering (which would betray G2's memory model). The stitcher (§6) consumes multi-set procs correctly by construction, so this constraint only touches hand-consumers.
- `zweb db pull` (tooling): introspects the twin's procs (via the spec's `proc_info`) and reports/regenerates bindings — supports database-first workflows and drift detection.
- **Doctrine (ADR-T5): procs are for fixed-shape, multi-statement, atomic, or hot paths.** Procs must not attempt dynamic shape: the optional-parameter pattern (`WHERE ?1 IS NULL OR col = ?1`) is an anti-pattern *specifically under sprocket*, where compiled-body caching pins one plan for all parameter combinations and that plan generally cannot use the column index — it silently converts the caching feature into a full-scan generator. The pre-pass should lint this pattern in procs.sql and warn.

---

## 6. `include` and the stitch layer

**DECIDED (ADR-T4): `include` is a stream-stitching feature, not a query feature.** The stitcher consumes N typed streams and yields one stream of parent-with-children projections; stream *sources* are interchangeable. Codegen selects the strategy per shape:

| Strategy | When chosen | Statements | Memory | Notes |
|---|---|---|---|---|
| **S1 Join-flatten, group-adjacent** | single `include`, codegen owns the parent query | 1 | O(1 parent + its children) | pagination correct by construction: parent LIMIT applied in a subquery *before* the join |
| **S2 Ordered merge-join** | ≥2 sibling includes, or nested includes | k+1 concurrent prepared stmts, zipped | O(1 parent + its children) | the generalizing strategy; no cartesian explosion (the EF `AsSplitQuery` disease); correlated ordering guaranteed because codegen writes every query |
| **S3 JSON fold** (`json_group_array`) | parent source is opaque (hand-written checked SQL where ordering can't be imposed) | 1 | O(1 row) | compatibility strategy; children round-trip through JSON text; never the default |
| **S4 Multi-set proc** | proc declared with sequential parent/child result sets, ordered by correlation key | 1 `CALL` | O(1 parent + its children) | split-query pattern natively, atomically, one round trip, compiled cached body; feeds the same S2 zipper |

- Proc-author contract for S4 (documented convention): emit sets in declared order, each ordered by the correlation key. Debug builds add a cheap key-monotonicity assertion in the stitcher; violation is a clear error naming the proc.
- Every stitched result is a distinct projection type (§3.2): `Post.WithComments` etc. There is no mechanism by which iterating a collection triggers a query (lazy loading is unrepresentable — G5).
- `.collect()` on any stream (or any stitched stream) makes it concrete as an arena-allocated list; this is the *only* way to get a list, and it is always explicit (your G2/answer-4).

---

## 7. The criteria builder (T3c) — bounded by design

### 7.1 Dual role

(1) The dynamic-shape mechanism (user-driven filters/sorts); (2) the **no-SQL-required tier** for developers uncomfortable writing SQL — kept open deliberately even though the primary user is SQL-fluent.

### 7.2 Surface — DECIDED: this list is closed (ADR-T3)

- **Predicates** over generated per-table column enums (`Post.cols.title`): `eq ne lt le gt ge like in_ between is_null`, combined with `and or not`.
- **Relation-walks** along declared `@fk` only: `Post.where(Post.rel.author.name.eq(x))` — the join is generated from the FK declaration. Arbitrary joins are refused with an error message that names the checked-SQL tier.
- **order_by** (column enums + direction), **limit/offset**, **include** (feeding §6).
- Nothing else. Aggregates, group-by, subqueries, expressions-on-columns: refused → checked SQL. (NG2: the refusal is the discipline.)

```zebra
q = query(Post)
if filter.author_id.has_value: q = q.where(Post.cols.author_id.eq(filter.author_id))
if filter.text != "":          q = q.where(Post.cols.title.like("%{filter.text}%"))
posts = q.order_by(Post.cols.created_at, desc).limit(20).include(Post.rel.comments).run(db)
```

### 7.3 Why this is not the EF trap — and the cost model

- Injection is unrepresentable: identifiers come only from compile-time enums; values are always bound parameters (G4).
- EF's runtime cost was expression-tree *translation*; criteria assembly here is concatenation of pre-validated fragments — nanoseconds — followed by SQLite prepare (microseconds) on cache miss only. An LRU prepared-statement cache keyed by normalized criteria shape (bounded size, **OPEN #8** for default) means recurring shapes pay bind/step only. The dirty-bitset UPDATE assembler (§3.3) shares this exact machinery.
- The criteria base query (table + FK joins skeleton) is validated at build time against the twin; runtime assembly only composes fragments the build already proved individually preparable.

### 7.4 Division-of-labor doctrine — DECIDED (ADR-T5)

**Fixed-shape, multi-statement, atomic, or hot → proc. Dynamic-shape → criteria builder. Everything else → checked SQL. Boring per-row → generated CRUD.** Each tier refuses the others' jobs; the refusals keep all four fast. This doctrine goes in user-facing docs verbatim.

### 7.5 Deferred fusion — comptime variant enumeration

When a criteria site's filter set is statically knowable and small, the pre-pass may pre-generate the 2^n statement variants (build-checked, zero runtime assembly); for hot paths it may further emit variants as *generated procs* into procs.sql, buying compiled-body caching for machine-written SQL. Deferred beyond v1; the criteria API is its unchanged surface, so it can land later without touching application code.

---

## 8. Sprocket dependency and degradation path

### 8.1 Required from the companion spec

`RETURNS TABLE(...)` (single and multiple, ordered) on `CREATE PROCEDURE`, with (a) body-conformance enforcement at proc-compile time across all branches, (b) declared shape exposed through standard column metadata on `prepare("CALL ...")`, (c) `proc_info` introspection.

### 8.2 What it buys

`CALL` becomes exactly as statically knowable as a prepared statement → §4 handles procs with zero special cases → "equal citizen" is literal. Branch-divergent result shapes become engine-side errors at `CREATE PROCEDURE` time — impossible to ship.

### 8.3 Sequencing — **RESOLVED: P0 shipped 2026-08-01**

No longer a prerequisite to plan around. See §0.5. Tack P4 can be scheduled on
its own merits.

### 8.4 Degradation path — **retired**

Kept only as history: the fallback was Zebra-side `@returns(RowType)` checked at
startup. It is unnecessary; do not implement it.

---

## 9. Schema direction and migrations

### 9.1 Direction of truth — DECIDED: both directions, one canonical artifact

Per your answer #3, both workflows are supported; they meet at **checked-in `schema.sql` + `procs.sql` as the canonical artifacts** (what the twin loads, §4):

- **Schema-first:** author `schema.sql` by hand; `db pull` generates/refreshes persistent-class skeletons (contracts added by hand thereafter; the generator never overwrites a class that exists — it diffs and reports).
- **Class-first:** author classes; `db push --dry-run` generates DDL (including contract-derived CHECKs, STRICT tables) and a migration diff against current `schema.sql`; accepting it rewrites `schema.sql` + appends a migration.
- Drift detection both ways is a build step: classes ⇄ schema.sql mismatches are build errors with a fix-it direction.

### 9.2 Migrations & proc sync

- Tables: ordered `migrations/*.sql`, applied at startup, tracked in `_migrations` (unchanged from web doc §4.6). Build-time verification: twin replays migrations from empty and diffs the result against `schema.sql` — **this resolves web-doc Open Question #5** (source of truth = schema.sql, verified by migration replay).
- Procs are code, not migrations: at startup, each proc in `procs.sql` whose body hash differs from the installed version is re-created (`DROP`+`CREATE` in a transaction). Hash tracking in `_procs`. No numbered proc migrations — the file is the truth, like source code.

---

## 10. Transactions & concurrency

- Explicit only: `db.tx(fn)` — closure runs in `BEGIN IMMEDIATE`…`COMMIT`, rollback on error propagation. No ambient/implicit transactions; `save`/`insert` outside a tx autocommit (SQLite semantics, documented).
- Connection topology inherited from web doc §4.6: one writer behind a mutex, small read pool, WAL. Streams hold a read connection while open — **documented sharp edge:** a long-lived unconsumed stream pins a pool connection; `db.tx` + open streams from *other* connections is fine under WAL. Debug builds warn on streams held open > N seconds (**OPEN #9** for N and mechanism).
- `busy_timeout` set by default; retry-on-SQLITE_BUSY policy for `db.tx` — **OPEN #10**.

---

## 11. Implementation phases

**P0 — Sprocket `RETURNS TABLE`** — ✅ **DONE 2026-08-01.**
*Exit met:* `proc4.test` 47/47; full `veryquick` 0 errors out of 392,950. Also
shipped beyond spec: `sqlite3_proc_next_resultset()`, per-connection
compiled-body cache, `PRAGMA proc_list`/`proc_info`.

**P1 — Statement layer + twin validation (T2 + §4).** C-ABI bindings against sprocket, prepared-stmt caches, streaming iterators, arena materializer, build-time twin bootstrap (schema.sql load + prepare-and-extract-metadata for a hardcoded statement list).
*Exit:* a hand-declared checked-SQL function round-trips: build fails on bad SQL with a pointed error; good SQL yields a typed stream; memory flat while streaming 1M rows.

**P2 — Persistent classes + CRUD + dirty bitset (T3a, §3).** Attribute parsing in the pre-pass, class↔schema drift check, generated CRUD, bitset setters, dirty-subset UPDATE via the LRU assembler, RETURNING-populated inserts, contract→CHECK DDL generation.
*Exit:* guestbook (from web-doc Phase 2) ported to Tack; `save` after single-field edit issues a single-column UPDATE (assert via sqlite trace); unmodified `save` issues nothing.

**P3 — Checked SQL tier + migrations/proc-sync + `db pull/push` (T3b, §9).**
*Exit:* migration replay-and-diff verifies schema.sql in CI; both direction-of-truth workflows demonstrated on the guestbook; a deliberately-broken query in `@sql` fails the build pointing at the .zbr line.

**P4 — Proc bindings (T3d, §5.3; needs P0).** `CALL` prepare-based binding generation, multi-set stream structs with in-order enforcement, startup proc hash-sync, optional-parameter-pattern lint.
*Exit:* the README's `archive_user` proc callable as a typed streaming function; out-of-order multi-set consumption errors loudly; editing a proc body and restarting hot-swaps it.

**P5 — Stitch layer + `include` (T4, §6).** S1 and S2 first (S1 single-include default, S2 for siblings), projection type generation, debug monotonicity assertions; S4 wiring (procs into the S2 zipper); S3 last.
*Exit:* `include` of two sibling collections on a paginated parent query produces correct results with 3 statements (S2), constant memory, and correct parent-count pagination; same shape via a multi-set proc (S4) produces identical results in 1 CALL.

**P6 — Criteria builder (T3c, §7).** Column/relation enum generation, closed predicate surface, normalized-shape LRU cache, refusal errors that name the right tier.
*Exit:* the dynamic-filter demo from §7.2 runs; attempting an aggregate produces the redirect error; repeated shapes show zero prepares after warmup (trace-verified).

**Deferred beyond v1:** comptime variant enumeration + generated-proc fusion (§7.5), borrow-not-copy text materialization (§3.4), FTS5/json criteria extensions (via checked SQL meanwhile), savepoint-based nested tx.

---

## 12. Architecture Decision Records

**ADR-T1 — The engine is the type checker.**
*Decision:* Build-time validation = prepare every statement against an in-memory twin sprocket loaded with schema.sql/procs.sql; generate types from statement metadata. No SQL parser in the toolchain.
*Rationale:* Zero drift by construction; sprocket features inherited automatically; the hardest components of sqlc/EF (SQL front-ends) are deleted from the design. Enabled by single-engine commitment (NG1).
*Risks:* build needs the sprocket amalgamation compiled for host (already true of the app build); prepare-time checking validates shape, not semantics (a wrong-but-well-typed query still needs tests — accepted).

**ADR-T2 — Dirty-bitset writes; no snapshots, no identity map.**
*Decision:* Setters compiled with per-field dirty bits; `save` updates dirty subset; entities are arena-transient snapshots.
*Rationale:* EF's most-loved ergonomic at ~zero cost, achievable only because codegen owns the setters; identity-map deletion makes proc-mutation staleness a non-problem by construction.
*Risks:* wide tables need bitset arrays (warned); field mutation through references bypassing setters would miss bits — pre-pass must ensure persistent-class fields are setter-mediated (verify against language semantics in P2).

**ADR-T3 — Criteria surface is closed.**
*Decision:* Predicates + FK relation-walks + order/limit/include. Everything else refused with a redirect to checked SQL.
*Rationale:* The builder's two jobs (dynamic shape; no-SQL tier) need exactly this much; growth toward LINQ is the documented root of the EF disease (§1.1 #1, #4). Fragment assembly over pre-validated pieces + shape-keyed LRU keeps runtime cost in nanoseconds-to-microseconds.
*Risks:* pressure to extend will be constant, including from future implementing-Claude sessions (mitigate: NG2 states the refusal is the point; extensions require amending this ADR with a cost analysis).

**ADR-T4 — `include` is stream stitching over interchangeable sources.**
*Decision:* One stitcher (group-adjacent / k-way ordered zip) fed by any of: single join statement (S1), multiple statements (S2), JSON fold (S3), multi-set proc (S4). Strategy chosen by codegen per shape; results are distinct projection types; lazy loading does not exist.
*Rationale:* Unifies the SQL and proc worlds instead of special-casing procs; S2 kills cartesian explosion; S4 turns sprocket's multi-set streaming into a native split-query with one round trip and a compiled cached body; correctness preconditions (correlated ordering) are guaranteed because codegen writes the SQL and the proc convention is assertion-checked in debug.
*Risks:* stitcher is the subtlest runtime code in Tack (mitigate: property-based tests zipping randomized ordered streams; it is pure logic, ideal for exhaustive testing).

**ADR-T5 — Division-of-labor doctrine; procs refuse dynamic shape.**
*Amended 2026-08-01 (§0.5): reorder the proc criteria to* **atomic /
multi-statement / data-dependent → proc**, *with "hot" fourth and conditional.
Measurement showed a CALL is allocation-identical to the statements it replaces
and ~0.2 µs/result-set slower in process, so "hot" is the weakest criterion;
and compiled-body caching only applies to* self-contained *bodies (non-TEMP, no
AUTOINCREMENT, no body-DML triggers, no nested CALL), so a proc that calls
another proc gets none of it. The strong criteria are engine-side branching and
atomicity across dependent steps — the things no transport or pipeline can
flatten.*
*Decision:* Fixed-shape/multi-statement/atomic/hot → procs; dynamic shape → criteria; full-power SQL → checked tier; boring CRUD → generated. Optional-parameter pattern linted in procs; `EXECUTE IMMEDIATE` refused engine-side (companion spec).
*Rationale:* Sprocket's compiled-body caching pins one plan per proc — dynamic-shape idioms convert the cache into a full-scan generator; dynamic SQL in PSM reintroduces the injection and shape-opacity the architecture exists to eliminate. Clean refusals keep every tier's performance story simple enough to state in one sentence (G5).
*Risks:* four tiers to teach (mitigate: the doctrine is one paragraph, and the error messages do the teaching by redirecting).

---

## 13. Open questions

1. **Naming** — Tack? (Before public docs.)
2. **Attribute syntax** — `@table`/`@fk`/`@sql` forms must match real language attribute grammar. (P2 start.)
3. **Stream API surface** — Zebra iterator protocol details; `.collect()`, `.first()`, `.map` availability. (P1.)
4. **`save` without key** — compile lint vs runtime error. (P2.)
5. **Text/blob materialization** — copy vs borrow. (P1 decides copy; revisit with measurements.)
6. **Timestamp convention** — ISO-8601 TEXT vs INTEGER epoch; must agree across DDL gen, criteria, and Zebra `Timestamp`. (P2.)
7. **Upsert surface.** (P2.)
8. **LRU statement-cache sizing** and eviction policy. (P6, defaults measured.)
9. **Held-open-stream warning** threshold/mechanism. (P1.)
10. **SQLITE_BUSY retry policy** for `db.tx`. (P2.)
11. **`db pull` class-skeleton merge strategy** when a class already exists (diff-and-report chosen; exact report format TBD). (P3.)

---

## 14. Extension roadmap — how sprocket's own docket feeds Tack

*Added 2026-08-01. The fork keeps a ranked docket (`DOCKET.md` in the sprocket
repo). Each item below is written from Tack's side: what it would change here,
so the two roadmaps are planned together rather than colliding.*

### 14.1 Procedure authorization — **Tack should block on this**

The fork has no authorizer action code for `CALL`; body statements authorize
under the procedure's context, trigger-style. Harmless for an embedded library,
but Tack's §5.3 makes procs a first-class application surface and the web doc
puts them behind HTTP. **The proc boundary becomes the security boundary, and
it is currently unguarded.**

What Tack gains when it lands: an `@authz` attribute on proc bindings, and a
build-time check that every proc reachable from a route has one. The open
engine-side question — definer's vs invoker's rights — is a Tack question too,
because it decides whether a proc can be a privilege boundary at all. Track it.

### 14.2 Typed client generation — **this is §4, generalized; do not build it twice**

The docket's "typed client generation" (emit C/TS/Python stubs from
`proc_info`) and Tack's §4 pre-pass are *the same mechanism* pointed at
different languages. Tack is the Zebra instantiation.

Recommendation: keep the introspection contract (`PRAGMA proc_info`) as the
single shared interface, and let Tack's generator be the reference
implementation. If the sqlite side ships a `.procgen` shell command first, Tack
should consume the same metadata rather than re-deriving it — and the
determinism requirement (byte-identical output for an unchanged schema) belongs
in both.

### 14.3 Incremental view maintenance — **a fifth stitch strategy, and a new projection kind**

Materialized views maintained as writes land. For Tack this is not a query
feature but a **new projection source**: `Post.CommentCounts` becomes a real
table the engine keeps current, so §6's stitcher gets **S5 — read a maintained
projection**, with O(1) statements and no join at all.

It also completes the architecture the fork's `DESIGN-NETWORK.md` recommends
(append-only ledger + rollups), which currently requires hand-written triggers
per schema — exactly the boilerplate Tack exists to delete. Correctness is
beautifully testable: the view must equal its from-scratch recomputation after
any write sequence, which is a property test, not a unit test.

### 14.4 Temporal tables (`AS OF`) — **projections already have the right shape**

System-versioned rows would slot into §3.2 with no new concepts: `Post.AsOf(t)`
is just another generated projection type, and "which version am I holding" is
answered by the type rather than by runtime checks — the same move §3.2 already
makes for loadedness. Cheap to adopt *because* §3.2 exists.

### 14.5 Shard routing — **the one item that disturbs §10**

If the engine grows a fan-out shard virtual table, Tack's connection topology
(one writer + read pool) becomes per-shard, and the criteria builder needs a
shard-key concept so a query can be routed rather than fanned. This is the item
most likely to force a Tack redesign, so it is worth knowing early whether it
is on the road.

### 14.6 The wire protocol — **the strongest synergy, and a new idea**

The fork now has a working codec and TCP transport where **the request is a
CALL** (`PLAN-TRANSPORT.md`; phases 1–4 done). Its differentiating feature: a
client that already knows a procedure's result shape can present the schema
cookie and receive responses with **no schema frames at all** — measured 34.9%
fewer bytes on a small payload.

Tack is the ideal client for that mode, and for a reason no hand-written client
can match: **Tack knows every shape at build time.** It never needs a describe,
not even once. A Tack-generated remote binding can be compiled with the schema
cookie baked in and run in shape-free mode from its first call — zero schema
bytes, ever.

That suggests a Tack-specific refinement of the handshake worth building:

> For a hand-written client a cookie mismatch means "re-describe." For a
> **Tack** client it means the deployed binary was compiled against a different
> schema than the server is running. That is not a cache miss, it is a
> **deployment error**, and it should fail loudly at startup rather than
> silently degrade to describing. Tack's generated bindings should therefore
> present their cookie at connection setup and refuse to run on mismatch.

This turns the schema cookie into a build/deploy version check for free, and it
is only possible because §4 resolves shapes at compile time. It is the same
idea as this whole document — *resolve the mapping before the program runs* —
applied one layer further out, to the wire.

*End of document.*
