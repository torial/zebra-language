/* Fixture support for test/extern_c_call_test.zbr (BUG-261).
 *
 * Deliberately has NO matching .h: that selects the `c_no_header` path, where
 * the symbol must be declared on the Zebra side with `extern def`. The header
 * case takes a different branch (@cImport) and is a separate fixture.
 *
 * `int` here is C's int, which is why the Zebra declaration says `int32` and
 * not `int` -- Zebra's `int` is i64. See docs/extern_ffi_design.md section 4.
 */
int zebra_probe_add3(int a, int b, int c) {
    return a + b + c;
}
