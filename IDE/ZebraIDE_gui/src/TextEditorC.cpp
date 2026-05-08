// C API shim for BalazsJako/ImGuiColorTextEdit.
// Wrapped by a TE_Wrapper struct so we avoid static-buffer lifetime hazards.
#include "TextEditorC.h"
#include "../vendor/ImGuiColorTextEdit/TextEditor.h"
#include <cstring>
#include <string>

struct TE_Wrapper {
    TextEditor editor;
    TextEditor::ErrorMarkers errors;
    std::string text_buf;   // backing store for te_get_text return value
};

// ── Zebra language definition ────────────────────────────────────────────────
// Zebra is indentation-significant, # comments, " strings, no preprocessor.
static TextEditor::LanguageDefinition makeZebraLang() {
    TextEditor::LanguageDefinition lang;
    lang.mName             = "Zebra";
    lang.mSingleLineComment = "#";
    lang.mCommentStart     = "";
    lang.mCommentEnd       = "";
    lang.mPreprocChar      = '\0';
    lang.mAutoIndentation  = true;
    lang.mCaseSensitive    = true;
    lang.mTokenize         = nullptr;

    static const char* kKeywords[] = {
        "def", "var", "class", "struct", "interface", "extend", "namespace",
        "if", "else", "elif", "while", "for", "in", "return",
        "nil", "true", "false",
        "and", "or", "not", "is", "as",
        "with", "capture", "throws", "raise", "try", "catch",
        "use", "static", "new", "this",
        "break", "continue",
        "branch", "on", "to",
        "ensure", "old",
        "guard", "orelse", "arena",
        nullptr
    };
    for (int i = 0; kKeywords[i]; ++i)
        lang.mKeywords.insert(kKeywords[i]);

    // Regex token rules: order matters — checked front to back.
    using PI = TextEditor::PaletteIndex;
    lang.mTokenRegexStrings = {
        { "0[xX][0-9a-fA-F]+",                          PI::Number      },
        { "[0-9]+[.][0-9]*([eE][+-]?[0-9]+)?[fF]?",    PI::Number      },
        { "[0-9]+",                                      PI::Number      },
        { "\"([^\"\\\\]|\\\\.)*\"",                     PI::String      },
        { "'([^'\\\\]|\\\\.)'",                         PI::CharLiteral },
        { "[a-zA-Z_][a-zA-Z0-9_]*",                     PI::Identifier  },
        { "[\\[\\]\\{\\}\\!\\%\\^\\&\\*\\(\\)\\-\\+\\=\\~\\|\\<\\>\\?\\/\\;\\,\\.]",
                                                         PI::Punctuation },
    };

    return lang;
}

// ── extern "C" surface ───────────────────────────────────────────────────────
extern "C" {

TE_Handle te_create(void) {
    static TextEditor::LanguageDefinition s_zebra = makeZebraLang();
    auto* w = new TE_Wrapper();
    w->editor.SetLanguageDefinition(s_zebra);
    return w;
}

void te_destroy(TE_Handle h) {
    delete static_cast<TE_Wrapper*>(h);
}

void te_set_text(TE_Handle h, const char* text) {
    static_cast<TE_Wrapper*>(h)->editor.SetText(text ? text : "");
}

const char* te_get_text(TE_Handle h) {
    auto* w = static_cast<TE_Wrapper*>(h);
    w->text_buf = w->editor.GetText();
    return w->text_buf.c_str();
}

void te_set_language(TE_Handle h, const char* lang) {
    if (!lang || lang[0] == '\0') return;
    auto* w = static_cast<TE_Wrapper*>(h);
    if (strcmp(lang, "zebra") == 0) {
        static TextEditor::LanguageDefinition s_zebra = makeZebraLang();
        w->editor.SetLanguageDefinition(s_zebra);
    } else if (strcmp(lang, "cpp") == 0) {
        w->editor.SetLanguageDefinition(TextEditor::LanguageDefinition::CPlusPlus());
    } else if (strcmp(lang, "c") == 0) {
        w->editor.SetLanguageDefinition(TextEditor::LanguageDefinition::C());
    } else if (strcmp(lang, "glsl") == 0) {
        w->editor.SetLanguageDefinition(TextEditor::LanguageDefinition::GLSL());
    } else if (strcmp(lang, "lua") == 0) {
        w->editor.SetLanguageDefinition(TextEditor::LanguageDefinition::Lua());
    } else if (strcmp(lang, "sql") == 0) {
        w->editor.SetLanguageDefinition(TextEditor::LanguageDefinition::SQL());
    }
}

void te_render(TE_Handle h, const char* id, float w, float ht) {
    static_cast<TE_Wrapper*>(h)->editor.Render(id, ImVec2(w, ht));
}

void te_clear_errors(TE_Handle h) {
    auto* w = static_cast<TE_Wrapper*>(h);
    w->errors.clear();
    w->editor.SetErrorMarkers(w->errors);
}

void te_add_error(TE_Handle h, int line, const char* msg) {
    auto* w = static_cast<TE_Wrapper*>(h);
    w->errors[line] = msg ? msg : "";
    w->editor.SetErrorMarkers(w->errors);
}

void te_set_readonly(TE_Handle h, int readonly) {
    static_cast<TE_Wrapper*>(h)->editor.SetReadOnly(readonly != 0);
}

int te_is_readonly(TE_Handle h) {
    return static_cast<TE_Wrapper*>(h)->editor.IsReadOnly() ? 1 : 0;
}

int te_get_cursor_line(TE_Handle h) {
    return static_cast<TE_Wrapper*>(h)->editor.GetCursorPosition().mLine + 1;
}

int te_get_cursor_col(TE_Handle h) {
    return static_cast<TE_Wrapper*>(h)->editor.GetCursorPosition().mColumn + 1;
}

void te_set_cursor_position(TE_Handle h, int line, int col) {
    TextEditor::Coordinates pos(line > 0 ? line - 1 : 0, col > 0 ? col - 1 : 0);
    static_cast<TE_Wrapper*>(h)->editor.SetCursorPosition(pos);
}

} // extern "C"
