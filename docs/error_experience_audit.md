# Error-experience audit (2026-06-22)

A snapshot of what the **selfhost** compiler (`zebra.exe`) reports for the
mistakes a beginner — e.g. someone porting Roblox/Luau scripts to Zebra — is
most likely to make. The goal is to rank which diagnostics are worth improving.

Method: feed each mistake to `zebra run` and grade the result. "Good" = a Zebra
`file:line[:col]: error: …` with a clear message (ideally a source line + `^`
caret, as the parser / resolver / type-checker now emit). "Bad" = a panic, a
silent wrong run, a cryptic Zig error, or no source location.

| Mistake | What you get today | Grade |
|---|---|---|
| `return "x"` from an `int` fn | `…:2:0: error: type mismatch: expected int, got str` + source line + caret | 🟢 good |
| undefined name (`print(missingThing)`) | `…:2:11: error: undefined name: 'missingThing'` + caret | 🟢 good |
| parse error (misplaced keyword, bad token) | clear message + caret | 🟢 good |
| `obj.noSuchMethod()` | `…:LINE: error: no field or member function named 'shout' in '[]const u8'` | 🟡 has `.zbr` line, but leaks the Zig type (`[]const u8` not `str`), no column/caret, Zig stack trace |
| `p.noSuchField` | `…:LINE: error: no field named 'y' in struct 'mod.P'` + a note pointing into the **generated `.zig`** | 🟡 has `.zbr` line; mangled type name; note leaks generated file |
| `f(1, "two")` — wrong arg **type** | cryptic Zig `expected type 'i64', found '*const [3:0]u8'`, note → `.zig` | 🟡 has line; Zig types; the TC checks var-decl/return type mismatches cleanly but does **not** check call-arg types in expression position |
| `greet` — forgot the `()` | Zig `value of type 'fn () void' ignored`, location is the **`.zig`**, no `.zbr` line | 🔴 bad — no Zebra location at all |
| `f(1)` — **missing a required arg** | **silently compiles and runs with garbage** (prints an uninitialized value) | 🔴 **worst** — no error; wrong behavior. See BUG-142. |

## Priorities (highest value first)

1. **BUG-142 — missing required argument is not caught.** A correctness/safety
   hole, not just a bad message: codegen pads the missing arg with `undefined`
   (`f(1)` → `f(1, undefined)`), so the program runs reading uninitialized
   memory. Needs arg-count validation in the type-checker (pairs with BUG-139,
   which is the defaulted-param side of the same arity story).
2. **`forgot_parens`** — a bare function name used as a value should be a Zebra
   error (`'greet' is a function — did you mean to call it 'greet()'?`), not a
   Zig "value … ignored" with no `.zbr` location.
3. **Call-arg type mismatch** — the TC already produces caret diagnostics for
   var-decl and return type mismatches; extend the same check to call arguments
   in expression position so `f(1, "two")` reports
   `expected int, got str` with a caret instead of a Zig type error.
4. **Method/field-not-found polish** — these have a `.zbr` line but leak Zig type
   names (`[]const u8` → `str`) and emit notes pointing into the generated
   `.zig`. Mapping the receiver type back to its Zebra name and suppressing the
   `.zig` note would make them 🟢.

Cases 2–4 are message-quality improvements (the program already fails to
compile). Case 1 is a behavioral bug and should go first.
