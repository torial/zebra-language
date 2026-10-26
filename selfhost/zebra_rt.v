// zebra_rt.v -- the Zebra runtime for the V backend (proof of concept, 2026-10-13).
// Installed beside an emitted <stem>.v by `zebra --target v`; both compile as one
// V module (`v run <dir>` or `v run <stem>.v` with this file beside it).
//
// The containers are REFERENCES, as Zebra's are (zebra-language BUG-501 1d):
// a V array is a value copied on assignment, so a Zebra List is a struct by
// reference holding one, and two names for it are one container. A mutating
// method needs a `mut` receiver, and V cannot call one on a call's result: the
// emitter binds a temporary for `xs.at(0).add(7)`.

// the modules the runtime uses (the emitted file's header imports them;
// unused imports are a V warning, and these are used here regardless)

// ── List ───────────────────────────────────────────────────────────────────
@[heap]
pub struct ZList[T] {
pub mut:
	items []T
}

pub fn new_zlist[T]() &ZList[T] {
	return &ZList[T]{}
}

pub fn zlist_of[T](zr_items []T) &ZList[T] {
	return &ZList[T]{
		items: zr_items
	}
}

pub fn (mut zr_l ZList[T]) add(zr_x T) {
	zr_l.items << zr_x
}

// a one-variant union's second member (a `type U = U_v` alone is an alias to V,
// not a sum type): never constructed, never matched
pub struct ZUnionPad {}

// List.append: the same as add (the emitter maps methods by name, and a Zebra
// list has both; 2026-10-14, tree_smoke)
pub fn (mut zr_l ZList[T]) append(zr_x T) {
	zr_l.items << zr_x
}

pub fn (zr_l &ZList[T]) at(zr_i i64) T {
	return zr_l.items[zr_i]
}

pub fn (mut zr_l ZList[T]) set(zr_i i64, zr_x T) {
	zr_l.items[zr_i] = zr_x
}

pub fn (zr_l &ZList[T]) count() i64 {
	return i64(zr_l.items.len)
}

pub fn (zr_l &ZList[T]) is_empty() bool {
	return zr_l.items.len == 0
}

pub fn (zr_l &ZList[T]) copy() &ZList[T] {
	return &ZList[T]{
		items: zr_l.items.clone()
	}
}

// (the comparing helpers -- contains, index_of, remove by value -- are free
// functions below, not methods: V instantiates every method of a generic
// struct per element type, and its C for `it == x` over the parse tree's
// sum type did not compile; a free function is instantiated where called)

// (insert / remove_at are out for now: `l.items.insert(int(i), x)` on a generic T
// is instantiated with the wrong element type under V 0.5.2 once two ZList
// instantiations exist -- the i64 call got the string body; a repro is kept
// at C:/Projects/v-dist/repro_v/ for a ticket to V)

pub fn (mut zr_l ZList[T]) clear() {
	zr_l.items.clear()
}

pub fn (zr_l &ZList[T]) last() T {
	return zr_l.items.last()
}

// (a free function, not a method: a method is instantiated for every
// element type the struct is named with, and V's own string method for a
// float array lost a helper to its unused-pruning at the C stage)
pub fn zlist_str[T](zr_l &ZList[T]) string {
	return zr_l.items.str()
}

// ── HashMap ────────────────────────────────────────────────────────────────
@[heap]
pub struct ZMap[K, V] {
pub mut:
	m map[K]V
}

pub fn (zr_m &ZMap[K, V]) contains(zr_k K) bool {
	return zr_k in zr_m.m
}

// Zebra's fetch: the value, or a failure when the key is absent (the Zig
// backend's `.?`; callers guard with contains)
pub fn (zr_m &ZMap[K, V]) fetch(zr_k K) V {
	return zr_m.m[zr_k] or { zbr_panic('fetch: no such key: ${zr_k}') }
}

pub fn new_zmap[K, V]() &ZMap[K, V] {
	return &ZMap[K, V]{}
}

pub fn (mut zr_z ZMap[K, V]) set(zr_k K, zr_v V) {
	zr_z.m[zr_k] = zr_v
}

// Zebra's get is a nilable: V's option
pub fn (zr_z &ZMap[K, V]) get(zr_k K) ?V {
	if zr_k in zr_z.m {
		return zr_z.m[zr_k] or { return none }
	}
	return none
}

pub fn (zr_z &ZMap[K, V]) has(zr_k K) bool {
	return zr_k in zr_z.m
}

pub fn (mut zr_z ZMap[K, V]) remove(zr_k K) {
	zr_z.m.delete(zr_k)
}

pub fn (zr_z &ZMap[K, V]) count() i64 {
	return i64(zr_z.m.len)
}

pub fn (zr_z &ZMap[K, V]) keys() &ZList[K] {
	return &ZList[K]{
		items: zr_z.m.keys()
	}
}

pub fn (zr_z &ZMap[K, V]) values() &ZList[V] {
	return &ZList[V]{
		items: zr_z.m.values()
	}
}

pub fn (mut zr_z ZMap[K, V]) clear() {
	zr_z.m.clear()
}

pub fn (zr_z &ZMap[K, V]) copy() &ZMap[K, V] {
	return &ZMap[K, V]{
		m: zr_z.m.clone()
	}
}

// ── Set ────────────────────────────────────────────────────────────────────
@[heap]
pub struct ZSet[T] {
pub mut:
	m map[T]bool
}

pub fn new_zset[T]() &ZSet[T] {
	return &ZSet[T]{}
}

pub fn (mut zr_s ZSet[T]) add(zr_x T) {
	zr_s.m[zr_x] = true
}

pub fn (zr_s &ZSet[T]) contains(zr_x T) bool {
	return zr_x in zr_s.m
}

pub fn (mut zr_s ZSet[T]) remove(zr_x T) {
	zr_s.m.delete(zr_x)
}

pub fn (zr_s &ZSet[T]) count() i64 {
	return i64(zr_s.m.len)
}

pub fn (mut zr_s ZSet[T]) clear() {
	zr_s.m.clear()
}

pub fn (zr_s &ZSet[T]) items() &ZList[T] {
	return &ZList[T]{
		items: zr_s.m.keys()
	}
}

// ── StringBuilder ──────────────────────────────────────────────────────────
@[heap]
pub struct ZStringBuilder {
pub mut:
	parts []string
}

pub fn new_zstring_builder() &ZStringBuilder {
	return &ZStringBuilder{}
}

pub fn (mut zr_b ZStringBuilder) append(zr_s string) {
	zr_b.parts << zr_s
}

// StringBuilder.appendChar(byte): one byte (2026-10-14, toolbar_smoke's RGBA icons)
pub fn (mut zr_b ZStringBuilder) append_char(zr_c i64) {
	zr_b.parts << [u8(zr_c)].bytestr()
}

pub fn (mut zr_b ZStringBuilder) append_int(zr_x i64) {
	zr_b.parts << zr_x.str()
}

pub fn (mut zr_b ZStringBuilder) append_float(zr_x f64) {
	zr_b.parts << zr_x.str()
}

pub fn (mut zr_b ZStringBuilder) append_bool(zr_x bool) {
	zr_b.parts << zr_x.str()
}

pub fn (zr_b &ZStringBuilder) build() string {
	return zr_b.parts.join('')
}

pub fn (mut zr_b ZStringBuilder) clear() {
	zr_b.parts.clear()
}

pub fn (zr_b &ZStringBuilder) len() i64 {
	mut zr_n := i64(0)
	for zr_p in zr_b.parts {
		zr_n += i64(zr_p.len)
	}
	return zr_n
}

// ── the list methods V's generics cannot carry on the struct ──────────────
// (a generic method is instantiated for every element type the program uses,
// and `join` only exists for strings; `sort` wants a comparable T)
pub fn zjoin(zr_l &ZList[string], zr_sep string) string {
	return zr_l.items.join(zr_sep)
}

// `x == nil` / `x != nil`: through a call, so V never smart-casts the name
// (a smart-cast name refuses an `or` block, keeps its option type in a
// binding, and breaks the C stage when passed back to a generic `?T`)
pub fn zis_none[T](zr_x ?T) bool {
	return zr_x == none
}

// a def that is nilable AND throws returns this (V has no `!?T`): the
// emitter wraps its returns and unwraps a `?`-call back to V's option
pub struct ZOpt[T] {
pub mut:
	has bool
	val T
}

pub fn zopt_of[T](zr_o ZOpt[T]) ?T {
	if zr_o.has {
		return zr_o.val
	}
	return none
}

pub fn zopt_from[T](zr_x ?T) ZOpt[T] {
	if zr_v := zr_x {
		return ZOpt[T]{ has: true, val: zr_v }
	}
	return ZOpt[T]{}
}

