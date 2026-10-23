<!-- doc-status: design -->
# Memory in long-running programs — the model, brainstormed

**Status:** BRAINSTORM for Sean. Decided so far: §6.2, weak by default for declared parent links (Sean, 2026-10-23). §6.1 measured, with Fable's review pending. Written 2026-10-22 by Opus 5.5 (the
compiler session) with Fable (the GameEngine session), at Sean's request: "coordinate with
Fable ... and brainstorm on the best way forward". Where the two of us agree it says so;
where we disagree, both positions are kept. The 2026-10-11 decision ("reference counting for
strings and containers, cycles accepted, debug-mode leak report") is the starting point, not
assumed final.

---

## 1. The problem, measured

**Sean's worry:** a general program, not only the engine, sees RAM grow with what it has
*ever* allocated. The example: `a = b.upper().split("*")[0]` in a loop over the lines of a
large file.

**Measured 2026-10-22** on a 100 MB file (1,972,690 lines), lines read from stdin with
`sys.readLine()`, `--release`, arena growth from `sys.memStats()` and the OS peak working set:

| variant | arena growth | peak working set |
|---|---|---|
| A: read the lines, nothing else | 245 MB (2.5x the file) | 248 MB |
| B: `a = line!.upper().split("*")[0]` | **942 MB (9.4x)** | 678 MB |
| C: the documented workaround, `allocate Arena()` around the body and `a <<- ...` | **1247 MB** | **1009 MB** |
| C after BUG-617 (2026-10-23): the block backed by an allocator that frees | 318 MB | 265 MB |

C is the surprise: the workaround QUICKSTART recommends makes it WORSE. It emits
`std.heap.ArenaAllocator.init(_allocator)`, so the scoped arena is backed by the program
arena; on exit it "frees" into an allocator that never frees, and its own bookkeeping is
added on top. That is a bug independent of any model (§3, item 1). Programs and harness:
`C:\tmp\zzrc\` (`a_read.zbr`, `b_plain.zbr`, `c_arena.zbr`).

What one iteration of B allocates today (from the emitted Zig): a copy of the line
(`allocUpperString`), a List header (`_zbr_new`), the List's buffer and every buffer it
outgrows, and `a` is a slice INTO the upper-case copy. None of it is ever freed.

**The engine (Fable, 2026-10-22, a plain `--mm-gui` run):** a steady **+8.3 MB/s** net, about
1,000 allocations per frame averaging ~140 bytes, every section growing together (scripts
9.1 MB, gui 2.2, render 1.6, collision 0.8, other 2.8 per 2 s window): the signature of
"temporaries nobody frees", not one bad site. A 24-minute run reached 18 GB. The intern pool
grew 1,947 -> 2,269 strings in 20 s with no new literals -- traced by Fable the same night to
a COMPILER rule (BUG-618, §3 item 2): every `str` stored into a class field is wrapped in
`_intern(...)`, and `_intern` copies each new string onto its own page, forever. Earlier, F50: a page per JSON node gave 13 GB in
30 s -- **a 100-byte leak under a page-granular allocator is a 4 KB leak (64 KB of reserve on
Windows); the allocator behind the model matters as much as the model.**

**Which kind dominates (Fable's deeper report, engine commit 50c5e70).** The Debug leak report
at 6 s (24 frames) lists 126k live allocations, 103k of them the nine animation clips' JSON
trees -- parsed once each and kept after the clips are built, ~10 MB one-time -- the rest also
one-time (map library, laid map, GUI scene). So the per-frame drift does NOT go through the Zig
allocator the leak report sees, and the host's counting allocator over-reads it. The OS does
see it: 64 KB committed regions at ~145/s (+9.4 MB/s), whose first bytes are floats, doubles
and pointers, no text. **The dominant kind is the runtime's own objects -- containers and boxes
rebuilt every frame and never freed**; the intern pool's pages are about a tenth. Named engine
sites: the GUI flush's five fresh Lists a frame (cmds, hitNodes, hitRects, hoverNodes,
hoverRects, a few hundred items each), a fresh List per host-polled queue per frame, the status
handler's attribute JSON each second per character, the health bar's format strings.

## 2. What allocates today, and what frees

The program allocator `_allocator` is one `ArenaAllocator` over the page allocator (wrapped
thread-safe when threads exist), released only at exit (`defer _arena.deinit()` in `main`).
Everything below goes through it:

- strings: concatenation, interpolation, `toString()`, `upper()`, `split()`, file reads;
- class instances (`_allocator.create` in every constructor);
- container headers (`_zbr_new`) and storage -- and **growth garbage**: an arena resizes in
  place only for its most recent allocation, so a growing List, a HashMap rehash or a
  StringBuilder leaves every outgrown buffer behind (building a list costs ~2x its size);
- `^T` boxes, union payloads, closure cells (BUG-569/607, 2026-10-22);
- thread allocations (same arena through the thread-safe wrapper).

Outside the arena, also never freed: **76** `std.heap.page_allocator` escape hatches in the
runtime (the `escape-hatches` gate counts them): the string intern pool, JSON values and
output, error messages formatted on `raise`, ObjectPool / ThreadPool headers, HTTP buffers.

What frees: a scoped `allocate` block (in principle -- see C above), `--library-mode` with a
host allocator plus `_zbr_free`, and process exit.

## 3. No-regret steps -- do these under ANY model (joint)

Each is useful whatever Sean decides, and the census and the gate are how the decision gets
measured.

1. **`allocate Arena()` must reclaim (BUG-617) -- DONE 2026-10-23,** variant C 1009 -> 265 MB. Back a scoped arena with a freeing
   allocator (the page or smp allocator), not with `_allocator`; red-check with variant C
   above, which must go flat. Same for `Debug()`. Without this the language's only tool for
   bounded memory does not work.
2. **A field store must not intern (BUG-618, found by Fable).** Codegen wraps every `str`
   stored into a class field in `_intern(...)` -- `_self.name = _intern(name)`,
   `guiProps().text = _intern(text)`, `attributes.put(_intern(key), _intern(value))`: 89 + 19
   + 13 + ... sites in the emitted engine, all dynamic text. `_intern` dupes each new string with
   `std.heap.page_allocator` (a page per string; 64 KB of reserve on Windows) and keeps it
   forever, so a timer label rewritten once a second is an immortal page a second. Interning is
   today's FIELD-OWNERSHIP strategy (a field-held str must not dangle into a temporary), which
   makes it unbounded by construction for any field that takes dynamic text. Steps: (a) at
   least intern through the program allocator (bytes, not pages; ~100x smaller, still
   unbounded); (b) better, a field store COPIES into a fresh allocation, with interning kept for
   literals only. Under counting the rule disappears (the field holds a count). Engine witness:
   the plain run's intern-pool count flat over 60 s. This is the live leak in every Roblox port.
   **(a) DONE 2026-10-22:** 50,000 field stores 202 MB -> 5.2 MB; (b) remains.
3. **Free outgrown container buffers** (Fable). The old buffer on growth is pure waste under
   any model; route container storage through an allocator that frees.
4. **One allocator interface, no page-allocator escapes** (Fable). Each of the 76 hatches turns
   a byte leak into a page leak; each moves to the program allocator or carries a written
   reason why it must outlive everything.
5. **A builder with reused capacity** for per-frame formatting (Fable) -- the GUI flush builds
   ~200 formatted strings per frame through `_str_concat` chains.
6. **A per-type allocation census** in the runtime (Fable): strings, Lists, maps, instances,
   closure cells, boxes, interned -- counts and bytes, on the profiler's memory line and from
   `sys.memStats()`. This is the evidence the decision needs, and the witness afterwards.
   Per TYPE **and per SITE** (Fable, reviewing this note): the engine's 8.3 MB/s is spread
   across every section, so a per-type count alone will not say which GUI path to fix.
   Fable can land the engine side.
7. **A leak-budget gate** (Fable): a fixed-length plain run (the engine for 60 s; Sean's loop
   over a large file) must not grow committed private memory past a budget. The same gate
   witnesses whatever model lands.
8. **Reuse in place: `clear()` that keeps capacity** (Fable) -- **DONE 2026-10-23**
   (`HashMap.clear()` added; `List.clear()` documented). The per-frame reuse idiom every
   game has, and the one change that cuts the engine's drift today without a model. Measured
   while adding this: `List.clear()` ALREADY EXISTS and keeps capacity (it emits
   `clearRetainingCapacity()`) but QUICKSTART never mentions it, so nobody knew; `HashMap` has
   no `clear()` at all (the checker refuses it; `Set.clear()` exists). So: document
   `List.clear()`, add `HashMap.clear()` with the same retaining behaviour.
9. **A JSON parse result that can be released** once the value built from it is kept (Fable):
   the engine's nine clips hold ~10 MB of parse tree they never read again.

Items 1 and 3 should take variant B from 9.4x toward the size of what it keeps, for any program
that bounds its loops with `allocate`; item 2 removes the engine's one named live leak.

## 4. The models considered

| model | for | against |
|---|---|---|
| **A. Reference counting, freed at LAST USE** (Koka's Perceus, Lobster; Nim ARC/ORC is the closest compile-to-a-systems-language precedent) | deterministic, no pauses, Python-like expectations met (Sean's loop runs flat), works with a host that holds values; most inc/dec elided at compile time (Lobster reports ~95%) | the `str` representation changes (a counted buffer, not a bare slice), touching every runtime string function and the FFI; releases on every path, including `raise`/`catch` unwinding; cycles leak without help; the V backend's boxed runtime must count the same |
| **B. Perceus reuse** on top of A (Fable) | when a count is 1, `upper()` / `split()` reuse buffers in place -- Sean's loop allocates nothing per iteration | only as good as A's precision |
| **C. Escape analysis for temporaries** (Fable) | a List or str made, used and dropped inside one function (no field, no return, no capture) is freed at the function's end with no counts at all; most of the engine's ~1,000 per frame are this shape | a conservative analysis misses some; needs A (or an arena) for the rest |
| **D. A frame arena the HOST owns**, opt-in (Fable) | `Workspace.frameScope` around step+draw; the compiler REFUSES assigning a frame-arena value to a field, module var or capture (a static check, as `<<-` is today), so "the loop kept something" is a compile error, not a surprise; Unity's `Allocator.Temp`, Bevy's frame allocators are the precedent; removes the engine's drift alone | a tool for frame-shaped programs, not a model for general code |
| **E. Generational handles** for engine Instances (Fable) | a slab plus a generation counter, as the engine's ECS already does for entities: Destroy invalidates, no cycles exist, a host keeps handles safely with no retain; the Roblox DataModel's real shape | an engine representation, not a language rule |
| **F. Automatic per-iteration arena** | cheap | real loops KEEP something (append a parsed field to a results list), so the user must know to `<<-` it out -- the same surprise moved |
| **G. Tracing GC** | handles cycles | pauses inside a 16 ms frame; host-held pointers need a host-roots API ("hostile to embedding" is only true without one) |

**Joint recommendation:** the hybrid -- **A + B + C as the language's model** (counts freed at
last use, with reuse and escape analysis making them cheap and mostly invisible), **D as an
opt-in tool** whose escapes the compiler refuses, **E as the engine's Instance
representation**. F and G ranked below by both of us.

## 5. Requirements any model must meet (joint)

- **Host-held values go through an explicit handle ABI** (Fable). Today's rule is "the host
  copies what it keeps"; under counting it becomes "the host retains what it keeps", and a
  forgotten retain is a **use-after-free instead of a leak** -- the one place counting makes the
  engine worse. So a host-facing value is an opaque handle the host cannot dereference without
  retaining, and `_zbr_free` becomes `_zbr_release`. The V backend honours the same ABI.
- **A value handed to the host and used "later" is a last use the compiler cannot see**
  (Fable): the ABI retains across that boundary explicitly.
- **Threads:** counts are plain (non-atomic) by default; only values crossing `sys.go` / `Chan`
  pay for atomics. Zebra already makes those boundaries explicit (a `sys.go` closure names what
  it uses in a `capture` block), which is Nim's approach.
- **Module-level containers initialised by nobody** (the engine's F26) must not hold references
  forever.

## 6. Decisions for Sean (both positions kept)

1. **Substrings and `split` results: copy, or a view that keeps its parent alive?**
   - Opus: copy. A view keeps the whole parent alive -- keep a 3-byte field from every line and
     you have kept every line (Java's and Go's substring trap).
   - Fable: views are the normal design for immutable strings, and copying the GUI's per-frame
     `split` results is a real cost. Keep views and measure.
   - Agreed: **measure first** (the census, item 6 in §3); take copies if they are cheap enough.
   - **Measured 2026-10-23 (Opus; Sean: "let's measure"). Fable's review is PENDING** -- Fable is
     out of tokens until about 2026-10-26, so this is one side's reading of one benchmark, not a
     joint conclusion.

     Today `split` and `substring` are already views (slices into the parent) and nothing is
     freed, so the question only exists under a freeing model. `bench/split_copy_view/` (Zig,
     `bash bench/split_copy_view/run.sh 5`, raw output in `results_2026-10-23.txt`) simulates
     what a counted runtime would free, and when, over Zig's `smp_allocator`, three policies:
     **view** (a kept piece keeps its parent alive), **copy_all** (`split` copies every piece,
     the parent dies at once), **copy_kept** (pieces are views while temporary; the one that is
     KEPT is copied at the store). Medians of 5 interleaved rounds; checksums agree across the
     policies of each workload, freed variants end with 0 MB live, the arena variant shows its
     full growth.

     | workload | view | copy_kept | copy_all |
     |---|---|---|---|
     | W1 Sean's loop, `a = line.upper().split("*")[0]`, 2M lines of ~50 B | 280 ms | 305 ms (+9%) | 430 ms (+54%) |
     | W2 keep field 0 of every line, 2M lines of ~50 B: time / live at end | 336 ms / **166 MB** | 307 ms / **53 MB** | 456 ms / 53 MB |
     | W2, 500k lines of ~200 B (20 fields): time / live at end | 232 ms / **117 MB** | 191 ms / **15 MB** | 348 ms / 15 MB |
     | W3 `"rect\|120\|340\|64\|32\|Play".split("\|")`, parsed and dropped, 2M times | 123 ms (61 ns each) | = view (nothing kept) | 358 ms (179 ns each) |

     Today's arena on W1, for scale: 294 ms and **464 MB** live at the end, against under 1 MB
     for every freeing policy.

     **What the numbers say.** Copying every piece is the expensive policy, about 3x on a short
     temporary split. Copying only what is kept costs about 9% on Sean's loop. It costs nothing
     on temporaries, and on the retention workload it is *faster* than view (it keeps less
     memory live). The retention trap is real and grows with the row/field ratio: 3x the live
     memory on 50-byte rows, 8x on 200-byte rows (the end-live totals include the results list
     itself, 16 B a piece in both policies, so the ratio of the string data alone is higher).
     Absolute scale for the engine: 1,000 `copy_all` splits a frame is 0.12 ms more per 16.6 ms
     frame. The engine's GUI flush (`guitree.zbr`, `gui.zbr`) contains no `split`. Its 85 `split`
     sites are elsewhere, many in ported scripts; how many run per frame is not measured.

     **Limits, so nobody reads more into this than it holds.**
     - copy_kept is a **store-site rule** the compiler would have to apply. W1 copied on a plain
       local assignment (`a = ...`), so in this model every `var x = s.split(..)[0]` pays the
       copy. A narrower rule (copy only into a field, container element, module var, return or
       capture) costs less on W1 and keeps a parent alive through a long-lived local. Which
       stores count is a design decision this benchmark does not make.
     - **view is under-costed.** It omits the parent pointer every view would carry (a `str` of
       ptr+len+parent) and the count increment/decrement on the parent per piece. The
       simulation's list of pinned parents stands in for the first.
     - One allocator (`smp_allocator`), one machine; the runtime's real counted header is not
       modelled. Spreads were tight except for three outlier maxima (W2 short copy_kept 524,
       W2 wide copy_all 661, W1 arena 332); all are in the raw file.

     **Opus's reading:** copy at the store, views for temporaries. That puts the retention
     protection behind a rule a reader can see, at single-digit cost. It is also the shape the
     compiler already has for `_intern` on a field store (BUG-618) and that escape analysis (§4
     C) needs anyway. Through the UNGIT tests: a view that pins its parent is *withheld*
     retention, since nothing at the use site says a 9-byte field is holding a 200-byte row.
     Copy-at-store happens at a declared point the compiler can name on request.
2. **Cycles: `weak` by default on parent-shaped fields, or opt-in?**
   - **DECIDED 2026-10-23 (Sean): weak by default**, the joint recommendation below. Precisely:
     weak by default for a field whose *kind* declares it a parent link (a declared shape the
     reader can see), never a compiler guess at which fields "look like" parents. A guessed
     weak reference would fail "nothing ambient", and a wrong guess would surface as a
     use-after-free rather than a leak.
   - Every engine tree node is a cycle from day one (`Instance.parent` <-> `children`), and
     signals hold closures that capture their owner. An opt-in `weak` is one a port forgets.
   - **Joint recommendation:** a field kind that is weak by default where the shape is declared
     (a parent link), plus explicit `weak` elsewhere; subscriber lists weak or Maid-style
     connection objects the owner drops (the ports already use Maid). Keep the debug-mode leak
     report for what remains.
3. **Are class instances counted?** The 2026-10-11 decision named strings and containers. A
   `Parser()` made per line grows the same way; the recommendation is yes.
4. **Order of work:** the no-regret steps (§3) first -- they are small, measurable, and fix the
   workaround users are told to use -- then a design for the counted representation before
   any code. Within §3, Fable would put the **census (item 6) first**: its per-site list is what
   any model's reuse and escape analysis will be judged against. Opus would put BUG-618 and
   BUG-617 alongside it (each is small, and each is a defect users hit today).

## 6a. How much a V backend resolves (Fable, at Sean's request)

With V's default Boehm collector the drift goes away **as a class** -- per-frame containers and
boxes, field-stored strings (no interning needed under a collector), instances, closure cells
-- with no Zebra-side model work: it is model G as a shipped collector, not one to write. The
costs, from the engine's side:

- Boehm is stop-the-world mark-sweep; the pause scales with the live heap (the engine's is
  100-300 MB: tens of ms against a 16 ms frame). An incremental mode exists; V's support for it
  is uneven.
- Conservative scanning retains pointer-shaped garbage, invisibly.
- **The host boundary gets worse:** the Zig / raylib side holds pointers the collector cannot
  see, so a missed root is a silent use-after-free, not a leak. Threads must register
  (`sys.go`).
- With `-gc none` (the V rows today) it resolves nothing -- today's arena with another
  allocator. With `-autofree`, some: experimental, leaks where it does not understand; not a
  basis.

It does not touch the no-regret items (which help under any backend), the determinism the
engine's budget guard relies on, the Zig backend (the shipped one), or the reference semantics
Sean chose for containers and closures.

**Measured (Fable, 2026-10-23)** on the engine's V window host over its 45 s autoplay, the
working set sampled every 2 s, three runs each:

| V build | working set over 45 s | frame cost |
|---|---|---|
| `-gc none` (the V rows today) | 573 MB -> **2,509 MB** (~43 MB/s; the boxed V runtime drifts about five times the Zig host's 8 MB/s on the same game) | 60 fps |
| `-gc boehm` | 135 -> 776 MB in the first 15 s (clips, scene, GUI), then **flat at ~810 MB** | 60 fps at the 2 s average; lowest sample 60; the budget guard (thirty frames over 20 ms in a row) never fired |

Both runs pass the window row (milestones identical, as a prefix of the Zig host's). So at this
scale the collector resolves the drift as a class with no frame cost the engine's instruments
can see -- the first measured "it just works" among the options, at no compiler change, which
makes it **the comparison every other model has to beat on the engine.** Caveats: 45 s is one
steady state (a longer run at a bigger live heap would show the collection cycles), and the
host-boundary hazard above is UNTESTED, because the V host's rows never keep a Zebra pointer past
the frame. `VGC=boehm` on the row script repeats it.

**Why `-gc none` drifts about five times faster -- apportioned by section (Fable, 2026-10-23).**
Per 2 s window of the engine's plain run, gross (bytes charged before any free) and net. The V
column samples Boehm's total at every profiler section boundary (three windows; with `-gc none`
nothing is freed, so V's net equals its gross):

| section | Zig gross | Zig net | V gross (= net) |
|---|---|---|---|
| scripts -- the emitted Zebra game | 16.2 MB | 9.9 MB | **7.8-10.4 MB** |
| render -- the host's own draw | 19.4 MB | 1.6 MB | 20.6-22.3 MB |
| gui | 2.5 MB | 1.6 MB | **39.4-50.3 MB** |
| collision | 1.5 MB | 0.8 MB | 1.7 MB |
| other | 5.6 MB | 2.8 MB | ~10 MB |

What it says:

- **The emitted game: the V backend allocates LESS per frame than the Zig backend, not more**
  (about 9 against 16 MB a window) -- boxing does not multiply the garbage. In the engine the Zig
  runtime allocates from the host's allocator and the game keeps about sixty percent of what it
  allocates (9.9 of 16.2); V keeps all of its ~9. So **the game's drift is the same on both
  backends, ~10 MB a window**.
- **The host's draw** is ~20 MB a window on both: freed by the host's defers on the Zig side, by
  the collector on the V side.
- **The one real difference is the GUI path: ~45 MB a window on the V host against 2.5 on the
  Zig host.** Split around the flush call (two windows): **two thirds (~30 MB) is the emitted GUI
  tree's flush** -- the same Zebra code whose Zig emission allocates 2.5 for the whole section, so
  this is the V BACKEND's string handling -- a backend finding. Traced (Fable): the command
  builders are one interpolated literal with ~10 formatted floats each; the Zig backend emits one
  `std.fmt.allocPrint` per command (one allocation, the floats formatted into its buffer), while V
  lowers the literal to `str_intp`, whose float formatting returns a heap string per value before
  joining them -- **~11 allocations per command against one**, ~200 commands a frame. Not `+`
  chains (an earlier guess here). **The fix (Fable's, in CodeGenV, the next V-backend thread):**
  emit an interpolation whose arguments are numbers as ONE formatted write -- V's stdlib has no
  allocation-free float formatting (every path ends in a `tos_clone`), so through a C-level
  `snprintf` into a stack buffer and one final string: one allocation per interpolation. Witness:
  the same gui-flush line, 30 MB a window before. **Landed** (d67ee8d on v-backend-poc,
  2026-10-23): **30 -> 4.5-10.6 MB a window** (the gui section 46 -> 11-29); the spelling is the
  Zig backend's by a tie rule, since V's `str_intp` and C's `printf` each spell ties and specials
  differently (`docs/design/v_backend_poc.md`, "Float interpolation as one formatted write").
  **Dropped:** an engine-side per-flush command
  buffer -- the Zig flush is already one `allocPrint` per command (2.5 MB a window; a buffer takes
  it to ~1.5), and on V the cost is inside each number's formatting, which a builder around the
  commands does not reach. **The other third (~16 MB) is
  the V host's draw** parsing the ~200 command strings a frame with copying `split` / `substr`
  where the Zig host slices -- a port finding. So the V backend's emitted game allocates less in
  the step (9 vs 16 MB) but twelve times more in the GUI flush (30 vs 2.5), and that flush is
  string building: **the no-regret builder item (§3 item 5, reused capacity for per-frame
  formatting) is where the V backend gains most.**
- With Boehm the V heap holds at **109 MB** from 16 s on (~0.6 collections a second, no frame the
  budget guard saw); without it every byte is kept. A collector keeping a 109 MB live set at
  60 fps is the measured floor any counting scheme has to match on the engine.

(A first reading compared WHOLE-PROCESS gross on both sides -- "~40 MB/s on both, the Zig side
frees 80 percent" -- and the section split showed that figure was mostly the host freeing its own
draw. The wrong instrument for the claim, corrected the same night; recorded so it is not
re-derived.)

## 6b. The models through the UNGIT tests (Fable, at Sean's request)

Nothing withheld / nothing fabricated / nothing ambient (`concept_ungit-principle`):

- **Today's arena.** Withheld: no instrument said memory grows (the engine's 18 GB was a
  24-minute accident). Fabricated: `allocate Arena()` read as freeing and reclaimed nothing
  (BUG-617 -- a green from an instrument never seen red). Ambient: the arena is the program's
  whole life, declared by nobody.
- **Reference counting at last use.** Nothing withheld IF the compiler can say, per site and on
  request, what it inserted and what it elided, and debug builds report cycles. Nothing
  fabricated IF `weak` is visible where declared (a field kind), not inferred. Ambient risk: the
  host's retain, unless the handle type makes it explicit (a handle the host cannot dereference
  without retaining).
- **Frame arena, host-owned.** Nothing withheld (entered and left at a named point). Nothing
  fabricated ONLY with a compile-time refusal of escapes that names the fix -- a runtime-silent
  escape is the `<<-` surprise again. The boundary is declared by the host, never inferred from
  a loop.
- **Tracing GC (V's Boehm).** Withheld unless the runtime reports pauses where the user looks
  (the profiler's frame line); fabricated liveness from conservative scanning, with no report;
  ambient at its worst -- thread registration and host roots, where a missed root is a silent
  use-after-free.
- **Perceus reuse / escape analysis.** Needs a "why was this not reused" answer on request, or a
  slow loop is unexplainable; otherwise holds. An optimisation, not a rule.
- **Generational handles.** A stale handle fails loudly on the generation check; nothing reads
  freed memory as live; Destroy is the declared event. Holds on all three.
- **The census and the leak budget** are the UNGIT instruments themselves: the count where the
  user looks, a strip that goes red -- and a budget never seen red is the first thing to run.

Two conclusions: **the tracing collector fails all three tests at the host boundary**, which is
the engine's exact seam; and **counting passes only if its elision and its cycle leaks are
REPORTABLE** -- a tooling requirement to write into the design, not an afterthought.

## 7. Acceptance (Fable's witness list)

Before Sean decides on a branch:

- the plain engine run for ten minutes with committed private memory flat (the leak-budget
  gate), and the host-boundary duo;
- the autoplay's fps within noise of today's (the inc/dec cost on the ~1,000-allocation GUI path,
  with elision);
- `designer_test`, `demo_test`, the full engine suite: Destroy and the signals under counting
  (cycles), nothing freed under the host's feet (the snapshot rule);
- Sean's loop over a 1 GB file, flat;
- the V backend showing the same counts on one program.

## 8. Credits

Fable: the engine evidence (§1), the BUG-618 trace and no-regret items 2-7, §6a and §6b, models B-E, the handle-ABI requirement,
the cycle analysis, the acceptance list, and both dissents in §6. Opus: Sean's-loop
measurements and the finding that `allocate Arena()` reclaims nothing, the inventory (§2),
model A, the copy position and the thread rule.
