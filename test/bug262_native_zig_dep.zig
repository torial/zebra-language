// Native Zig dependency for test/bug262_native_zig_dep_test.zbr.
// Deliberately trivial: the fixture is about whether this FILE is materialised beside the
// emitted output, not about what it computes.
pub fn triple(n: i64) i64 {
    return n * 3;
}
