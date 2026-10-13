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

pub fn zlist_of[T](items []T) &ZList[T] {
	return &ZList[T]{
		items: items
	}
}

pub fn (mut l ZList[T]) add(x T) {
	l.items << x
}

pub fn (l &ZList[T]) at(i i64) T {
	return l.items[i]
}

pub fn (mut l ZList[T]) set(i i64, x T) {
	l.items[i] = x
}

pub fn (l &ZList[T]) count() i64 {
	return i64(l.items.len)
}

pub fn (l &ZList[T]) is_empty() bool {
	return l.items.len == 0
}

pub fn (l &ZList[T]) copy() &ZList[T] {
	return &ZList[T]{
		items: l.items.clone()
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

pub fn (mut l ZList[T]) clear() {
	l.items.clear()
}

pub fn (l &ZList[T]) last() T {
	return l.items.last()
}

// (a free function, not a method: a method is instantiated for every
// element type the struct is named with, and V's own string method for a
// float array lost a helper to its unused-pruning at the C stage)
pub fn zlist_str[T](l &ZList[T]) string {
	return l.items.str()
}

// ── HashMap ────────────────────────────────────────────────────────────────
@[heap]
pub struct ZMap[K, V] {
pub mut:
	m map[K]V
}

pub fn (m &ZMap[K, V]) contains(k K) bool {
	return k in m.m
}

// Zebra's fetch: the value, or a failure when the key is absent (the Zig
// backend's `.?`; callers guard with contains)
pub fn (m &ZMap[K, V]) fetch(k K) V {
	return m.m[k] or { panic('fetch: no such key: ${k}') }
}

pub fn new_zmap[K, V]() &ZMap[K, V] {
	return &ZMap[K, V]{}
}

pub fn (mut z ZMap[K, V]) set(k K, v V) {
	z.m[k] = v
}

// Zebra's get is a nilable: V's option
pub fn (z &ZMap[K, V]) get(k K) ?V {
	if k in z.m {
		return z.m[k] or { return none }
	}
	return none
}

pub fn (z &ZMap[K, V]) has(k K) bool {
	return k in z.m
}

pub fn (mut z ZMap[K, V]) remove(k K) {
	z.m.delete(k)
}

pub fn (z &ZMap[K, V]) count() i64 {
	return i64(z.m.len)
}

pub fn (z &ZMap[K, V]) keys() &ZList[K] {
	return &ZList[K]{
		items: z.m.keys()
	}
}

pub fn (z &ZMap[K, V]) values() &ZList[V] {
	return &ZList[V]{
		items: z.m.values()
	}
}

pub fn (mut z ZMap[K, V]) clear() {
	z.m.clear()
}

pub fn (z &ZMap[K, V]) copy() &ZMap[K, V] {
	return &ZMap[K, V]{
		m: z.m.clone()
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

pub fn (mut s ZSet[T]) add(x T) {
	s.m[x] = true
}

pub fn (s &ZSet[T]) contains(x T) bool {
	return x in s.m
}

pub fn (mut s ZSet[T]) remove(x T) {
	s.m.delete(x)
}

pub fn (s &ZSet[T]) count() i64 {
	return i64(s.m.len)
}

pub fn (mut s ZSet[T]) clear() {
	s.m.clear()
}

pub fn (s &ZSet[T]) items() &ZList[T] {
	return &ZList[T]{
		items: s.m.keys()
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

pub fn (mut b ZStringBuilder) append(s string) {
	b.parts << s
}

pub fn (mut b ZStringBuilder) append_int(x i64) {
	b.parts << x.str()
}

pub fn (mut b ZStringBuilder) append_float(x f64) {
	b.parts << x.str()
}

pub fn (mut b ZStringBuilder) append_bool(x bool) {
	b.parts << x.str()
}

pub fn (b &ZStringBuilder) build() string {
	return b.parts.join('')
}

pub fn (mut b ZStringBuilder) clear() {
	b.parts.clear()
}

pub fn (b &ZStringBuilder) len() i64 {
	mut n := i64(0)
	for p in b.parts {
		n += i64(p.len)
	}
	return n
}

// ── the list methods V's generics cannot carry on the struct ──────────────
// (a generic method is instantiated for every element type the program uses,
// and `join` only exists for strings; `sort` wants a comparable T)
pub fn zjoin(l &ZList[string], sep string) string {
	return l.items.join(sep)
}

// `x == nil` / `x != nil`: through a call, so V never smart-casts the name
// (a smart-cast name refuses an `or` block, keeps its option type in a
// binding, and breaks the C stage when passed back to a generic `?T`)
pub fn zis_none[T](x ?T) bool {
	return x == none
}

// a def that is nilable AND throws returns this (V has no `!?T`): the
// emitter wraps its returns and unwraps a `?`-call back to V's option
pub struct ZOpt[T] {
pub mut:
	has bool
	val T
}

pub fn zopt_of[T](o ZOpt[T]) ?T {
	if o.has {
		return o.val
	}
	return none
}

pub fn zopt_from[T](x ?T) ZOpt[T] {
	if v := x {
		return ZOpt[T]{ has: true, val: v }
	}
	return ZOpt[T]{}
}

// `opt == value` (Zebra compares a nilable with a value): false when none
pub fn zopt_eq[T](a ?T, b T) bool {
	x := a or { return false }
	return x == b
}

// `x!`: the value, or a failure
pub fn zunwrap[T](x ?T) T {
	return x or { panic('a nil unwrapped') }
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
pub fn zany(xs []bool) bool {
	for x in xs {
		if x {
			return true
		}
	}
	return false
}

pub fn zall(xs []bool) bool {
	for x in xs {
		if !x {
			return false
		}
	}
	return true
}

pub fn zsort_i64(mut l ZList[i64]) {
	l.items.sort()
}

pub fn zsort_f64(mut l ZList[f64]) {
	l.items.sort()
}

// a list sorted by a comparator or a key: stable insertion sorts (the Zig
// backend's std.mem.sort is stable, so ties keep their order on both)
pub fn zlist_sort_with[T](mut l ZList[T], less fn (T, T) bool) {
	for i := 1; i < l.items.len; i++ {
		for j := i; j > 0 && less(l.items[j], l.items[j - 1]); j-- {
			tmp := l.items[j]
			l.items[j] = l.items[j - 1]
			l.items[j - 1] = tmp
		}
	}
}

pub fn zlist_sort_by_i64[T](mut l ZList[T], key fn (T) i64) {
	for i := 1; i < l.items.len; i++ {
		for j := i; j > 0 && key(l.items[j]) < key(l.items[j - 1]); j-- {
			tmp := l.items[j]
			l.items[j] = l.items[j - 1]
			l.items[j - 1] = tmp
		}
	}
}

pub fn zlist_sort_by_f64[T](mut l ZList[T], key fn (T) f64) {
	for i := 1; i < l.items.len; i++ {
		for j := i; j > 0 && key(l.items[j]) < key(l.items[j - 1]); j-- {
			tmp := l.items[j]
			l.items[j] = l.items[j - 1]
			l.items[j - 1] = tmp
		}
	}
}

pub fn zlist_sort_by_str[T](mut l ZList[T], key fn (T) string) {
	for i := 1; i < l.items.len; i++ {
		for j := i; j > 0 && key(l.items[j]) < key(l.items[j - 1]); j-- {
			tmp := l.items[j]
			l.items[j] = l.items[j - 1]
			l.items[j - 1] = tmp
		}
	}
}

pub fn zsort_str(mut l ZList[string]) {
	l.items.sort()
}

pub fn zlist_index_of[T](l &ZList[T], x T) i64 {
	for i, it in l.items {
		if it == x {
			return i64(i)
		}
	}
	return -1
}

pub fn zlist_remove[T](mut l ZList[T], x T) bool {
	i := zlist_index_of(l, x)
	if i < 0 {
		return false
	}
	l.items.delete(int(i))
	return true
}

pub fn zlist_reverse[T](l &ZList[T]) &ZList[T] {
	return &ZList[T]{
		items: l.items.reverse()
	}
}

pub fn zlist_contains[T](l &ZList[T], x T) bool {
	// (a loop rather than `x in l.items`: V 0.5.2's -g line map blamed the `in`
	// for a C error that was the generic insert's; a standalone `in` compiles)
	for it in l.items {
		if it == x {
			return true
		}
	}
	return false
}

// the list's own spellings, reached when the emitter knows the receiver is a list
pub fn (mut l ZList[T]) remove_at(i i64) {
	l.items.delete(int(i))
}

pub fn (l &ZList[T]) reversed() &ZList[T] {
	return zlist_reverse(l)
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
pub fn zsys_run(argv &ZList[string]) ZRunResult {
	if argv.count() == 0 {
		return ZRunResult{ exit_code: -1, stderr: 'sys.run: no program named' }
	}
	mut p := os.new_process(argv.items[0])
	p.set_args(argv.items[1..].clone())
	p.set_redirect_stdio()
	p.run()
	out := p.stdout_slurp()
	errs := p.stderr_slurp()
	p.wait()
	code := p.code
	p.close()
	return ZRunResult{ exit_code: i64(code), stdout: out, stderr: errs }
}

// ── Json: Zebra's Json / JsonValue is json2.Any by value ──────────────────
pub fn zjson_parse(s string) ?json2.Any {
	return json2.decode[json2.Any](s) or { return none }
}

pub fn zjson_object() json2.Any {
	return json2.Any(map[string]json2.Any{})
}

pub fn zjson_array() json2.Any {
	return json2.Any([]json2.Any{})
}

pub fn zjson_get(j json2.Any, k string) ?json2.Any {
	if j is map[string]json2.Any {
		m := j as map[string]json2.Any
		return m[k] or { return none }
	}
	return none
}

pub fn zjson_has(j json2.Any, k string) bool {
	if j is map[string]json2.Any {
		m := j as map[string]json2.Any
		return k in m
	}
	return false
}

pub fn zjson_try_str(j json2.Any) ?string {
	if j is string {
		return j as string
	}
	return none
}

fn zjson_is_number(j json2.Any) bool {
	if j is string || j is bool || j is json2.Null || j is []json2.Any || j is map[string]json2.Any {
		return false
	}
	return true
}

// a whole number only: json2 parses every number as f64, and a fraction
// is not an int (the Zig backend's _json_as_int is null for 1.6)
pub fn zjson_try_int(j json2.Any) ?i64 {
	if j is f64 {
		f := j as f64
		if math.floor(f) == f && f >= -9.2233720368547758e18 && f < 9.2233720368547758e18 {
			return i64(f)
		}
		return none
	}
	if zjson_is_number(j) {
		return j.i64()
	}
	return none
}

pub fn zjson_try_float(j json2.Any) ?f64 {
	if zjson_is_number(j) {
		return j.f64()
	}
	return none
}

pub fn zjson_try_bool(j json2.Any) ?bool {
	if j is bool {
		return j as bool
	}
	return none
}

pub fn zjson_try_obj(j json2.Any) ?json2.Any {
	if j is map[string]json2.Any {
		return j
	}
	return none
}

pub fn zjson_try_list(j json2.Any) ?&ZList[json2.Any] {
	if j is []json2.Any {
		return zlist_of[json2.Any](j as []json2.Any)
	}
	return none
}

// `v.tryX(key)`: the member as X when v is an object with the key, else none
// (Zebra's _json_try_X beside the bare _json_self_X)
pub fn zjson_tryk_str(j json2.Any, k string) ?string {
	m := zjson_get(j, k) or { return none }
	return zjson_try_str(m)
}

pub fn zjson_tryk_int(j json2.Any, k string) ?i64 {
	m := zjson_get(j, k) or { return none }
	return zjson_try_int(m)
}

pub fn zjson_tryk_float(j json2.Any, k string) ?f64 {
	m := zjson_get(j, k) or { return none }
	return zjson_try_float(m)
}

pub fn zjson_tryk_bool(j json2.Any, k string) ?bool {
	m := zjson_get(j, k) or { return none }
	return zjson_try_bool(m)
}

pub fn zjson_tryk_obj(j json2.Any, k string) ?json2.Any {
	m := zjson_get(j, k) or { return none }
	return zjson_try_obj(m)
}

pub fn zjson_tryk_list(j json2.Any, k string) ?&ZList[json2.Any] {
	m := zjson_get(j, k) or { return none }
	return zjson_try_list(m)
}

// `j[key]?`: the member, or an error (Zebra's _json_idx)
pub fn zjson_idx(j json2.Any, k string) !json2.Any {
	if j is map[string]json2.Any {
		m := j as map[string]json2.Any
		return m[k] or { return error('json: no key ' + k) }
	}
	return error('json: not an object, indexed by ' + k)
}

// `arr[i]?`: the element, or an error
pub fn zjson_idx_at(j json2.Any, i i64) !json2.Any {
	if j is []json2.Any {
		a := j as []json2.Any
		if i < 0 || i >= a.len {
			return error('json: index ${i} of ${a.len}')
		}
		return a[int(i)]
	}
	return error('json: not an array, indexed by ${i}')
}

// a Json value received as a str: the string itself, else its JSON text
pub fn zjson_str(j json2.Any) string {
	if j is string {
		return j as string
	}
	return j.json_str()
}

// `for x in j`: the array's elements (none for anything else)
pub fn zjson_list(j json2.Any) &ZList[json2.Any] {
	if j is []json2.Any {
		return zlist_of[json2.Any](j as []json2.Any)
	}
	return new_zlist[json2.Any]()
}

pub fn zjson_keys(j json2.Any) &ZList[string] {
	if j is map[string]json2.Any {
		m := j as map[string]json2.Any
		return zlist_of[string](m.keys())
	}
	return new_zlist[string]()
}

pub fn zjson_values(j json2.Any) &ZList[json2.Any] {
	if j is map[string]json2.Any {
		m := j as map[string]json2.Any
		return zlist_of[json2.Any](m.values())
	}
	return new_zlist[json2.Any]()
}

pub fn zjson_is_null(j json2.Any) bool {
	return j is json2.Null
}

pub fn zjson_is_object(j json2.Any) bool {
	return j is map[string]json2.Any
}

pub fn zjson_is_array(j json2.Any) bool {
	return j is []json2.Any
}

// the put / append family returns the new value: the emitter writes
// `j = zjson_put(j, k, v)` for Zebra's `j.put(k, v)` (a sum type cannot be
// a mut parameter), which keeps the value semantics of Zig's std.json.Value
pub fn zjson_put(j json2.Any, k string, v json2.Any) json2.Any {
	mut m := map[string]json2.Any{}
	if j is map[string]json2.Any {
		m = (j as map[string]json2.Any).clone()
	}
	m[k] = v
	return json2.Any(m)
}

pub fn zjson_put_str(j json2.Any, k string, v string) json2.Any {
	return zjson_put(j, k, json2.Any(v))
}

pub fn zjson_put_int(j json2.Any, k string, v i64) json2.Any {
	return zjson_put(j, k, json2.Any(v))
}

pub fn zjson_put_float(j json2.Any, k string, v f64) json2.Any {
	return zjson_put(j, k, json2.Any(v))
}

pub fn zjson_put_bool(j json2.Any, k string, v bool) json2.Any {
	return zjson_put(j, k, json2.Any(v))
}

pub fn zjson_append(j json2.Any, v json2.Any) json2.Any {
	mut a := []json2.Any{}
	if j is []json2.Any {
		a = (j as []json2.Any).clone()
	}
	a << v
	return json2.Any(a)
}

pub fn zjson_append_str(j json2.Any, v string) json2.Any {
	return zjson_append(j, json2.Any(v))
}

pub fn zjson_append_int(j json2.Any, v i64) json2.Any {
	return zjson_append(j, json2.Any(v))
}

pub fn zjson_append_float(j json2.Any, v f64) json2.Any {
	return zjson_append(j, json2.Any(v))
}

pub fn zjson_append_bool(j json2.Any, v bool) json2.Any {
	return zjson_append(j, json2.Any(v))
}

// ── Random: a seeded generator (xoshiro256++, seeded by splitmix64 as Zig's
// DefaultPrng is; the range reduction is not Zig's, so a sequence here is
// not the Zig backend's -- a known divergence, said in the note) ─────────
@[heap]
pub struct ZRandom {
pub mut:
	s [4]u64
}

pub fn zrandom_new(seed i64) &ZRandom {
	mut r := &ZRandom{}
	mut x := u64(seed)
	for i in 0 .. 4 {
		x += u64(0x9E3779B97F4A7C15)
		mut z := x
		z = (z ^ (z >> 30)) * u64(0xBF58476D1CE4E5B9)
		z = (z ^ (z >> 27)) * u64(0x94D049BB133111EB)
		r.s[i] = z ^ (z >> 31)
	}
	return r
}

fn zrotl(x u64, k int) u64 {
	return (x << k) | (x >> (64 - k))
}

pub fn (mut r ZRandom) next_u64() u64 {
	result := zrotl(r.s[0] + r.s[3], 23) + r.s[0]
	t := r.s[1] << 17
	r.s[2] ^= r.s[0]
	r.s[3] ^= r.s[1]
	r.s[1] ^= r.s[2]
	r.s[0] ^= r.s[3]
	r.s[2] ^= t
	r.s[3] = zrotl(r.s[3], 45)
	return result
}

// Random.nextInt(lo, hi): inclusive both ends
pub fn (mut r ZRandom) next_int(lo i64, hi i64) i64 {
	if hi <= lo {
		return lo
	}
	span := u64(hi - lo + 1)
	return lo + i64(r.next_u64() % span)
}

pub fn (mut r ZRandom) next_float() f64 {
	return f64(r.next_u64() >> 11) / f64(u64(1) << 53)
}

// ── Sqlite: no sqlite on this backend; the types exist so a program that
// holds a database compiles, and every call on one panics with the reason ──
@[heap]
pub struct ZSqliteDb {
pub mut:
	path string
}

@[heap]
pub struct ZSqliteRow {
pub mut:
	n i64
}

pub fn zsqlite_open(path string) ?&ZSqliteDb {
	panic('not on the V backend: Sqlite.open: no sqlite (the Zig backend links the vendored sqlite3)')
}

pub fn (mut d ZSqliteDb) exec(sql_text string, params &ZList[string]) {
	panic('not on the V backend: SqliteDb.exec: no sqlite')
}

pub fn (mut d ZSqliteDb) query(sql_text string, params &ZList[string]) &ZList[&ZSqliteRow] {
	panic('not on the V backend: SqliteDb.query: no sqlite')
}

pub fn (mut d ZSqliteDb) close() {
}

pub fn (r &ZSqliteRow) as_int(col string) i64 {
	panic('not on the V backend: SqliteRow.asInt: no sqlite')
}

pub fn (r &ZSqliteRow) as_str(col string) string {
	panic('not on the V backend: SqliteRow.asStr: no sqlite')
}

pub fn (r &ZSqliteRow) as_float(col string) f64 {
	panic('not on the V backend: SqliteRow.asFloat: no sqlite')
}

pub fn (r &ZSqliteRow) as_bool(col string) bool {
	panic('not on the V backend: SqliteRow.asBool: no sqlite')
}

// ── Random, Hash, Http ────────────────────────────────────────────────────
pub fn zrandom_int(lo i64, hi i64) i64 {
	return rand.i64_in_range(lo, hi + 1) or { lo }
}

pub fn zhash_sha256(s string) string {
	return sha256.hexhash(s)
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

pub fn (a ZArgs) flag(long string, short string) bool {
	for x in a.raw {
		if x == long || x == short {
			return true
		}
	}
	return false
}

pub fn (a ZArgs) contains(name string) bool {
	for x in a.raw {
		if x == name {
			return true
		}
	}
	return false
}

pub fn (a ZArgs) option(name string, default_val string) string {
	for x in a.raw {
		if x.starts_with(name) && x.len > name.len && x[name.len] == `=` {
			return x[name.len + 1..]
		}
	}
	for i := 0; i + 1 < a.raw.len; i++ {
		if a.raw[i] == name {
			return a.raw[i + 1]
		}
	}
	return default_val
}

pub fn (a ZArgs) option_int(name string, default_val i64) i64 {
	s := a.option(name, '')
	if s.len == 0 {
		return default_val
	}
	return strconv.parse_int(s, 10, 64) or { default_val }
}

pub fn (a ZArgs) unknown_flag(known string) string {
	for x in a.raw {
		if x.len < 2 || x[0] != `-` {
			continue
		}
		if x == '--' {
			break
		}
		name := if eq := x.index('=') { x[..eq] } else { x }
		mut found := false
		for k in known.split(' ') {
			if k == name {
				found = true
				break
			}
		}
		if !found {
			return x
		}
	}
	return ''
}

pub fn (a ZArgs) positional(idx i64) ?string {
	mut pos := i64(0)
	for x in a.raw {
		if !x.starts_with('-') {
			if pos == idx {
				return x
			}
			pos += 1
		}
	}
	return none
}

pub fn (a ZArgs) usage() string {
	return 'Usage: program [options]'
}

pub fn zdir_try_delete_all(path string) bool {
	os.rmdir_all(path) or { return false }
	return true
}

pub fn zfile_try_delete(path string) bool {
	os.rm(path) or { return false }
	return true
}

// sys.readLine: a line without its newline, none at the end of input
pub fn zsys_readline() ?string {
	line := os.get_raw_line()
	if line.len == 0 {
		return none
	}
	return line.trim_right('\r\n')
}

// sys.exec_inherit(argv): run with the parent's stdio; the exit code
pub fn zsys_exec_inherit(argv &ZList[string]) i64 {
	mut parts := []string{}
	for a in argv.items {
		if a.contains(' ') || a.contains('"') {
			parts << '"' + a.replace('"', '\\"') + '"'
		} else {
			parts << a
		}
	}
	return i64(os.system(parts.join(' ')))
}

// Dir.list(path): the entries' names
pub fn zdir_list(path string) &ZList[string] {
	return zlist_of[string](os.ls(path) or { []string{} })
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

pub fn zstr_is_numeric(s string) bool {
	if s.len == 0 {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

pub fn zstr_last_index_of(s string, sub string) i64 {
	return i64(s.last_index(sub) or { -1 })
}

pub fn zstr_try_int(s string) ?i64 {
	return strconv.parse_int(s, 10, 64) or { return none }
}

pub fn zstr_try_float(s string) ?f64 {
	return strconv.atof64(s) or { return none }
}

pub fn zstr_char_at(s string, i i64) string {
	return s[i..i + 1]
}

pub fn zstr_split(s string, sep string) &ZList[string] {
	return &ZList[string]{
		items: s.split(sep)
	}
}

pub fn zstr_lines(s string) &ZList[string] {
	return &ZList[string]{
		items: s.split_into_lines()
	}
}

pub fn zstr_pad_left(s string, width i64, pad string) string {
	mut out := s
	for i64(out.len) < width {
		out = pad + out
	}
	return out
}

pub fn zstr_pad_right(s string, width i64, pad string) string {
	mut out := s
	for i64(out.len) < width {
		out = out + pad
	}
	return out
}

pub fn zstr_index_of(s string, sub string) i64 {
	return i64(s.index(sub) or { return -1 })
}

// ── Math ───────────────────────────────────────────────────────────────────
pub fn zmath_clamp(x f64, lo f64, hi f64) f64 {
	return math.min(math.max(x, lo), hi)
}

pub fn zmath_round(x f64) f64 {
	return math.round(x)
}

// ── File / Path (over V's os) ──────────────────────────────────────────────
pub fn zfile_exists(p string) bool {
	return os.exists(p)
}

pub fn zfile_read(p string) string {
	return os.read_file(p) or { '' }
}

pub fn zfile_write(p string, text string) {
	os.write_file(p, text) or { eprintln('zebra: File.write ${p}: ${err}') }
}

pub fn zfile_append(p string, text string) {
	mut f := os.open_append(p) or {
		eprintln('zebra: File.append ${p}: ${err}')
		return
	}
	f.write_string(text) or { eprintln('zebra: File.append ${p}: ${err}') }
	f.close()
}

pub fn zfile_list_dir(p string) &ZList[string] {
	return &ZList[string]{
		items: os.ls(p) or { []string{} }
	}
}

pub fn zpath_dirname(p string) string {
	return os.dir(p)
}

pub fn zpath_basename(p string) string {
	return os.base(p)
}

pub fn zpath_stem(p string) string {
	return os.file_name(p).all_before_last('.')
}

pub fn zpath_join(a string, b string) string {
	return os.join_path(a, b)
}