// `opt == value` (Zebra compares a nilable with a value): false when none
pub fn zopt_eq[T](zr_a ?T, zr_b T) bool {
	zr_x := zr_a or { return false }
	return zr_x == zr_b
}

// `x!`: the value, or a failure
// an option held as itself: what `?T(x)` did on 0.5.2, which master refuses as
// a cast of an option to its own type
pub fn zopt_id[T](zr_x ?T) ?T {
	return zr_x
}

// a Zebra `^U` payload inside U's own variant: a heap box, so the sum type
// (an inline tagged union on V master, vlang/v#29578) has no value cycle
@[heap]
pub struct ZBox[T] {
pub mut:
	v T
}

pub fn zbox[T](zr_x T) &ZBox[T] {
	return &ZBox[T]{ v: zr_x }
}

// == concurrency ==
// Zebra's Atomic(T): a value under a mutex -- V's sync.stdatomic has no value
// type over every T Zebra allows (bool among them), and the LSP's uses are a
// flag and a counter. add and sub are comptime-guarded: a generic method is
// instantiated for every T the struct is, and bool has no +=.
@[heap]
pub struct ZAtomic[T] {
mut:
	mu sync.Mutex
	v  T
}

pub fn zatomic_new[T](zr_v T) &ZAtomic[T] {
	return &ZAtomic[T]{ v: zr_v }
}

pub fn (mut zr_a ZAtomic[T]) load() T {
	zr_a.mu.lock()
	defer { zr_a.mu.unlock() }
	return zr_a.v
}

pub fn (mut zr_a ZAtomic[T]) store(zr_v T) {
	zr_a.mu.lock()
	zr_a.v = zr_v
	zr_a.mu.unlock()
}

pub fn (mut zr_a ZAtomic[T]) swap(zr_v T) T {
	zr_a.mu.lock()
	defer { zr_a.mu.unlock() }
	zr_old := zr_a.v
	zr_a.v = zr_v
	return zr_old
}

pub fn (mut zr_a ZAtomic[T]) add(zr_d T) T {
	zr_a.mu.lock()
	defer { zr_a.mu.unlock() }
	$if T is bool {
		return zr_a.v
	} $else {
		zr_a.v += zr_d
		return zr_a.v
	}
}

pub fn (mut zr_a ZAtomic[T]) sub(zr_d T) T {
	zr_a.mu.lock()
	defer { zr_a.mu.unlock() }
	$if T is bool {
		return zr_a.v
	} $else {
		zr_a.v -= zr_d
		return zr_a.v
	}
}

pub fn (mut zr_a ZAtomic[T]) cas(zr_expected T, zr_desired T) bool {
	zr_a.mu.lock()
	defer { zr_a.mu.unlock() }
	if zr_a.v == zr_expected {
		zr_a.v = zr_desired
		return true
	}
	return false
}

// Zebra's Chan(T) is V's chan T; the receives keep Zebra's rule: queued
// messages first, none once the channel is closed and empty. (V's select on
// a closed channel fires its receive branch with a zero value, so the closed
// and empty case is checked first; a close that lands during the wait gives
// one zero value, which the next call reports as none.)
pub fn zchan_recv[T](zr_ch chan T) ?T {
	zr_x := <-zr_ch or { return none }
	return zr_x
}

pub fn zchan_try_recv[T](zr_ch chan T) ?T {
	if zr_ch.closed && zr_ch.len == 0 {
		return none
	}
	select {
		zr_x := <-zr_ch {
			return zr_x
		}
		else {
			return none
		}
	}
	return none
}

pub fn zchan_recv_timeout[T](zr_ch chan T, zr_secs f64) ?T {
	if zr_ch.closed && zr_ch.len == 0 {
		return none
	}
	select {
		zr_x := <-zr_ch {
			return zr_x
		}
		i64(zr_secs * 1000.0) * time.millisecond {
			return none
		}
	}
	return none
}

// sys.readBytes(n): exactly n bytes of stdin, none at an early end
pub fn zsys_read_bytes(zr_n i64) ?string {
	mut zr_buf := []u8{cap: int(zr_n)}
	for zr_buf.len < int(zr_n) {
		zr_c := C.getchar()
		if zr_c < 0 {
			return none
		}
		zr_buf << u8(zr_c)
	}
	return zr_buf.bytestr()
}

// sys.readStdinAvailable / sys.stdinClosed: the debugger bridge polls stdin
// without blocking. On Windows PeekNamedPipe on the stdin handle counts what
// a pipe holds (and fails on a closed pipe or a console: closed, as the Zig
// runtime reads it), ReadFile takes exactly that many bytes; elsewhere poll.
// These read the handle itself, not libc's buffer: a program that mixes them
// with readLine / readBytes on the same stdin would lose what libc had read
// ahead -- the bridge and the LSP each use one family.
// The header that defines pollfd, named so V emits no body of its own for
// the declaration below: a C-prefixed struct with no #include beside it is
// emitted as a definition (0.5.2 and master alike), and that definition
// redefines winsock2.h's the moment an import pulls the header in (net,
// db.sqlite, x.json) -- the whole game module refused to build for it.
$if windows {
	#include <winsock2.h>
} $else {
	#include <poll.h>
}

struct C.pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds &C.pollfd, nfds u64, timeout int) int

pub fn zsys_read_stdin_available() string {
	$if windows {
		zr_h := C.GetStdHandle(u32(0xfffffff6))   // STD_INPUT_HANDLE
		mut zr_avail := u32(0)
		if !C.PeekNamedPipe(zr_h, unsafe { nil }, 0, unsafe { nil }, &zr_avail, unsafe { nil }) || zr_avail == 0 {
			return ''
		}
		mut zr_buf := []u8{len: int(zr_avail)}
		mut zr_got := u32(0)
		if !C.ReadFile(zr_h, zr_buf.data, zr_avail, &zr_got, unsafe { nil }) || zr_got == 0 {
			return ''
		}
		return zr_buf[..int(zr_got)].bytestr()
	} $else {
		mut zr_pfd := C.pollfd{ fd: 0, events: 1, revents: 0 }   // POLLIN
		if C.poll(&zr_pfd, 1, 0) <= 0 || (zr_pfd.revents & 1) == 0 {
			return ''
		}
		mut zr_buf := []u8{len: 65536}
		zr_n := C.read(0, zr_buf.data, 65536)
		if zr_n <= 0 {
			return ''
		}
		return zr_buf[..zr_n].bytestr()
	}
}

pub fn zsys_stdin_closed() bool {
	$if windows {
		zr_h := C.GetStdHandle(u32(0xfffffff6))
		mut zr_avail := u32(0)
		return !C.PeekNamedPipe(zr_h, unsafe { nil }, 0, unsafe { nil }, &zr_avail, unsafe { nil })
	} $else {
		mut zr_pfd := C.pollfd{ fd: 0, events: 1, revents: 0 }
		if C.poll(&zr_pfd, 1, 0) <= 0 {
			return false
		}
		if (zr_pfd.revents & 1) != 0 {
			return false   // data first
		}
		return (zr_pfd.revents & (0x10 | 0x08 | 0x20)) != 0   // HUP, ERR, NVAL
	}
}

// == http begin ==
// Zebra's Http over V's net.http: a response (status, text) or none when the
// request could not be made (no route, a refused connection, a bad URL);
// the program reads the status itself. Inlined only when a program names it
// (the section's import with it), as the sqlite section is.
pub struct ZHttpResponse {
pub mut:
	status i64
	text   string
}

pub fn zhttp_get(zr_url string) ?ZHttpResponse {
	zr_r := http.get(zr_url) or { return none }
	return ZHttpResponse{ status: zr_r.status_code, text: zr_r.body }
}

pub fn zhttp_post(zr_url string, zr_body string) ?ZHttpResponse {
	zr_r := http.post(zr_url, zr_body) or { return none }
	return ZHttpResponse{ status: zr_r.status_code, text: zr_r.body }
}
// == http end ==

pub fn zunwrap[T](zr_x ?T) T {
	return zr_x or { zbr_panic('a nil unwrapped') }
}

// the same, naming the Zebra source place ("file.zbr:line") as the Zig
// side's runtime faults do (the engine's error overlay reads it)
pub fn zunwrap_at[T](zr_x ?T, zr_at string) T {
	return zr_x or { zbr_panic('nil unwrapped at ' + zr_at) }
}

// the compiler's own version string (`zig"_zbr_version"` on the Zig backend)
// Zebra's DateTime: the epoch milliseconds (the Zig backend's _DateTime)
pub struct ZDateTime {
pub:
	epoch_ms i64
}

