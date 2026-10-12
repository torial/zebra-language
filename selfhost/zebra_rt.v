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

pub fn (l &ZList[T]) str() string {
	return l.items.str()
}

// ── HashMap ────────────────────────────────────────────────────────────────
pub struct ZMap[K, V] {
pub mut:
	m map[K]V
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
		return z.m[k]
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

pub fn zsort_i64(mut l ZList[i64]) {
	l.items.sort()
}

pub fn zsort_f64(mut l ZList[f64]) {
	l.items.sort()
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
