<!-- doc-status: design -->
# Http.serve: surviving a handler that panics (BUG-701)

Status: DECIDED 2026-11-12 (Sean): A, then B, and both are required -- B is not optional once A
lands. Nothing built yet.

## The problem

`Http.serve` runs each request's handler on its own thread, inside the server process. A Zig
panic ends the process, and Zig has no `recover`, so one handler defect ends the whole server:
every other connection in flight and every later request. Graze's charter (§4.3) asks for the
opposite: answer the request 500 and keep serving.

The defect does not have to be the handler author's. BUG-703 (`chars()` on bytes that are not
UTF-8) is reachable from any client that sends such bytes, so today any Zebra web server is one
crafted request away from going down, unless every handler validates input first.

## Options

### A. Remove panics that input can trigger (do first, whatever else is chosen)

Find every runtime path where bytes a client controls can reach a panic, and make each one
return a value instead: BUG-703 (`chars()`), the `std.debug.panic` arms in parsing helpers, and
integer conversions on header values. BUG-704 (`readAll()` panicking when a peer resets) is the
client-side case of the same thing. This does not make the server crash-proof, since a
handler's own `assert` or out-of-range index still panics. It does close the case where a
stranger can stop the server with no bug in the program.

- Cost: small per site. The work is finding the sites; a fuzzer over `HttpRequest` fields (the
  leakgen pattern, but RUNNING the handler) would find them.
- Keeps: one process, shared memory between requests, no IPC.

### B. A supervising parent that restarts the server

`Http.serve` forks or spawns itself as a child and restarts it when it dies. Requests in flight
on the crashed child are lost (the client sees a reset, not a 500); new connections reach the
restarted child after a delay.

- Cost: moderate. Needs a listen socket shared with or passed to the child (or a re-bind after
  the child exits), and a restart policy (backoff, give up after N crashes per minute).
- Weakness: in-memory state is lost on every crash. A Graze session table in memory would be
  wiped, so it would have to live in Sqlite.
- Answers "keep serving"; does not answer "answer 500".

### C. A pool of worker processes, each handling one request at a time

The parent accepts connections and hands each one to a worker process; a worker that dies is
replaced, and the parent answers 500 for the request it was holding.

- Cost: the largest. Passing a socket between processes differs per OS (SCM_RIGHTS on POSIX,
  `WSADuplicateSocket` on Windows), or the parent proxies the bytes itself.
- Answers both "answer 500" and "keep serving". This is the prefork model (Apache prefork,
  Unicorn).
- Same in-memory-state caveat as B, per worker.

### D. Per-request recovery inside the process

Not available in Zig: a panic handler can run code, but cannot unwind the panicking thread and
resume. Listed so nobody re-proposes it without new information.

## Decision

Sean, 2026-11-12: the recommendation below, with both halves required. A alone leaves the server
one handler bug from going down; B alone restarts a server that any stranger can keep knocking
over. A narrows who can crash it, B bounds what a crash costs, and neither replaces the other.

## Recommendation

A now, as ordinary bug fixes (BUG-703 first). Then B, behind an opt-in such as
`Http.serve(port, handler, restart: true)`, because it is the smallest change that keeps a
server up, and Graze already keeps its durable state in Sqlite. C only if a real deployment
needs the 500 rather than a reset; its socket-passing cost is real and per-OS.

## What would change this

- If Graze needs in-memory state that cannot move to Sqlite, B and C both lose it, and the
  answer becomes "make handlers unable to panic" (A plus a lint), not process isolation.
- If the V backend's runtime can recover from a handler panic (V has no `recover` either, but
  check), the two backends would differ, which is its own decision.