pub fn zdatetime_now() ZDateTime {
	return ZDateTime{epoch_ms: time.now().unix_milli()}
}

// Zebra's tuples: (A, B) is ZTuple2[A, B], its elements f0 and f1 (`t.0` is `t.f0`)
pub struct ZTuple2[A, B] {
pub mut:
	f0 A
	f1 B
}

pub struct ZTuple3[A, B, D] {
pub mut:
	f0 A
	f1 B
	f2 D
}

pub const zbr_version = 'zebra (V backend, proof of concept)'

// a long `or` / `and` chain (V's checker gives up at forty nested levels);
// every term is evaluated: no short-circuit past thirty terms
pub fn zany(zr_xs []bool) bool {
	for zr_x in zr_xs {
		if zr_x {
			return true
		}
	}
	return false
}

pub fn zall(zr_xs []bool) bool {
	for zr_x in zr_xs {
		if !zr_x {
			return false
		}
	}
	return true
}

pub fn zsort_i64(mut zr_l ZList[i64]) {
	zr_l.items.sort()
}

pub fn zsort_f64(mut zr_l ZList[f64]) {
	zr_l.items.sort()
}

// a list sorted by a comparator or a key: stable insertion sorts (the Zig
// backend's std.mem.sort is stable, so ties keep their order on both)
pub fn zlist_sort_with[T](mut zr_l ZList[T], zr_less fn (T, T) bool) {
	for zr_i := 1; zr_i < zr_l.items.len; zr_i++ {
		for zr_j := zr_i; zr_j > 0 && zr_less(zr_l.items[zr_j], zr_l.items[zr_j - 1]); zr_j-- {
			zr_tmp := zr_l.items[zr_j]
			zr_l.items[zr_j] = zr_l.items[zr_j - 1]
			zr_l.items[zr_j - 1] = zr_tmp
		}
	}
}

pub fn zlist_sort_by_i64[T](mut zr_l ZList[T], zr_key fn (T) i64) {
	for zr_i := 1; zr_i < zr_l.items.len; zr_i++ {
		for zr_j := zr_i; zr_j > 0 && zr_key(zr_l.items[zr_j]) < zr_key(zr_l.items[zr_j - 1]); zr_j-- {
			zr_tmp := zr_l.items[zr_j]
			zr_l.items[zr_j] = zr_l.items[zr_j - 1]
			zr_l.items[zr_j - 1] = zr_tmp
		}
	}
}

pub fn zlist_sort_by_f64[T](mut zr_l ZList[T], zr_key fn (T) f64) {
	for zr_i := 1; zr_i < zr_l.items.len; zr_i++ {
		for zr_j := zr_i; zr_j > 0 && zr_key(zr_l.items[zr_j]) < zr_key(zr_l.items[zr_j - 1]); zr_j-- {
			zr_tmp := zr_l.items[zr_j]
			zr_l.items[zr_j] = zr_l.items[zr_j - 1]
			zr_l.items[zr_j - 1] = zr_tmp
		}
	}
}

pub fn zlist_sort_by_str[T](mut zr_l ZList[T], zr_key fn (T) string) {
	for zr_i := 1; zr_i < zr_l.items.len; zr_i++ {
		for zr_j := zr_i; zr_j > 0 && zr_key(zr_l.items[zr_j]) < zr_key(zr_l.items[zr_j - 1]); zr_j-- {
			zr_tmp := zr_l.items[zr_j]
			zr_l.items[zr_j] = zr_l.items[zr_j - 1]
			zr_l.items[zr_j - 1] = zr_tmp
		}
	}
}

pub fn zsort_str(mut zr_l ZList[string]) {
	zr_l.items.sort()
}

pub fn zlist_index_of[T](zr_l &ZList[T], zr_x T) i64 {
	for zr_i, it in zr_l.items {
		if it == zr_x {
			return i64(zr_i)
		}
	}
	return -1
}

pub fn zlist_remove[T](mut zr_l ZList[T], zr_x T) bool {
	zr_i := zlist_index_of(zr_l, zr_x)
	if zr_i < 0 {
		return false
	}
	zr_l.items.delete(int(zr_i))
	return true
}

pub fn zlist_reverse[T](zr_l &ZList[T]) &ZList[T] {
	return &ZList[T]{
		items: zr_l.items.reverse()
	}
}

pub fn zlist_contains[T](zr_l &ZList[T], zr_x T) bool {
	// (a loop rather than `x in l.items`: V 0.5.2's -g line map blamed the `in`
	// for a C error that was the generic insert's; a standalone `in` compiles)
	for it in zr_l.items {
		if it == zr_x {
			return true
		}
	}
	return false
}

// the list's own spellings, reached when the emitter knows the receiver is a list
// `xs.pop()`: the last element, removed, or a Zebra error on an empty list (the Zig side's
// _zbr_list_pop, BUG-545), so `xs.pop()?` propagates on both backends
pub fn (mut zr_l ZList[T]) pop() !T {
	if zr_l.items.len == 0 {
		return error('pop on an empty list')
	}
	return zr_l.items.pop()
}

pub fn (mut zr_l ZList[T]) remove_at(zr_i i64) {
	zr_l.items.delete(int(zr_i))
}

pub fn (zr_l &ZList[T]) reversed() &ZList[T] {
	return zlist_reverse(zr_l)
}

// ── str ────────────────────────────────────────────────────────────────────
// ── sys ───────────────────────────────────────────────────────────────────
pub struct ZRunResult {
pub mut:
	exit_code i64
	stdout    string
	stderr    string
}

// sys.run(argv): the program run to completion, its streams captured
pub fn zsys_run(zr_argv &ZList[string]) ZRunResult {
	if zr_argv.count() == 0 {
		return ZRunResult{ exit_code: -1, stderr: 'sys.run: no program named' }
	}
	mut zr_p := os.new_process(zr_argv.items[0])
	zr_p.set_args(zr_argv.items[1..].clone())
	zr_p.set_redirect_stdio()
	zr_p.run()
	zr_out := zr_p.stdout_slurp()
	zr_errs := zr_p.stderr_slurp()
	zr_p.wait()
	zr_code := zr_p.code
	zr_p.close()
	return ZRunResult{ exit_code: i64(zr_code), stdout: zr_out, stderr: zr_errs }
}

// ── sys.spawnPiped: a conversation with a child over its three pipes ──────
// The Zig preamble's _SysProcess: readAvailable / readErrAvailable drain what
// the pipe already holds without blocking (V's stdout_read peeks first), write
// is a blocking write of a small message, isRunning polls and reaps the exit
// code. closeStdin is the one method V's os.Process cannot do (no per-pipe
// close): it is accepted and said once, and a child waiting for EOF is ended
// by the caller's kill, as zebra-ide's transport does after a short wait.
@[heap]
pub struct ZSysProcess {
pub mut:
	p         &os.Process = unsafe { nil }
	alive     bool
	exit_code i64 = -1 // -1 until the child has been seen to exit
	close_said bool // closeStdin said once per process (a __global would need -enable-globals of every program)
}

pub fn zsys_spawn_piped(zr_argv &ZList[string]) &ZSysProcess {
	return zsys_spawn_piped_in(zr_argv, '')
}

// cwd == '' inherits the parent's directory, else the child starts there
pub fn zsys_spawn_piped_in(zr_argv &ZList[string], zr_cwd string) &ZSysProcess {
	mut zr_r := &ZSysProcess{}
	if zr_argv.count() == 0 {
		return zr_r
	}
	// resolved first: V's os.Process on Windows ends the whole program on a
	// CreateProcess failure ("failed CreateProcess", exit 1), where Zebra's
	// contract is a process that is not running (isRunning false, exitCode -1)
	zr_prog := zsys_resolve_program(zr_argv.items[0])
	if zr_prog == '' {
		return zr_r
	}
	mut zr_p := os.new_process(zr_prog)
	zr_p.set_args(zr_argv.items[1..].clone())
	if zr_cwd != '' {
		zr_p.set_work_folder(zr_cwd)
	}
	zr_p.set_redirect_stdio()
	zr_p.run()
	zr_r.p = zr_p
	zr_r.alive = zr_p.err == '' && zr_p.status == .running
	return zr_r
}

// a bare name through PATH (with .exe on Windows when the name has no
// extension), a path by its existence; '' when nothing is there
fn zsys_resolve_program(zr_name string) string {
	if zr_name.contains('/') || zr_name.contains('\\') {
		if os.exists(zr_name) {
			return zr_name
		}
		$if windows {
			if !zr_name.to_lower().ends_with('.exe') && os.exists(zr_name + '.exe') {
				return zr_name + '.exe'
			}
		}
		return ''
	}
	zr_found := os.find_abs_path_of_executable(zr_name) or { '' }
	if zr_found != '' {
		return zr_found
	}
	$if windows {
		if !zr_name.to_lower().ends_with('.exe') {
			return os.find_abs_path_of_executable(zr_name + '.exe') or { '' }
		}
	}
	return ''
}

