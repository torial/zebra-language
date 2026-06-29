//! N-API preamble — hand-written Zig helpers prepended to every `--target
//! node-addon` output file.  Analogous to stdlib_preamble.zig, but kept in a
//! SEPARATE file so `node_api.h` types never leak into normal Zig builds: this
//! text is embedded as a build-time string (build.zig, `napi_preamble` option)
//! and only ever compiled when a generated addon is built — at which point the
//! Node headers are on the include path (see spike/build_spike.sh).
//!
//! Phase 1 scope: the `@cImport`, error throwing, and the `undefined` value
//! helper.  Argument marshaling lives in the emitted per-method wrappers
//! (Phase 4); allocator lifetime is refined in Phase 7.
//!
//! Idioms proven by the Phase 0 spike (spike/hello_napi.zig):
//!   - `NAPI_VERSION 6` defined before the include (Node 12+, stable surface).
//!   - explicit name lengths in napi_create_function (NAPI_AUTO_LENGTH does not
//!     survive @cImport) — the wrappers, not this file, call that.

// === NAPI_PREAMBLE_HELPERS_START ===
const napi = @cImport({
    @cDefine("NAPI_VERSION", "6");
    @cInclude("node_api.h");
});

/// Throw a JS `Error` with `msg` and return null.  Emitted wrappers call this
/// when argument extraction or arity checks fail, then `return` the null value
/// — Node sees the pending exception rather than a bogus result.
fn _napi_throw(env: napi.napi_env, msg: [*:0]const u8) napi.napi_value {
    _ = napi.napi_throw_error(env, null, msg);
    return null;
}

/// The JS `undefined` value, for void-returning exports.
fn _napi_undefined(env: napi.napi_env) napi.napi_value {
    var v: napi.napi_value = undefined;
    _ = napi.napi_get_undefined(env, &v);
    return v;
}
// === NAPI_PREAMBLE_HELPERS_END ===
