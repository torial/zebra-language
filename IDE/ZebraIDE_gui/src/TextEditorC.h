// Thin C API shim over BalazsJako/ImGuiColorTextEdit.
// Zig calls these via @cImport; the implementation is TextEditorC.cpp.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef void* TE_Handle;

TE_Handle   te_create(void);
void        te_destroy(TE_Handle h);

void        te_set_text(TE_Handle h, const char* text);
const char* te_get_text(TE_Handle h);       // valid until next te_get_text or te_destroy

// lang: "zebra" (default), "cpp", "c", "glsl", "lua", "sql", "" = none
void        te_set_language(TE_Handle h, const char* lang);

void        te_render(TE_Handle h, const char* id, float w, float ht);

void        te_clear_errors(TE_Handle h);
void        te_add_error(TE_Handle h, int line, const char* msg);

void        te_set_readonly(TE_Handle h, int readonly);
int         te_is_readonly(TE_Handle h);

// Cursor position — 1-based line/col to match compiler diagnostic convention.
// Internal TextEditor coordinates are 0-based; conversion is done in the .cpp.
int         te_get_cursor_line(TE_Handle h);
int         te_get_cursor_col(TE_Handle h);
void        te_set_cursor_position(TE_Handle h, int line, int col);

#ifdef __cplusplus
}
#endif