pub fn (mut zr_r ZSysProcess) is_running() bool {
	if !zr_r.alive {
		return false
	}
	if zr_r.p.is_alive() {
		return true
	}
	zr_r.alive = false
	// is_alive only looks; wait() fills p.code and closes the child's ends of
	// the pipes (the parent's read ends stay: what the child wrote is still there)
	zr_r.p.wait()
	zr_r.exit_code = i64(zr_r.p.code)
	return false
}

pub fn (mut zr_r ZSysProcess) alive() bool {
	return zr_r.is_running()
}

pub fn (mut zr_r ZSysProcess) kill() {
	if !zr_r.alive {
		return
	}
	zr_r.p.signal_kill()
	zr_r.alive = false
}

pub fn (mut zr_r ZSysProcess) write(zr_data string) bool {
	if !zr_r.alive {
		return false
	}
	zr_r.p.stdin_write(zr_data)
	return true
}

// whatever stdout already holds (a few blocks at most per call), '' when nothing is pending
pub fn (mut zr_r ZSysProcess) read_available() string {
	if zr_r.p == unsafe { nil } {
		return ''
	}
	mut zr_out := ''
	for zr_i := 0; zr_i < 4; zr_i++ {
		zr_c := zr_r.p.stdout_read()
		if zr_c == '' {
			break
		}
		zr_out += zr_c
	}
	return zr_out
}

pub fn (mut zr_r ZSysProcess) read_err_available() string {
	if zr_r.p == unsafe { nil } {
		return ''
	}
	mut zr_out := ''
	for zr_i := 0; zr_i < 4; zr_i++ {
		zr_c := zr_r.p.stderr_read()
		if zr_c == '' {
			break
		}
		zr_out += zr_c
	}
	return zr_out
}

pub fn (mut zr_r ZSysProcess) close_stdin() {
	if !zr_r.close_said {
		eprintln('zebra: closeStdin is accepted and not acted on by the V runtime (os.Process has no per-pipe close): a child waiting for EOF is ended by kill')
		zr_r.close_said = true
	}
}

pub fn (mut zr_r ZSysProcess) exit_code() i64 {
	if zr_r.alive {
		zr_r.is_running()
	}
	return zr_r.exit_code
}

// Dir.walk(root): every file under root, recursively, as root/relative with
// forward slashes (the Zig backend's shape); dotfiles included, as its walker.
// Built as zfile_list_dir builds its list, not through zlist_of: a second
// zlist_of[string] call site here made V 0.5.2 generate that instantiation's
// body converting the items to json2.Any, and every program's string-list
// literal read as garbage (2026-10-15; a generic miscompile, to be reported).
pub fn zdir_walk(zr_root string) &ZList[string] {
	mut zr_out := os.walk_ext(zr_root, '', hidden: true)
	for zr_i in 0 .. zr_out.len {
		zr_out[zr_i] = zr_out[zr_i].replace('\\', '/')
	}
	return &ZList[string]{
		items: zr_out
	}
}

// ── Timer: the Zig preamble's TimerHandle (Timer.start(), elapsed ms as f64,
// elapsedMicros, reset) ──────────────────────────────────────────────────────
pub struct ZTimer {
pub mut:
	started time.Time
}

pub fn ztimer_start() ZTimer {
	return ZTimer{ started: time.now() }
}

// milliseconds, as the Zig preamble's elapsed()
pub fn (zr_t ZTimer) elapsed() f64 {
	return f64(time.since(zr_t.started).microseconds()) / 1000.0
}

pub fn (zr_t ZTimer) elapsed_micros() i64 {
	return time.since(zr_t.started).microseconds()
}

pub fn (mut zr_t ZTimer) reset() {
	zr_t.started = time.now()
}

// ── Json: Zebra's Json / JsonValue is json2.Any by value ──────────────────
pub fn zjson_parse(zr_s string) ?json2.Any {
	zr_j := json2.decode[json2.Any](zr_s) or { return none }
	return zjson_fix_keys(zr_j)
}

// V 0.5.2's decoder leaves a key's escape sequences in the key (a key
// `Iron \"Spear\"` reads back with its backslashes, and encodes doubled);
// master decodes them. Every object's keys unescaped after a decode, the
// values walked; a key without a backslash is untouched.
fn zjson_fix_keys(zr_j json2.Any) json2.Any {
	if zr_j is map[string]json2.Any {
		zr_old := zr_j as map[string]json2.Any
		mut zr_out := map[string]json2.Any{}
		for zr_k, zr_v in zr_old {
			zr_kk := if zr_k.contains('\\') { zjson_unescape(zr_k) } else { zr_k }
			zr_out[zr_kk] = zjson_fix_keys(zr_v)
		}
		return json2.Any(zr_out)
	}
	if zr_j is []json2.Any {
		zr_old := zr_j as []json2.Any
		mut zr_out := []json2.Any{cap: zr_old.len}
		for zr_v in zr_old {
			zr_out << zjson_fix_keys(zr_v)
		}
		return json2.Any(zr_out)
	}
	return zr_j
}

fn zjson_unescape(zr_s string) string {
	mut zr_b := []u8{cap: zr_s.len}
	mut zr_i := 0
	for zr_i < zr_s.len {
		zr_c := zr_s[zr_i]
		if zr_c == `\\` && zr_i + 1 < zr_s.len {
			zr_n := zr_s[zr_i + 1]
			match zr_n {
				`"` { zr_b << u8(`"`) }
				`\\` { zr_b << u8(`\\`) }
				`/` { zr_b << u8(`/`) }
				`b` { zr_b << u8(8) }
				`f` { zr_b << u8(12) }
				`n` { zr_b << u8(`\n`) }
				`r` { zr_b << u8(`\r`) }
				`t` { zr_b << u8(`\t`) }
				`u` {
					if zr_i + 5 < zr_s.len {
						zr_cp := strconv.parse_int(zr_s[zr_i + 2..zr_i + 6], 16, 32) or { 0 }
						zr_b << utf32_to_str(u32(zr_cp)).bytes()
						zr_i += 4
					}
				}
				else {
					zr_b << u8(zr_c)
					zr_b << u8(zr_n)
				}
			}
			zr_i += 2
			continue
		}
		zr_b << u8(zr_c)
		zr_i++
	}
	return zr_b.bytestr()
}

pub fn zjson_object() json2.Any {
	return json2.Any(map[string]json2.Any{})
}

pub fn zjson_array() json2.Any {
	return json2.Any([]json2.Any{})
}

pub fn zjson_get(zr_j json2.Any, zr_k string) ?json2.Any {
	if zr_j is map[string]json2.Any {
		zr_m := zr_j as map[string]json2.Any
		return zr_m[zr_k] or { return none }
	}
	return none
}

pub fn zjson_has(zr_j json2.Any, zr_k string) bool {
	if zr_j is map[string]json2.Any {
		zr_m := zr_j as map[string]json2.Any
		return zr_k in zr_m
	}
	return false
}

pub fn zjson_try_str(zr_j json2.Any) ?string {
	if zr_j is string {
		return zr_j as string
	}
	return none
}

fn zjson_is_number(zr_j json2.Any) bool {
	if zr_j is string || zr_j is bool || zr_j is json2.Null || zr_j is []json2.Any || zr_j is map[string]json2.Any {
		return false
	}
	return true
}

// a whole number only: json2 parses every number as f64, and a fraction
// is not an int (the Zig backend's _json_as_int is null for 1.6)
pub fn zjson_try_int(zr_j json2.Any) ?i64 {
	if zr_j is f64 {
		zr_f := zr_j as f64
		if math.floor(zr_f) == zr_f && zr_f >= -9.2233720368547758e18 && zr_f < 9.2233720368547758e18 {
			return i64(zr_f)
		}
		return none
	}
	if zjson_is_number(zr_j) {
		return zr_j.i64()
	}
	return none
}

pub fn zjson_try_float(zr_j json2.Any) ?f64 {
	if zjson_is_number(zr_j) {
		return zr_j.f64()
	}
	return none
}

pub fn zjson_try_bool(zr_j json2.Any) ?bool {
	if zr_j is bool {
		return zr_j as bool
	}
	return none
}

pub fn zjson_try_obj(zr_j json2.Any) ?json2.Any {
	if zr_j is map[string]json2.Any {
		return zr_j
	}
	return none
}

