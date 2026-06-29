//! Phase 0 N-API spike — a hand-written Node addon in Zig, before any compiler
//! work.  Exports one function `add(a, b)` and registers it as the module's
//! `add` export.  Goal: `node spike/test.js` prints `spike: ok`.
//!
//! Proves the load-bearing platform path (Windows node.lib link + node_api.h
//! include + .node packaging) in isolation, per the impl plan's Phase 0.

const c = @cImport({
    @cDefine("NAPI_VERSION", "6");
    @cInclude("node_api.h");
});

// napi callback: read two JS number args, return their sum as a JS number.
fn add(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 2;
    var argv: [2]c.napi_value = undefined;
    _ = c.napi_get_cb_info(env, info, &argc, &argv, null, null);

    var a: f64 = 0;
    var b: f64 = 0;
    _ = c.napi_get_value_double(env, argv[0], &a);
    _ = c.napi_get_value_double(env, argv[1], &b);

    var result: c.napi_value = undefined;
    _ = c.napi_create_double(env, a + b, &result);
    return result;
}

// Module init — Node calls this on require().  Attach `add` to `exports`.
export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    var fn_val: c.napi_value = undefined;
    // Pass the explicit name length (3) instead of NAPI_AUTO_LENGTH so we don't
    // depend on @cImport translating that macro.
    _ = c.napi_create_function(env, "add", 3, add, null, &fn_val);
    _ = c.napi_set_named_property(env, exports, "add", fn_val);
    return exports;
}
