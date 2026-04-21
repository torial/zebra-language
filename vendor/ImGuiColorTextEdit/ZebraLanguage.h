#pragma once
#include "TextEditor.h"

// Returns a TextEditor Language definition for the Zebra programming language.
// Call once; the result is a static singleton.
const TextEditor::Language* ZebraLanguage();