pub fn zjson_try_list(zr_j json2.Any) ?&ZList[json2.Any] {
	if zr_j is []json2.Any {
		return zlist_of[json2.Any](zr_j as []json2.Any)
	}
	return none
}

// `v.tryX(key)`: the member as X when v is an object with the key, else none
// (Zebra's _json_try_X beside the bare _json_self_X)
pub fn zjson_tryk_str(zr_j json2.Any, zr_k string) ?string {
	zr_m := zjson_get(zr_j, zr_k) or { return none }
	return zjson_try_str(zr_m)
}

pub fn zjson_tryk_int(zr_j json2.Any, zr_k string) ?i64 {
	zr_m := zjson_get(zr_j, zr_k) or { return none }
	return zjson_try_int(zr_m)
}

pub fn zjson_tryk_float(zr_j json2.Any, zr_k string) ?f64 {
	zr_m := zjson_get(zr_j, zr_k) or { return none }
	return zjson_try_float(zr_m)
}

pub fn zjson_tryk_bool(zr_j json2.Any, zr_k string) ?bool {
	zr_m := zjson_get(zr_j, zr_k) or { return none }
	return zjson_try_bool(zr_m)
}

pub fn zjson_tryk_obj(zr_j json2.Any, zr_k string) ?json2.Any {
	zr_m := zjson_get(zr_j, zr_k) or { return none }
	return zjson_try_obj(zr_m)
}

pub fn zjson_tryk_list(zr_j json2.Any, zr_k string) ?&ZList[json2.Any] {
	zr_m := zjson_get(zr_j, zr_k) or { return none }
	return zjson_try_list(zr_m)
}

// `j[key]?`: the member, or an error (Zebra's _json_idx)
pub fn zjson_idx(zr_j json2.Any, zr_k string) !json2.Any {
	if zr_j is map[string]json2.Any {
		zr_m := zr_j as map[string]json2.Any
		return zr_m[zr_k] or { return error('json: no key ' + zr_k) }
	}
	return error('json: not an object, indexed by ' + zr_k)
}

// `arr[i]?`: the element, or an error
pub fn zjson_idx_at(zr_j json2.Any, zr_i i64) !json2.Any {
	if zr_j is []json2.Any {
		zr_a := zr_j as []json2.Any
		if zr_i < 0 || zr_i >= zr_a.len {
			return error('json: index ${zr_i} of ${zr_a.len}')
		}
		return zr_a[int(zr_i)]
	}
	return error('json: not an array, indexed by ${zr_i}')
}

// a Json value received as a str: the string itself, else its JSON text
pub fn zjson_str(zr_j json2.Any) string {
	if zr_j is string {
		return zr_j as string
	}
	return zr_j.json_str()
}

// `for x in j`: the array's elements (none for anything else)
pub fn zjson_list(zr_j json2.Any) &ZList[json2.Any] {
	if zr_j is []json2.Any {
		return zlist_of[json2.Any](zr_j as []json2.Any)
	}
	return new_zlist[json2.Any]()
}

pub fn zjson_keys(zr_j json2.Any) &ZList[string] {
	if zr_j is map[string]json2.Any {
		zr_m := zr_j as map[string]json2.Any
		return zlist_of[string](zr_m.keys())
	}
	return new_zlist[string]()
}

pub fn zjson_values(zr_j json2.Any) &ZList[json2.Any] {
	if zr_j is map[string]json2.Any {
		zr_m := zr_j as map[string]json2.Any
		return zlist_of[json2.Any](zr_m.values())
	}
	return new_zlist[json2.Any]()
}

pub fn zjson_is_null(zr_j json2.Any) bool {
	return zr_j is json2.Null
}

pub fn zjson_is_object(zr_j json2.Any) bool {
	return zr_j is map[string]json2.Any
}

pub fn zjson_is_array(zr_j json2.Any) bool {
	return zr_j is []json2.Any
}

// the put / append family returns the new value: the emitter writes
// `j = zjson_put(j, k, v)` for Zebra's `j.put(k, v)` (a sum type cannot be
// a mut parameter), which keeps the value semantics of Zig's std.json.Value
pub fn zjson_put(zr_j json2.Any, zr_k string, zr_v json2.Any) json2.Any {
	mut zr_m := map[string]json2.Any{}
	if zr_j is map[string]json2.Any {
		zr_m = (zr_j as map[string]json2.Any).clone()
	}
	zr_m[zr_k] = zr_v
	return json2.Any(zr_m)
}

pub fn zjson_put_str(zr_j json2.Any, zr_k string, zr_v string) json2.Any {
	return zjson_put(zr_j, zr_k, json2.Any(zr_v))
}

pub fn zjson_put_int(zr_j json2.Any, zr_k string, zr_v i64) json2.Any {
	return zjson_put(zr_j, zr_k, json2.Any(zr_v))
}

pub fn zjson_put_float(zr_j json2.Any, zr_k string, zr_v f64) json2.Any {
	return zjson_put(zr_j, zr_k, json2.Any(zr_v))
}

pub fn zjson_put_bool(zr_j json2.Any, zr_k string, zr_v bool) json2.Any {
	return zjson_put(zr_j, zr_k, json2.Any(zr_v))
}

pub fn zjson_append(zr_j json2.Any, zr_v json2.Any) json2.Any {
	mut zr_a := []json2.Any{}
	if zr_j is []json2.Any {
		zr_a = (zr_j as []json2.Any).clone()
	}
	zr_a << zr_v
	return json2.Any(zr_a)
}

pub fn zjson_append_str(zr_j json2.Any, zr_v string) json2.Any {
	return zjson_append(zr_j, json2.Any(zr_v))
}

pub fn zjson_append_int(zr_j json2.Any, zr_v i64) json2.Any {
	return zjson_append(zr_j, json2.Any(zr_v))
}

pub fn zjson_append_float(zr_j json2.Any, zr_v f64) json2.Any {
	return zjson_append(zr_j, json2.Any(zr_v))
}

pub fn zjson_append_bool(zr_j json2.Any, zr_v bool) json2.Any {
	return zjson_append(zr_j, json2.Any(zr_v))
}

// ── Random: a seeded generator (xoshiro256++, seeded by splitmix64 as Zig's
// DefaultPrng is; the range reduction is not Zig's, so a sequence here is
// not the Zig backend's -- a known divergence, said in the note) ─────────
@[heap]
pub struct ZRandom {
pub mut:
	s [4]u64
}

pub fn zrandom_new(zr_seed i64) &ZRandom {
	mut zr_r := &ZRandom{}
	mut zr_x := u64(zr_seed)
	for zr_i in 0 .. 4 {
		zr_x += u64(0x9E3779B97F4A7C15)
		mut zr_z := zr_x
		zr_z = (zr_z ^ (zr_z >> 30)) * u64(0xBF58476D1CE4E5B9)
		zr_z = (zr_z ^ (zr_z >> 27)) * u64(0x94D049BB133111EB)
		zr_r.s[zr_i] = zr_z ^ (zr_z >> 31)
	}
	return zr_r
}

fn zrotl(zr_x u64, zr_k int) u64 {
	return (zr_x << zr_k) | (zr_x >> (64 - zr_k))
}

pub fn (mut zr_r ZRandom) next_u64() u64 {
	zr_result := zrotl(zr_r.s[0] + zr_r.s[3], 23) + zr_r.s[0]
	zr_t := zr_r.s[1] << 17
	zr_r.s[2] ^= zr_r.s[0]
	zr_r.s[3] ^= zr_r.s[1]
	zr_r.s[1] ^= zr_r.s[2]
	zr_r.s[0] ^= zr_r.s[3]
	zr_r.s[2] ^= zr_t
	zr_r.s[3] = zrotl(zr_r.s[3], 45)
	return zr_result
}

// a 64 x 64 -> 128 product as (high, low): V has no u128
fn zmul_wide(zr_a u64, zr_b u64) (u64, u64) {
	zr_a_lo := zr_a & 0xFFFFFFFF
	zr_a_hi := zr_a >> 32
	zr_b_lo := zr_b & 0xFFFFFFFF
	zr_b_hi := zr_b >> 32
	zr_p0 := zr_a_lo * zr_b_lo
	zr_p1 := zr_a_lo * zr_b_hi
	zr_p2 := zr_a_hi * zr_b_lo
	zr_p3 := zr_a_hi * zr_b_hi
	zr_mid := (zr_p0 >> 32) + (zr_p1 & 0xFFFFFFFF) + (zr_p2 & 0xFFFFFFFF)
	zr_lo := (zr_p0 & 0xFFFFFFFF) | (zr_mid << 32)
	zr_hi := zr_p3 + (zr_p1 >> 32) + (zr_p2 >> 32) + (zr_mid >> 32)
	return zr_hi, zr_lo
}

