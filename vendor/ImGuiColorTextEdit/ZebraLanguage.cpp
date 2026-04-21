#include "ZebraLanguage.h"

const TextEditor::Language* ZebraLanguage() {
    static bool initialized = false;
    static TextEditor::Language language;

    if (!initialized) {
        language.name = "Zebra";
        language.caseSensitive = true;

        // Comments
        language.singleLineComment = "#";
        // No block comments in Zebra

        // Strings
        language.hasDoubleQuotedStrings = true;  // "hello ${name}"
        language.hasSingleQuotedStrings = true;  // 'a'  (char literal)
        language.stringEscape = '\\';

        // Raw strings: r"..." — use otherString slots
        // The closing delimiter matches the opening so we use the same marker.
        language.otherStringStart = "r\"";
        language.otherStringEnd   = "\"";

        // Control flow and structural keywords
        static const char* const keywords[] = {
            "def",      "class",    "var",      "if",       "else",
            "for",      "in",       "while",    "return",   "raise",
            "throws",   "try",      "catch",    "branch",   "on",
            "as",       "capture",  "shared",   "use",      "nil",
            "true",     "false",    "and",      "or",       "not",
            "is",       "with",     "guard",    "arena",    "extend",
            "interface","expose",   "this",     "same",     "orelse",
            "continue", "break",    "get",      "post",     "namespace",
        };
        for (auto kw : keywords) language.keywords.insert(kw);

        // Builtin type names (colored as declarations/types)
        static const char* const types[] = {
            // Scalar primitives
            "int",      "float",    "bool",     "str",      "String",
            "char",     "void",     "num",      "decimal",  "dynamic",
            "object",   "same",
            // Sized integers
            "int8",     "int16",    "int32",    "int64",    "int128",
            "uint",     "uint8",    "uint16",   "uint32",   "uint64",   "uint128",
            "byte",     "size",
            // Sized floats
            "float16",  "float32",  "float64",  "float128",
            // Stdlib containers
            "List",     "HashMap",  "StringBuilder",
            // Stdlib I/O and path
            "File",     "Dir",      "Path",
            // Stdlib process / shell
            "Shell",    "SysRunResult",
            // Stdlib networking
            "Http",     "HttpRequest", "HttpResponse",
            "Tcp",      "TcpConn",  "Udp",      "UdpSocket", "Net",
            // Stdlib math + data
            "Math",     "Json",     "JsonValue", "Regex",
            "Csv",      "CsvWriter","DateTime", "CalendarView",
            // Stdlib utilities
            "Reflect",  "Hash",     "Random",
            "Arg",      "ArgResult","Terminal", "Log",
            "Uri",      "UriResult","Compress", "Mime",
            "Timer",    "TimerHandle",
            // GUI
            "Gui",      "CodeEditor",
            // System
            "sys",
            // Error handling
            "Result",
        };
        for (auto t : types) language.declarations.insert(t);

        // Custom tokenizer: highlight ^ (heap-pointer prefix) and ? (optional suffix)
        // as punctuation so they stand out from identifier text.
        language.customTokenizer = [](
            TextEditor::Language::Iterator start,
            TextEditor::Language::Iterator end,
            TextEditor::Color& color) -> TextEditor::Language::Iterator
        {
            (void)end;
            ImWchar cp = start->codepoint;
            if (cp == '^' || cp == '?') {
                color = TextEditor::PaletteIndex::Punctuation;
                return start + 1;
            }
            return start;  // no match
        };

        initialized = true;
    }

    return &language;
}
