<!-- doc-status: design -->
# Http.serve: surviving a handler that panics (BUG-701)

Status: DECIDED 2026-11-12 (Sean): A, then B, and both are required -- B is not optional once A
lands. BOTH LANDED 2026-11-15 (BUG-701 closed). A: BUG-703, 704, 715 (2026-11-13), 735, 736, 733 and
734 (2026-11-15) fixed -- the 2026-11-15 sweep, recorded under BUG-701. B: its rules are
under "B as built" below, pinned by `test/bug701_serve_restart_test.zbr`.

Not covered by that fixture: the grandchild rule (a server process's own Zebra child ignoring
the marker), the Linux and macOS ends-with-the-supervisor paths (the fixture runs them, but has
only been watched red on Windows), and a signal-terminated server on POSIX.

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

### What B must say to app authors (Fable, 2026-11-12, from Graze)

A restart resets every module-level `var` in the handler's program, so anything a handler
accumulates there -- caches, counters, **rate limits** -- is lost. For a rate limit that is a
security hole, not just a loss: anyone who can crash a child resets the attempt count. Graze's
sign-in throttle (failure counts per name, in a process HashMap) is the receipt. It moved to
Sqlite the same evening (graze aaf891a), and its check is the template for B's own fixture:
`check_tasks.py` restarts the server mid-run, and a name locked under the first process signed
straight in under the second while the counts lived in memory, and is refused with them in the
database. Everything else Graze holds is rebuilt at startup from its inputs
(route table, the session key from its key file, the decoy password hash) or is stateless
(signed session cookies, signed forgery tokens). B's documentation must state the reset rule
and name the rate-limit case.

## B as built (2026-11-15)

`Http.serve(port, handler, restart: true)`; `restart` is named only, a `bool`, and may stand
beside `host:` in either order. `Ws.serve` and `Tcp.serve` refuse `restart:` by name: the
decision covers `Http.serve`, and a WebSocket's open connections are its state, so a restart there
needs its own design.

**Re-exec, not fork.** Windows has no fork, so the process that reaches the call becomes the
SUPERVISOR: it never listens, and starts its own executable again, same argv, as the SERVER
process, with `ZEBRA_SERVE_CHILD=<port>:<supervisor pid>` in its environment. The server process
runs `main` from the top, reaches the same call, sees the marker, and serves. Consequences, all
documented in QUICKSTART:

- Everything before the call runs once in the supervisor and again in every server process.
- Every module-level `var` starts over on a restart: caches, counters, and rate limits. A rate
  limit kept in memory is reset by anyone who can crash the server (the Graze receipt above).
- The call must be made from `main`'s own thread, and once per program. Called from a
  `sys.go` thread, the restarted process would re-run `main` and redo whatever that thread's
  caller did next, so the runtime refuses it (`_zbr_main_tid`, recorded by the entry prologue;
  a program with no recorded main thread -- `--library-mode` -- is refused too).
- The marker names the supervisor's pid. A server process whose parent is not that pid ignores
  it, so a Zebra program a handler starts supervises itself rather than inheriting the role.

**What the supervisor does with an ending server process.** Windows exit codes are read whole
(`GetExitCodeProcess`); Zig's `Term` truncates them to 8 bits.

| how it ended | supervisor |
|---|---|
| exit 0 (a handler called `sys.exit(0)`) | exits 0, no restart |
| exit 98, `_HTTP_SERVE_LISTEN_FAILED` (it could not listen; the reason is printed above) | exits 98, no restart -- a held port or a bad host is not cured by trying again |
| Ctrl-C or a terminate request (SIGINT/SIGTERM; Windows `STATUS_CONTROL_C_EXIT`) | exits 128 + the signal (130 for Ctrl-C on Windows), no restart. A console Ctrl-C reaches both processes, so the supervisor usually ends by it directly |
| anything else: a panic (exit 1), a segfault, another exit code, another signal | restarts after a backoff, and prints the code or signal, the uptime and the count |

Restart policy: at most `_HTTP_SERVE_MAX_CRASHES` (5) restarts in any `_HTTP_SERVE_CRASH_WINDOW_S`
(60 s); the next crash in that window ends the supervisor with exit 1 and a message naming the
count. The backoff doubles from 100 ms for each crash in the window (100, 200, 400, 800, 1600
ms). A server process that serves for a minute without crashing restarts the count.

**Exit 98 is only meaningful from a server process.** A handler that calls `sys.exit(98)`
stops the supervisor as if the port were held. The code is documented, not hidden.

**The server process does not outlive the supervisor.** Windows: it is assigned to a Job object
created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so it ends when the supervisor ends, however
it ends. Linux: `PR_SET_PDEATHSIG` = SIGKILL, then a check that the parent did not already go.
Other POSIX (macOS): a thread polls `getppid()` once a second and exits the process when it
changes. Without this, killing the supervisor left a server holding the port, and the next start
of the program found it taken.

**A re-bind after a crash.** On POSIX the server process listens with SO_REUSEADDR, or Linux
refuses the bind while the previous process's closed connections sit in TIME_WAIT (up to 60 s).
Not on Windows, where SO_REUSEADDR lets a second socket take a port already bound; there every
server binds exclusively since BUG-727 (measured: an exclusive rebind succeeds with the old
server's connections in TIME_WAIT). An unsupervised `Http.serve` is unchanged.

What a restart does NOT give: an answer to the request in flight (the client sees a reset), or
anything held in memory. That is option C's ground.

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