// Zig's std.Random.uintLessThan(u64, n): Lemire's multiply-shift with
// rejection -- the same draws in the same order as the Zig backend
fn (mut zr_r ZRandom) uint_less_than(zr_less_than u64) u64 {
	mut zr_x := zr_r.next_u64()
	mut zr_hi, mut zr_l := zmul_wide(zr_x, zr_less_than)
	if zr_l < zr_less_than {
		mut zr_t := (~zr_less_than) + 1   // -less_than, wrapping
		if zr_t >= zr_less_than {
			zr_t -= zr_less_than
			if zr_t >= zr_less_than {
				zr_t %= zr_less_than
			}
		}
		for zr_l < zr_t {
			zr_x = zr_r.next_u64()
			zr_hi, zr_l = zmul_wide(zr_x, zr_less_than)
		}
	}
	return zr_hi
}

// Random.nextInt(lo, hi): inclusive both ends -- Zig's intRangeAtMost(i64):
// lo +% uintAtMost(u64, hi -% lo); a draw is consumed even for lo == hi
pub fn (mut zr_r ZRandom) next_int(zr_lo i64, zr_hi i64) i64 {
	zr_ulo := u64(zr_lo)
	zr_uhi := u64(zr_hi)
	zr_span := zr_uhi - zr_ulo
	mut zr_res := u64(0)
	if zr_span == u64(0xFFFFFFFFFFFFFFFF) {
		zr_res = zr_r.next_u64()
	} else {
		zr_res = zr_r.uint_less_than(zr_span + 1)
	}
	return i64(zr_ulo + zr_res)
}

// Zig's float(f64): the leading zeros of a draw are the exponent (twelve
// or more: further draws), the low 52 bits the mantissa
pub fn (mut zr_r ZRandom) next_float() f64 {
	zr_draw := zr_r.next_u64()
	mut zr_rand_lz := u64(bits.leading_zeros_64(zr_draw))
	if zr_rand_lz >= 12 {
		zr_rand_lz = 12
		for {
			zr_addl := u64(bits.leading_zeros_64(zr_r.next_u64()))
			zr_rand_lz += zr_addl
			if zr_addl != 64 {
				break
			}
			if zr_rand_lz >= 1022 {
				zr_rand_lz = 1022
				break
			}
		}
	}
	zr_mantissa := zr_draw & u64(0xFFFFFFFFFFFFF)
	zr_exponent := (u64(1022) - zr_rand_lz) << 52
	return bits.f64_from_bits(zr_exponent | zr_mantissa)
}

// == sqlite begin ==
// Zebra's SqliteDb / SqliteRow on V's db.sqlite (the vendored amalgamation in
// V's thirdparty/sqlite, the same sqlite3.c the Zig backend links). This
// section is inlined, and db.sqlite imported, only into a program that
// uses them (the emitter checks the body for these names).
@[heap]
pub struct ZSqliteDb {
pub mut:
	path string
	db   sqlite.DB
}

@[heap]
pub struct ZSqliteRow {
pub mut:
	cols map[string]string
}

pub fn zsqlite_open(zr_path string) ?&ZSqliteDb {
	zr_db := sqlite.connect(zr_path) or { return none }
	return &ZSqliteDb{
		path: zr_path
		db:   zr_db
	}
}

fn zsqlite_params(zr_params &ZList[string]) []string {
	mut zr_out := []string{}
	for zr_p in zr_params.items {
		zr_out << zr_p
	}
	return zr_out
}

// exec(sql, params): the statement run with its `?` parameters; a failure
// is the program's fault and says the statement
pub fn (mut zr_d ZSqliteDb) exec(zr_sql_text string, zr_params &ZList[string]) {
	zr_d.db.exec_param_many(zr_sql_text, zsqlite_params(zr_params)) or { zbr_panic('sqlite exec: ' + err.msg() + ' -- ' + zr_sql_text) }
}

// query(sql, params): the rows, each its columns by name
pub fn (mut zr_d ZSqliteDb) query(zr_sql_text string, zr_params &ZList[string]) &ZList[&ZSqliteRow] {
	mut zr_out := new_zlist[&ZSqliteRow]()
	zr_rows := zr_d.db.exec_param_many(zr_sql_text, zsqlite_params(zr_params)) or { zbr_panic('sqlite query: ' + err.msg() + ' -- ' + zr_sql_text) }
	for zr_r in zr_rows {
		mut zr_cols := map[string]string{}
		for zr_i, zr_name in zr_r.names {
			if zr_i < zr_r.vals.len {
				zr_cols[zr_name] = zr_r.vals[zr_i]
			}
		}
		zr_out.add(&ZSqliteRow{
			cols: zr_cols
		})
	}
	return zr_out
}

pub fn (mut zr_d ZSqliteDb) close() {
	zr_d.db.close() or {}
}

pub fn (zr_r &ZSqliteRow) as_int(zr_col string) i64 {
	return (zr_r.cols[zr_col] or { '0' }).i64()
}

pub fn (zr_r &ZSqliteRow) as_str(zr_col string) string {
	return zr_r.cols[zr_col] or { '' }
}

pub fn (zr_r &ZSqliteRow) as_float(zr_col string) f64 {
	return (zr_r.cols[zr_col] or { '0' }).f64()
}

pub fn (zr_r &ZSqliteRow) as_bool(zr_col string) bool {
	zr_v := zr_r.cols[zr_col] or { '0' }
	return zr_v == '1' || zr_v == 'true'
}
// == sqlite end ==

// ── Random, Hash, Http ────────────────────────────────────────────────────
pub fn zrandom_int(zr_lo i64, zr_hi i64) i64 {
	return rand.i64_in_range(zr_lo, zr_hi + 1) or { zr_lo }
}

pub fn zhash_sha256(zr_s string) string {
	return sha256.hexhash(zr_s)
}

// ── Arg: the builtin argument parser (the Zig preamble's ArgResult) ────────
pub struct ZArgs {
pub mut:
	raw []string
}

pub fn zarg_parse() ZArgs {
	if os.args.len > 1 {
		return ZArgs{ raw: os.args[1..].clone() }
	}
	return ZArgs{}
}

pub fn (zr_a ZArgs) flag(zr_long string, zr_short string) bool {
	for zr_x in zr_a.raw {
		if zr_x == zr_long || zr_x == zr_short {
			return true
		}
	}
	return false
}

pub fn (zr_a ZArgs) contains(zr_name string) bool {
	for zr_x in zr_a.raw {
		if zr_x == zr_name {
			return true
		}
	}
	return false
}

pub fn (zr_a ZArgs) option(zr_name string, zr_default_val string) string {
	for zr_x in zr_a.raw {
		if zr_x.starts_with(zr_name) && zr_x.len > zr_name.len && zr_x[zr_name.len] == `=` {
			return zr_x[zr_name.len + 1..]
		}
	}
	for zr_i := 0; zr_i + 1 < zr_a.raw.len; zr_i++ {
		if zr_a.raw[zr_i] == zr_name {
			return zr_a.raw[zr_i + 1]
		}
	}
	return zr_default_val
}

pub fn (zr_a ZArgs) option_int(zr_name string, zr_default_val i64) i64 {
	zr_s := zr_a.option(zr_name, '')
	if zr_s.len == 0 {
		return zr_default_val
	}
	return strconv.parse_int(zr_s, 10, 64) or { zr_default_val }
}

pub fn (zr_a ZArgs) unknown_flag(zr_known string) string {
	for zr_x in zr_a.raw {
		if zr_x.len < 2 || zr_x[0] != `-` {
			continue
		}
		if zr_x == '--' {
			break
		}
		zr_name := if eq := zr_x.index('=') { zr_x[..eq] } else { zr_x }
		mut zr_found := false
		for zr_k in zr_known.split(' ') {
			if zr_k == zr_name {
				zr_found = true
				break
			}
		}
		if !zr_found {
			return zr_x
		}
	}
	return ''
}

pub fn (zr_a ZArgs) positional(zr_idx i64) ?string {
	mut zr_pos := i64(0)
	for zr_x in zr_a.raw {
		if !zr_x.starts_with('-') {
			if zr_pos == zr_idx {
				return zr_x
			}
			zr_pos += 1
		}
	}
	return none
}

pub fn (zr_a ZArgs) usage() string {
	return 'Usage: program [options]'
}

pub fn zdir_try_delete_all(zr_path string) bool {
	os.rmdir_all(zr_path) or { return false }
	return true
}

pub fn zfile_try_delete(zr_path string) bool {
	os.rm(zr_path) or { return false }
	return true
}

