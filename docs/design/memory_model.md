<!-- doc-status: design -->
# Memory in long-running programs — the model, brainstormed

**Status:** BRAINSTORM for Sean, nothing decided. Written 2026-10-22 by Opus 5.5 (the
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

1. **`allocate Arena()` must reclaim (BUG-617).** Back a scoped arena with a freeing
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
8. **Reuse in place: `clear()` that keeps capacity** (Fable). The per-frame reuse idiom every
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
2. **Cycles: `weak` by default on parent-shaped fields, or opt-in?**
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

Fable: the engine evidence (§1), the BUG-618 trace and no-regret items 2-7, models B-E, the handle-ABI requirement,
the cycle analysis, the acceptance list, and both dissents in §6. Opus: Sean's-loop
measurements and the finding that `allocate Arena()` reclaims nothing, the inventory (§2),
model A, the copy position and the thread rule.
