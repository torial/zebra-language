# Cleanup Tracker — Zebra 0.15

This file tracks accumulated hacks, workarounds, and technical debt that should
be cleaned up in the 0.15 point release. Items are added as they are identified;
each entry notes the module, the hack, and what the clean fix would be.

---

## Selfhost compiler (`selfhost/`)

### 1. Shadow-set type tracking system

**Files:** `selfhost/codegen.zbr` — `Generator` struct  
**Status:** Stages 1–4 complete (2026-05-15); 3 sets remain pending

**What:** The `Generator` struct originally carried 9 parallel `StrSet`/`HashMap` fields.
Six have been deleted; 3 remain pending a different approach:
- ~~`list_locals`~~ — deleted
- ~~`hashmap_locals`~~ — deleted
- ~~`hashmap_str_key_locals`~~ — deleted
- ~~`hashmap_str_val_locals`~~ — deleted
- ~~`list_str_locals`~~ — deleted
- ~~`list_ref_locals`~~ — deleted
- `strset_locals` — still active (no InferCtx equivalent for StrSet)
- `list_tuple_locals` — still active (tuple element dispatch)
- `list_tuple_str_pos` — still active (string-position encoding)

**Stage 1 (done 2026-05-14):** `Type_` now carries `list_: ^Type_` and
`hashmap_: HashMapType_`, and `typeFromRef` returns them for annotated types.

**Stages 2–3 (done 2026-05-15):** Added 7 helper methods to `Generator`
(`localIsHashMap`, `localIsList`, `localIsListStr`, `localIsHashMapStrKey`,
`localIsHashMapStrVal`, `localIsListRef`, `localListRefType`). All 15 dispatch
sites replaced with helpers.

**Stage 4 (done 2026-05-15):** Extended `inferExpr` to handle the two previously-missing
patterns, then deleted the 6 shadow-set fields and `lookupTopLevelFnReturnTypeRef`:
1. `Expr.call as gc` extended: handles `HashMap(K,V)()` → `Type_.hashmap_(...)` and `List(T)()` → `Type_.list_(...)` when type args are bare idents
2. New `on Expr.list_lit as ll` arm: uses `elem_type` annotation if present; else infers from first element; fallback `Type_.list_(Type_.unknown_)` for empty lists
3. Helper fallbacks removed: `return false`/`return ""` instead of shadow-set reads
4. Field declarations deleted: 6 fields gone from Generator struct + cue init + indented()
5. Population code deleted: genLocalVar and genMethod param-tracking blocks for the 6 fields
6. `lookupTopLevelFnReturnTypeRef` deleted: InferCtx covers same-module function return types via `methodReturnAny("", fn_name)`

**Remaining (not migrated):** `strset_locals`, `list_tuple_locals`, `list_tuple_str_pos`
— need deeper InferCtx work or a different approach.

---

### 2. `str_slice` overloaded as "string collection"

**File:** `selfhost/typechecker.zbr` — `Type_` union, `typeFromRef`  
**Status:** Safety-net `inferExpr` arms removed (2026-05-15); variant still exists

**What:** `Type_.str_slice` was originally used as a sentinel for any string-valued
collection (both `List(str)` and `HashMap(K,str)`). After Stage 1 added `list_` and
`hashmap_`, `typeFromRef` no longer produces `str_slice` for List/HashMap.

Four dead arms were removed from `typechecker.zbr`:
- `inferExpr` member dispatch: `on Type_.str_slice` → string method returns
- `inferExpr` index dispatch: `on Type_.str_slice` → `Type_.string_`
- `inferExpr` slice dispatch: `on Type_.str_slice` → `Type_.str_slice`
- `walkStmt` for-in: `if ft_val is Type_.str_slice` → `loop_var_t = Type_.string_`

**Remaining:** `str_slice` variant still in `Type_` union; safety-net arms still in
`codegen.zbr` (`zigTypeForPrimType`, print format, clear handler). These are
technically dead but serve as a safety net until the variant is deleted.

**Root fix:** After Stage 4 deletes the shadow sets, audit all `str_slice` uses in
codegen.zbr (lines 372, 5095, 5130, 7304) and in `typeTag` (typechecker.zbr line
922). Remove them and delete the `str_slice` variant from `Type_`.

---

### 3. `list_tuple_str_pos` string-encoding for tuple position flags

**File:** `selfhost/codegen.zbr` — `Generator.list_tuple_str_pos: StrSet`  
**Status:** Active; superseded by root fix eventually

**What:** Whether a tuple position `N` in a list holds a `str` value is encoded as
the string `"varname:N"` in a `StrSet`. This is a textual encoding of a structured
fact (varname × position index × element type).

**Root fix:** Once `list_` carries its element `Type_`, position-level string-ness
can be derived by inspecting the tuple element type directly, eliminating the
string-encoded StrSet entirely.

---

### 4. `lookupTopLevelFnReturnTypeRef` patch in codegen