// sys.readLine: a line without its newline, none at the end of input
// one stdin path for readLine and readBytes: libc's stdin through getchar,
// so both read one buffer (os.get_raw_line and os.stdin().read_bytes read
// through different ones, and the LSP's second message vanished between
// them, 2026-10-20); the Zig side reads one buffered reader for both
fn C.getchar() int

pub fn zsys_readline() ?string {
	mut zr_buf := []u8{}
	for {
		zr_c := C.getchar()
		if zr_c < 0 {
			if zr_buf.len == 0 {
				return none
			}
			break
		}
		if zr_c == 10 {
			break
		}
		zr_buf << u8(zr_c)
	}
	return zr_buf.bytestr().trim_right('\r')
}

// sys.exec_inherit(argv): run with the parent's stdio; the exit code
// (os.new_process, not os.system: master deprecates the latter and -prod
// makes the deprecation an error)
pub fn zsys_exec_inherit(zr_argv &ZList[string]) i64 {
	if zr_argv.items.len == 0 {
		return 1
	}
	mut zr_p := os.new_process(zr_argv.items[0])
	zr_p.set_args(zr_argv.items[1..].clone())
	zr_p.run()
	zr_p.wait()
	zr_code := zr_p.code
	zr_p.close()
	return i64(zr_code)
}

// Dir.list(path): the entries' names
pub fn zdir_list(zr_path string) &ZList[string] {
	return zlist_of[string](os.ls(zr_path) or { []string{} })
}

// the CPU architecture's name as Zig's builtin.target.cpu.arch spells it
pub fn zsys_arch() string {
	$if x64 {
		return 'x86_64'
	} $else $if arm64 {
		return 'aarch64'
	} $else $if x32 {
		return 'x86'
	} $else {
		return 'unknown'
	}
}

pub fn zstr_is_numeric(zr_s string) bool {
	if zr_s.len == 0 {
		return false
	}
	for zr_c in zr_s {
		if zr_c < `0` || zr_c > `9` {
			return false
		}
	}
	return true
}

pub fn zstr_last_index_of(zr_s string, zr_sub string) i64 {
	return i64(zr_s.last_index(zr_sub) or { -1 })
}

pub fn zstr_try_int(zr_s string) ?i64 {
	return strconv.parse_int(zr_s, 10, 64) or { return none }
}

pub fn zstr_try_float(zr_s string) ?f64 {
	return strconv.atof64(zr_s) or { return none }
}

pub fn zstr_char_at(zr_s string, zr_i i64) string {
	return zr_s[int(zr_i)..int(zr_i + 1)]   // int bounds: an i64 bound panics in range under MSVC, with or without -prod (vlang/v#30352)
}

pub fn zstr_split(zr_s string, zr_sep string) &ZList[string] {
	return &ZList[string]{
		items: zr_s.split(zr_sep)
	}
}

pub fn zstr_lines(zr_s string) &ZList[string] {
	return &ZList[string]{
		items: zr_s.split_into_lines()
	}
}

pub fn zstr_pad_left(zr_s string, zr_width i64, zr_pad string) string {
	mut zr_out := zr_s
	for i64(zr_out.len) < zr_width {
		zr_out = zr_pad + zr_out
	}
	return zr_out
}

pub fn zstr_pad_right(zr_s string, zr_width i64, zr_pad string) string {
	mut zr_out := zr_s
	for i64(zr_out.len) < zr_width {
		zr_out = zr_out + zr_pad
	}
	return zr_out
}

pub fn zstr_index_of(zr_s string, zr_sub string) i64 {
	return i64(zr_s.index(zr_sub) or { return -1 })
}

// ── Math ───────────────────────────────────────────────────────────────────
pub fn zmath_clamp(zr_x f64, zr_lo f64, zr_hi f64) f64 {
	return math.min(math.max(zr_x, zr_lo), zr_hi)
}

pub fn zmath_round(zr_x f64) f64 {
	return math.round(zr_x)
}

// ── File / Path (over V's os) ──────────────────────────────────────────────
pub fn zfile_exists(zr_p string) bool {
	return os.exists(zr_p)
}

pub fn zfile_read(zr_p string) string {
	return os.read_file(zr_p) or { '' }
}

pub fn zfile_write(zr_p string, zr_text string) {
	os.write_file(zr_p, zr_text) or { eprintln('zebra: File.write ${zr_p}: ${err}') }
}

pub fn zfile_append(zr_p string, zr_text string) {
	mut zr_f := os.open_append(zr_p) or {
		eprintln('zebra: File.append ${zr_p}: ${err}')
		return
	}
	zr_f.write_string(zr_text) or { eprintln('zebra: File.append ${zr_p}: ${err}') }
	zr_f.close()
}

pub fn zfile_list_dir(zr_p string) &ZList[string] {
	return &ZList[string]{
		items: os.ls(zr_p) or { []string{} }
	}
}

pub fn zpath_dirname(zr_p string) string {
	return os.dir(zr_p)
}

pub fn zpath_basename(zr_p string) string {
	return os.base(zr_p)
}

pub fn zpath_stem(zr_p string) string {
	return os.file_name(zr_p).all_before_last('.')
}

pub fn zpath_join(zr_a string, zr_b string) string {
	return os.join_path(zr_a, zr_b)
}

// Every panic the runtime or an emitted program raises (an assert, a raise nothing catches,
// a nil unwrapped, a map fetch of a missing key, a sqlite failure) comes through here. A host
// built with `-d zbr_panic_hook` defines `zbr_host_panic(msg string)` in module main and hears
// it first (the engine's V host: the message to saves/last_panic.txt and the clipboard, the
// window held on a red strip, exit 3 -- its Zig host's root panic handler); without the define
// the branch is not compiled and V's own panic runs, as before 2026-10-21.
@[noreturn]
fn zbr_panic(zr_msg string) {
	$if zbr_panic_hook ? {
		zbr_host_panic(zr_msg)
	}
	panic(zr_msg)
}

// -- zfmt_f: an interpolation of floats as one formatted write (2026-10-23) --
// The emitter takes this path when every hole of an interpolation is a float with an explicit
// one-digit precision (`${x:.4f}`) and there are at most twelve: the printf-shaped format is built
// at emit time (the literal parts with `%` doubled, each hole its `%.Nf`), the values come as one
// array, and the whole string is formatted hole by hole into a stack buffer and copied once. V's
// own interpolation (str_intp) makes a heap string per formatted value: the engine's GUI commands,
// ten floats each and two hundred a frame, cost 30 MB a window that way (the memory-model note,
// §6a). A string the buffer cannot hold is formatted again into a heap buffer of its size.
//
// The spelling is the Zig backend's (std.fmt's `{d:.N}`: the shortest round-trip digits, rounded
// half away from zero at N places; nan, -nan, inf, -inf), not the C library's: C's `%.Nf` rounds
// the exact binary value, so the two differ exactly when the shortest digits end in a 5 at place
// N+1 and the binary value lies below that tie (2.675 is 2.67499...: Zig 2.68, C 2.67), and
// msvcrt spells inf as "1.$". The rule: format at N+1 places; when the last digit is 5 and that
// decimal parses back to x, it IS the shortest digits' tie and the N-place prefix is rounded up by
// hand; else `%.Nf` is Zig's answer too. Exact while ulp(x) < 10^-(N+1), i.e. |x| < 2^52 / 10^(N+1)
// (zfmt_bounds); beyond that the C library's digits (Zig pads the shortest digits with zeros
// there). V's own `${x:.Nf}` is a third spelling (2.67, +inf, -+inf, and "10" for 1e16 at .0f on
// 0.5.2), which is why the emitter routes every fixed-precision float hole through zfmt_one, in
// a mixed interpolation too (one allocation per hole there, as before, but Zig's digits).
//
// Every local and parameter here is prefixed zf_: this file is compiled into the same module as
// the emitted program, and a local that shares a name with one of the program's module consts
// miscompiles silently under V 0.5.2 (an engine module has a const `tmp`; 2026-10-26).
fn C.snprintf(buf &char, n usize, fmt &char, ...) int

const zfmt_specs = ['%.0f', '%.1f', '%.2f', '%.3f', '%.4f', '%.5f', '%.6f', '%.7f', '%.8f', '%.9f', '%.10f']
const zfmt_bounds = [450359962737049.6, 45035996273704.96, 4503599627370.496, 450359962737.0496, 45035996273.70496, 4503599627.370496, 450359962.7370496, 45035996.27370496, 4503599.627370496, 450359.9627370496]

pub fn zfmt_f(zf_fmt string, zf_v []f64) string {
	mut zf_buf := [1024]u8{}
	zf_n := zfmt_into(unsafe { &zf_buf[0] }, 1024, zf_fmt, zf_v)
	if zf_n < 1024 {
		return unsafe { tos_clone(&zf_buf[0]) }
	}
	zf_big := []u8{len: zf_n + 1}
	zfmt_into(&u8(zf_big.data), zf_n + 1, zf_fmt, zf_v)
	return unsafe { tos_clone(&u8(zf_big.data)) }
}

