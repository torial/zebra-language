// zebra_rt.v -- the Zebra runtime for the V backend (proof of concept, 2026-10-13).
// Installed beside an emitted <stem>.v by `zebra --target v`; both compile as one
// V module (`v run <dir>` or `v run <stem>.v` with this file beside it).
//
// The containers are REFERENCES, as Zebra's are (zebra-language BUG-501 1d):
// a V array is a value copied on assignment, so a Zebra List is a struct by
// reference holding one, and two names for it are one container. A mutating
// method needs a `mut` receiver, and V cannot call one on a call's result: the
// emitter binds a temporary for `xs.at(0).add(7)`.

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

pub fn (l &ZList[T]) contains(x T) bool {
	// (a loop rather than `x in l.items`: V 0.5.2's -g line map blamed the `in`
	// for a C error that was the generic insert's; a standalone `in` compiles)
	for it in l.items {
		if it == x {
			return true
		}
	}
	return false
}

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

pub fn (z &ZMap[K, V]) copy() &ZMap[K, V] {
	return &ZMap[K, V]{
		m: z.m.clone()
	}
}