**File:** `selfhost/codegen.zbr`  
**Status:** Active; becomes obsolete once Stage 3 of root fix covers function-call sources

**What:** When a local variable is initialized by a function call (`var x = f()`) with
no type annotation, the shadow sets miss it unless `f`'s return type is explicitly
looked up. `lookupTopLevelFnReturnTypeRef` walks `module_decls` to find the declared
return type and populates the shadow sets accordingly. It only covers same-module
functions — cross-module function return types are still missed.

**Note:** `inferExpr` on call expressions does use `methodReturnAny` to look up
registered function return types, so for annotated functions it works via InferCtx.
The shadow-set population in `genLocalVar` is a belt-and-suspenders fallback.

**Root fix:** Close the `inferExpr` gap for unannotated ctors (see item 1 Stage 4).
Once dispatch uses `inferExpr`/InferCtx exclusively, this helper is no longer
needed for shadow-set population.

---

### 5. `Type_` taxonomy split (`context_dependent` / `unresolved` / `unknown_`)

**File:** `selfhost/typechecker.zbr` — `Type_` union  
**Status:** Active design debt (BUG-099)

**What:** Three "abstract/placeholder" Type_ variants were introduced as part of the
BUG-099 split to distinguish TC gap conditions:
- `unknown_` — upstream error; suppress cascading errors
- `context_dependent` — type must be resolved by surrounding context (nil, bare `{}`)
- `unresolved` — TC gap; alarm bell for missing inference coverage

The boundary between `unresolved` and `unknown_` is sometimes fuzzy in practice.

**Root fix:** Audit all `unresolved` return sites and either convert them to real
inference (closing TC gaps) or reclassify as `unknown_` where the expression type
is genuinely unknowable without deeper analysis.

---

### 6. `isHashMapTypeRef` raw-TypeRef parallel path

**File:** `selfhost/typechecker.zbr`  
**Status:** Active; used in `addClassMembers` to populate `hashmap_field_names`

**What:** `isHashMapTypeRef` inspects the raw `TypeRef` to detect HashMap fields, in
parallel with `typeFromRef` storing `hashmap_` in `field_types`. Two parallel indexes
exist: `ClassTypes.field_types` (via `typeFromRef`) and `ModuleTypes.hashmap_field_names`
(via `isHashMapTypeRef`). The latter is used by codegen heuristics.

**Root fix:** Once codegen dispatches via `inferExpr` (Stage 3 fully closed), 
`hashmap_field_names` is no longer needed. Remove it from `ModuleTypes` and 
remove `isHashMapTypeRef`.

---

## Dead code detection idea

The shadow-set cleanup uncovered a recurring problem: code accumulates dead arms
(union variant match branches that can never fire) and the compiler doesn't flag them.

**Proposed lint tool (`tools/zbr_dead_code.py` or a Zebra stdlib pass):**

1. **Union variant reachability:** For each `Type_` (or user) union, collect all
   variant construction sites (`Type_.list_(...)`, `Type_.hashmap_(...)`, etc.) and
   all match sites (`on Type_.list_`, `is Type_.list_`). Report variants that are
   matched but never constructed, and variants that are constructed but never matched.

2. **Top-level reachability:** Walk the module's call graph from roots (`main`,
   `@reflectable` decls, explicitly-exported types). Report top-level `def` / `class`
   / `struct` declarations that are never reachable from any root.

3. **Local variable usage:** Within each method, report declared `var` / `const`
   bindings that are never referenced in subsequent expressions.

**Implementation sketch (bootstrap compiler):**
- Add a `--dead-code` flag to `zebra typecheck`
- After type-checking, run a second pass that builds construction/match sets per
  union, and a call-graph from all roots
- Emit warnings for each dead arm, unreachable decl, or unused local

**Why this matters:** The `str_slice` arms in `inferExpr` were live for weeks after
`typeFromRef` stopped producing `str_slice`. A lint tool would have flagged the
mismatch immediately.

---

## Summary table

| # | Hack | Location | Superseded by | Status |
|---|------|----------|---------------|--------|
| 1 | Shadow-set system (9 fields → 3) | codegen.zbr Generator | `inferExpr` dispatch (Stages 1–4) | **Complete** (6 deleted; 3 pending) |
| 2 | `str_slice` overloading | typechecker.zbr Type_ | `list_` / `hashmap_` variants | inferExpr arms removed; variant kept |
| 3 | `list_tuple_str_pos` encoding | codegen.zbr | `list_` element type | Active |
| 4 | `lookupTopLevelFnReturnTypeRef` | codegen.zbr | `inferExpr` on call return | **Deleted** |
| 5 | `context_dependent`/`unresolved` blur | typechecker.zbr | TC gap audit | Active (BUG-099) |
| 6 | `isHashMapTypeRef` + `hashmap_field_names` | typechecker.zbr | `inferExpr` dispatch | Active |