// one float at a precision, as a string (the mixed interpolation's hole)
pub fn zfmt_one(zf_x f64, zf_prec int) string {
	mut zf_buf := [400]u8{}
	zf_n := zfmt_val(unsafe { &zf_buf[0] }, 400, 0, zf_x, zf_prec)
	unsafe {
		zf_buf[if zf_n < 399 { zf_n } else { 399 }] = 0
	}
	return unsafe { tos_clone(&zf_buf[0]) }
}

fn zfmt_put(zf_out &u8, zf_cap int, zf_pos int, zf_c u8) {
	if zf_pos < zf_cap - 1 {
		unsafe {
			zf_out[zf_pos] = zf_c
		}
	}
}

// fmt's literal bytes and each `%.Nf` hole's value into out (cap bytes, NUL-terminated at what
// fits); returns the whole's length, as snprintf does
fn zfmt_into(zf_out &u8, zf_cap int, zf_fmt string, zf_v []f64) int {
	mut zf_pos := 0
	mut zf_i := 0
	mut zf_hole := 0
	for zf_i < zf_fmt.len {
		zf_c := zf_fmt[zf_i]
		if zf_c != `%` {
			zfmt_put(zf_out, zf_cap, zf_pos, zf_c)
			zf_pos++
			zf_i++
			continue
		}
		if zf_i + 1 < zf_fmt.len && zf_fmt[zf_i + 1] == `%` {
			zfmt_put(zf_out, zf_cap, zf_pos, `%`)
			zf_pos++
			zf_i += 2
			continue
		}
		if zf_i + 3 < zf_fmt.len && zf_fmt[zf_i + 1] == `.` && zf_fmt[zf_i + 3] == `f` && zf_hole < zf_v.len {
			zf_d := int(zf_fmt[zf_i + 2]) - 48
			if zf_d >= 0 && zf_d <= 9 {
				zf_pos = zfmt_val(zf_out, zf_cap, zf_pos, zf_v[zf_hole], zf_d)
				zf_hole++
				zf_i += 4
				continue
			}
		}
		// any other spec: its bytes as they are (the emitter writes none)
		zfmt_put(zf_out, zf_cap, zf_pos, zf_c)
		zf_pos++
		zf_i++
	}
	zf_end := if zf_pos < zf_cap { zf_pos } else { zf_cap - 1 }
	unsafe {
		zf_out[zf_end] = 0
	}
	return zf_pos
}

fn zfmt_signbit(zf_x f64) bool {
	zf_u := unsafe { *(&u64(&zf_x)) }
	return (zf_u >> 63) != 0
}

fn zfmt_lit(zf_t &u8, zf_s string) int {
	for zf_k in 0 .. zf_s.len {
		unsafe {
			zf_t[zf_k] = zf_s[zf_k]
		}
	}
	return zf_s.len
}

// the digits t[0..n0) rounded up by one in the last place, the sign kept, a carry out of the
// first digit prepending a 1; a trailing '.' (precision 0) dropped first; returns the new length
fn zfmt_round_up(zf_t &u8, zf_n0 int) int {
	mut zf_n := zf_n0
	if zf_n > 0 && unsafe { zf_t[zf_n - 1] } == `.` {
		zf_n--
	}
	mut zf_k := zf_n - 1
	for zf_k >= 0 {
		zf_c := unsafe { zf_t[zf_k] }
		if zf_c == `.` {
			zf_k--
			continue
		}
		if zf_c == `-` {
			break
		}
		if zf_c == `9` {
			unsafe {
				zf_t[zf_k] = `0`
			}
			zf_k--
			continue
		}
		unsafe {
			zf_t[zf_k] = zf_c + 1
		}
		return zf_n
	}
	zf_at := zf_k + 1
	mut zf_j := zf_n
	for zf_j > zf_at {
		unsafe {
			zf_t[zf_j] = zf_t[zf_j - 1]
		}
		zf_j--
	}
	unsafe {
		zf_t[zf_at] = `1`
	}
	return zf_n + 1
}

// one value at a precision into out at pos, in Zig's spelling (see above); returns the new pos
fn zfmt_val(zf_out &u8, zf_cap int, zf_pos int, zf_x f64, zf_prec int) int {
	mut zf_tmp := [400]u8{}
	zf_tp := unsafe { &zf_tmp[0] }
	mut zf_len := 0
	if zf_x != zf_x {
		zf_len = zfmt_lit(zf_tp, if zfmt_signbit(zf_x) { '-nan' } else { 'nan' })
	} else if zf_x > 1.7976931348623157e308 {
		zf_len = zfmt_lit(zf_tp, 'inf')
	} else if zf_x < -1.7976931348623157e308 {
		zf_len = zfmt_lit(zf_tp, '-inf')
	} else {
		zf_len = C.snprintf(&char(zf_tp), 400, &char(zfmt_specs[zf_prec + 1].str), zf_x)
		zf_ax := if zf_x < 0 { -zf_x } else { zf_x }
		if zf_len > 0 && zf_len < 400 && zf_tmp[zf_len - 1] == `5` && zf_ax < zfmt_bounds[zf_prec]
			&& unsafe { tos(zf_tp, zf_len) }.f64() == zf_x {
			zf_len = zfmt_round_up(zf_tp, zf_len - 1)
		} else {
			zf_len = C.snprintf(&char(zf_tp), 400, &char(zfmt_specs[zf_prec].str), zf_x)
		}
	}
	if zf_len > 400 {
		zf_len = 400
	}
	for zf_k in 0 .. zf_len {
		zfmt_put(zf_out, zf_cap, zf_pos + zf_k, zf_tmp[zf_k])
	}
	return zf_pos + zf_len
}

// -- zshow_f: a bare float hole's spelling, the Zig backend's (2026-10-26) --
// A hole with no spec (`${x}`) and a float's toString go through the Zig backend's _zbr_show_float:
// std.fmt's `{d}` -- the shortest digits that read back to the value, never an exponent -- plus
// ".0" when the value is whole and finite; nan, -nan, inf, -inf as they are. V's f64.str() gives the
// same shortest digits but switches to an exponent past a magnitude ("1e+20", "1e-07"), so the
// digits are taken from it and the exponent is expanded into plain digits here. One allocation for
// V's string and one for the result; the fixed-precision holes take zfmt_f, this is parity only.
pub fn zshow_f(zf_x f64) string {
	if zf_x != zf_x {
		return if zfmt_signbit(zf_x) { '-nan' } else { 'nan' }
	}
	if zf_x > 1.7976931348623157e308 {
		return 'inf'
	}
	if zf_x < -1.7976931348623157e308 {
		return '-inf'
	}
	zf_s := zf_x.str()
	zf_epos := zf_s.index_u8(`e`)
	if zf_epos < 0 {
		// no exponent: V's digits are the plain digits; make sure a whole value ends in ".0"
		if zf_s.index_u8(`.`) < 0 {
			return zf_s + '.0'
		}
		return zf_s
	}
	// d[.ddd]e[+-]NN -> the point moved by NN places
	mut zf_mant := zf_s[..zf_epos]
	zf_exp := zf_s[zf_epos + 1..].int()
	mut zf_neg := false
	if zf_mant.len > 0 && zf_mant[0] == `-` {
		zf_neg = true
		zf_mant = zf_mant[1..]
	}
	mut zf_digits := ''
	mut zf_point := zf_mant.len
	zf_dot := zf_mant.index_u8(`.`)
	if zf_dot >= 0 {
		zf_digits = zf_mant[..zf_dot] + zf_mant[zf_dot + 1..]
		zf_point = zf_dot
	} else {
		zf_digits = zf_mant
	}
	// shortest digits carry no trailing zeros in the fraction; drop any V left ("1.0e+20")
	for zf_digits.len > zf_point && zf_digits[zf_digits.len - 1] == `0` {
		zf_digits = zf_digits[..zf_digits.len - 1]
	}
	zf_newpoint := zf_point + zf_exp
	mut zf_out := ''
	if zf_newpoint <= 0 {
		zf_out = '0.' + '0'.repeat(-zf_newpoint) + zf_digits
	} else if zf_newpoint >= zf_digits.len {
		zf_out = zf_digits + '0'.repeat(zf_newpoint - zf_digits.len) + '.0'
	} else {
		zf_out = zf_digits[..zf_newpoint] + '.' + zf_digits[zf_newpoint..]
	}
	if zf_neg {
		return '-' + zf_out
	}
	return zf_out
}
