// gui_libui_ng_section.v -- the libui-ng GUI backend for the V target (proof of
// concept, 2026-10-14). Appended to a `zebra --target v` emission when the
// program is a GUI program (`--gui-backend=libui_ng`), as the Zig target appends
// selfhost/gui_libui_ng_section.zig.
//
// What it is: Zebra's Gui is immediate-mode over an MVU loop (the preamble's
// _gui_mvu_run): each frame the program's `view(g, model)` declares the widgets
// it wants, and the backend owns how they persist. libui-ng is retained: a
// widget lives until destroyed. So the section keeps the last frame's widget
// list and DIFFS the new one against it in order -- the same kinds and labels
// in the same places reuse their controls (a label's text, a field's text, a
// spinbox's value, a toggle's state updated in place when the model's differs);
// any difference in the shape rebuilds the window's content from scratch. A
// frame runs after each event (uiMainStep waits), and once more without
// waiting when the previous frame sent a message, so the updated model is
// drawn at once.
//
// Messages: `g.button(label, msg)` takes the program's own Msg type (a V sum
// type here), which this file cannot name; the generic method copies the
// value's bytes (memdup, sizeof(T)) into the queue, and the generic run loop
// reads them back as G. A widget with a value (`g.field(label, text, on)`)
// takes a closure `on` from the value to a Msg; the generic method wraps it in
// a closure that sends the Msg, and the control's callback runs that.
//
// Containers: begin_form / end_form (libui's uiForm: labels left, controls
// right), begin_hbox / end_hbox, begin_vbox / end_vbox, begin_panel / end_panel
// (a uiGroup). A control without its own label (field, spinbox, slider,
// progress bar) gets a label beside it, or its form row's label inside a form.
//
// Also: tabs (a page is a box appended to a uiTab), combobox and radio (items,
// a selection, a sender), menus (declared in the first frame and built BEFORE
// the window, libui's order, so the window itself is made at the first commit;
// later declarations are ignored), and the vbox / hbox handles that `using`
// binds (begin / end).
//
// And tables: `beginTable(id, cols)` / `tableSetupColumn` / `tableNextRow` /
// `tableNextColumn` / `g.text` as the cell / `endTable`, a uiTable over a model
// whose rows the view fills each frame (libui told row by row what changed);
// `tableSelectedRow`, `tableActivatedRow` (a double-click, read once).
//
// And, on the FORK checkout (zig-libui-ng/libui, which has them; the plain
// libui-ng does not): trees (`beginTree` with the three closures, `treeNode`,
// `treeLeaf`, their Icon forms, `treePop`, `endTree`: the fork's keyed model
// over this frame's nodes, the same structure updated in place, a changed one
// rebuilt), the toolbar (a strip the window holds, its items re-appended when
// the labels change, enabled per frame), tooltips on the widget declared just
// before, the clipboard (`Gui.setClipboardText` / `clipboardText`) and
// `Gui.registerIcon` (queued until libui is initialised; an unregistered icon
// name is drawn without and said once: the Zig section's built-in set is not
// here).
//
// And the editable combobox, the dialogs (openFile / saveFile / openFolder,
// msgBox / msgBoxError: libui's modal ones, or, scripted, the next `dialog:`
// answer and a line in the trace) and the built-in icon set (folder, file,
// dot, warn: the Zig section's painters, premultiplied as libui wants, which
// registerIcon's bytes now are too).
//
// And the table's check, edit and button columns (`tableSetupCheckColumn` /
// `EditColumn` / `ButtonColumn`, each with the program's closure for the
// row's toggle, edit or click; a check cell is `tableCheck`): libui's
// SetCellValue is dispatched by column to the closure and the model is not
// changed there -- the message goes to update and the next frame's rows carry
// the answer.
//
// And drawing: `area(id, w, h, draw, onClick)` and `canvas(id, w, h, draw,
// onMouse, onKey)`, the draw closure run inside libui's draw callback with the
// paint context and the area's size held in the state, `line` / `rect` /
// `fillRect` / `circle` / `fillCircle` / `drawText` as paths with a solid
// brush and round strokes (a 0xRRGGBB colour), text through an attributed
// string and the control font; mouse and key events to the program's closures
// as the Zig section numbers them; a redraw queued every frame, since a V
// closure's captures cannot be compared (the Zig section redraws only when
// they changed). The trace names what the last draw painted.
//
// And the CodeEditor, over the fork's Scintilla shim (zig-libui-ng/
// libui_scintilla, the sci_native archive): `CodeEditor.forZebra()` /
// `forFile` / `forLanguage` / `new`, `setText` / `getText` (the text lives in
// the control while the window holds it, and is pulled back before a rebuild
// destroys it), `setReadOnly`, the cursor line and column, `setCursorPosition`,
// the recorded events `takeModified` / `takeCharAdded` / `takeMarginClick`,
// `hotkey` / `takeKey` (chords through the shim's key hook), `render` placing
// it as a node keyed by the record's address. Syntax styling is the Zig
// section's tokenizer ported (`zgui_ce_tokenize`: one tokenizer reading a
// language spec -- zebra, c, zig, text -- one style byte per source byte,
// sent as SCI_SETSTYLINGEX after a set and whenever the end-styled watermark
// says an edit moved it back, polled per frame); `setErrorMarkers` is
// accepted and said.
//
// Window hotkeys: `g.hotkey(vk, mods)` registers a chord ((mods << 16) | vk,
// Ctrl 1 / Shift 2 / Alt 4 as the fork's uiWindowOnKey passes them) and the
// window's key hook consumes a registered one before the focused control
// sees it, queued for `g.takeKey()` in order. `g.minSize(id, w, h)` sets the
// minimum size of the keyed container built last frame (uiControlSetMinSize).
// The CodeEditor's hatch `sci(msg, w, l)` / `sciStr(msg, w, text)` sends any
// Scintilla message to the control (0 before it exists, as the Zig section).
//
// Test hook: ZGUI_SCRIPT drives the window without a mouse, one action per
// frame after the first draw: `click:<label>`, `toggle:<label>`,
// `set:<label>=<text>` (a field), `spin:<label>=<n>`, `slide:<label>=<x>`,
// `pick:<label>=<index>` (a combobox or radio), `tab:<id>=<index>`,
// `menu:<label>` (a menu item), `dblclick:<table id>=<row>`,
// `select:<table id>=<row>`, `tool:<label>`, `treesel:<id>=<key>`,
// `treeact:<id>=<key>`, `treeexp:<id>=<key>=<0|1>`, `dialog:<path>` (what the
// next file dialog returns; empty = cancelled), `cellcheck:<id>=<row>=<0|1>`,
// `celledit:<id>=<row>=<text>`, `cellbutton:<id>=<row>`,
// `mouse:<id>=<ev>,<x>,<y>,<b>` (an area: ev 1 is a click; a canvas: 1 press
// 2 release 3 move 4 enter 5 leave), `key:<id>=<vk>,<mods>,<0|1>`,
// `edtype:<text>` (appended to the first editor through Scintilla, so the
// modified event fires), `edkey:<vk>,<mods>` (a chord to its key hook),
// `edmargin:<line>` (a margin click), `tick` (every timer fires once), `quit`.
// ZGUI_TRACE=1 prints each frame's widgets with their values, so a test reads
// what the window shows.

// the library: `zig build -Doptimize=ReleaseFast -p zig-out-fast` in libui-ng --
// zig's Debug build instruments the C with the undefined-behaviour sanitizer, and
// that archive wants the sanitizer runtime at link (284 references)
#flag -I $env('ZEBRA_LIBUI_NG')
#flag -L $env('ZEBRA_LIBUI_NG')/zig-out-fast/lib
#flag -lui
// (-static -lc++: libui-ng's Windows backend has C++ in it; the C driver does not
// add the C++ runtime, and static keeps llvm-mingw's DLLs out of the exe)
#flag windows -static -lc++ -luser32 -lkernel32 -lgdi32 -lcomctl32 -luxtheme -lmsimg32 -lcomdlg32 -ld2d1 -ldwrite -lole32 -loleaut32 -loleacc -luuid -lwindowscodecs
#include "ui.h"
// the Scintilla shim and Scintilla itself sit beside the fork checkout
// (zig-libui-ng/libui_scintilla, zig-libui-ng/scintilla); the archive is
// sci_native, installed by the fork's build into zig-out-fast/lib
#flag -I $env('ZEBRA_LIBUI_NG')/../libui_scintilla/include
#flag -I $env('ZEBRA_LIBUI_NG')/../scintilla/include
#flag -L $env('ZEBRA_LIBUI_NG')/../zig-out-fast/lib
#flag -lsci_native
#flag windows -limm32
#include "Scintilla.h"
#include "ui_scintilla.h"

struct C.uiInitOptions {
	Size usize
}
struct C.uiControl {}
struct C.uiWindow {}
struct C.uiBox {}
struct C.uiForm {}
struct C.uiGroup {}
struct C.uiButton {}
struct C.uiLabel {}
struct C.uiSeparator {}
struct C.uiCheckbox {}
struct C.uiEntry {}
struct C.uiSpinbox {}
struct C.uiSlider {}
struct C.uiProgressBar {}
struct C.uiTab {}
struct C.uiCombobox {}
struct C.uiRadioButtons {}
struct C.uiMenu {}
struct C.uiMenuItem {}
struct C.uiTable {}
struct C.uiTableModel {}
struct C.uiTableValue {}

// libui's model handler: five function pointers in this order; the handler
// is the FIRST field of ZGuiTable so a callback finds its table from the
// handler pointer it is given
struct C.uiTableModelHandler {
pub mut:
	NumColumns   fn (&C.uiTableModelHandler, &C.uiTableModel) int
	ColumnType   fn (&C.uiTableModelHandler, &C.uiTableModel, int) int
	NumRows      fn (&C.uiTableModelHandler, &C.uiTableModel) int
	CellValue    fn (&C.uiTableModelHandler, &C.uiTableModel, int, int) &C.uiTableValue
	SetCellValue fn (&C.uiTableModelHandler, &C.uiTableModel, int, int, &C.uiTableValue)
}

struct C.uiTableParams {
pub mut:
	Model                        &C.uiTableModel
	RowBackgroundColorModelColumn int
}

struct C.uiTableSelection {
pub mut:
	NumRows int
	Rows    &int
}
struct C.uiTree {}
struct C.uiTreeModel {}
struct C.uiToolbar {}
struct C.uiImage {}
struct C.uiEditableCombobox {}
struct C.uiScintilla {}

struct C.Sci_NotifyHeader {
pub mut:
	hwndFrom voidptr
	idFrom   usize
	code     u32
}

// Scintilla's notification (the layout is the header's; these are the fields read)
struct C.SCNotification {
pub mut:
	nmhdr            C.Sci_NotifyHeader
	position         isize
	ch               int
	modifiers        int
	modificationType int
	text             &char
	length           isize
	linesAdded       isize
	message          int
	wParam           usize
	lParam           isize
	line             isize
	foldLevelNow     int
	foldLevelPrev    int
	margin           int
}
struct C.uiArea {}
struct C.uiDrawContext {}
struct C.uiDrawPath {}
struct C.uiAttributedString {}
struct C.uiAttribute {}
struct C.uiDrawTextLayout {}

// libui's area handler: five function pointers, first in ZGuiArea
struct C.uiAreaHandler {
pub mut:
	Draw         fn (&C.uiAreaHandler, &C.uiArea, &C.uiAreaDrawParams)
	MouseEvent   fn (&C.uiAreaHandler, &C.uiArea, &C.uiAreaMouseEvent)
	MouseCrossed fn (&C.uiAreaHandler, &C.uiArea, int)
	DragBroken   fn (&C.uiAreaHandler, &C.uiArea)
	KeyEvent     fn (&C.uiAreaHandler, &C.uiArea, &C.uiAreaKeyEvent) int
}

struct C.uiAreaDrawParams {
pub mut:
	Context    &C.uiDrawContext
	AreaWidth  f64
	AreaHeight f64
	ClipX      f64
	ClipY      f64
	ClipWidth  f64
	ClipHeight f64
}

struct C.uiAreaMouseEvent {
pub mut:
	X          f64
	Y          f64
	AreaWidth  f64
	AreaHeight f64
	Down       int
	Up         int
	Count      int
	Modifiers  int
	Held1To64  u64
}

struct C.uiAreaKeyEvent {
pub mut:
	Key       i8
	ExtKey    int
	Modifier  int
	Modifiers int
	Up        int
}

struct C.uiDrawBrushGradientStop {
pub mut:
	Pos f64
	R   f64
	G   f64
	B   f64
	A   f64
}

struct C.uiDrawBrush {
pub mut:
	Type        int
	R           f64
	G           f64
	B           f64
	A           f64
	X0          f64
	Y0          f64
	X1          f64
	Y1          f64
	OuterRadius f64
	Stops       &C.uiDrawBrushGradientStop
	NumStops    usize
}

struct C.uiDrawStrokeParams {
pub mut:
	Cap        int
	Join       int
	Thickness  f64
	MiterLimit f64
	Dashes     &f64
	NumDashes  usize
}

struct C.uiFontDescriptor {
pub mut:
	Family  &char
	Size    f64
	Weight  int
	Italic  int
	Stretch int
}

struct C.uiDrawTextLayoutParams {
pub mut:
	String      &C.uiAttributedString
	DefaultFont &C.uiFontDescriptor
	Width       f64
	Align       int
}

// the fork's tree model handler: five function pointers, first in ZGuiTree
struct C.uiTreeModelHandler {
pub mut:
	NumChildren fn (&C.uiTreeModelHandler, &C.uiTreeModel, voidptr) int
	Child       fn (&C.uiTreeModelHandler, &C.uiTreeModel, voidptr, int) voidptr
	Text        fn (&C.uiTreeModelHandler, &C.uiTreeModel, voidptr) &char
	HasChildren fn (&C.uiTreeModelHandler, &C.uiTreeModel, voidptr) int
	Icon        fn (&C.uiTreeModelHandler, &C.uiTreeModel, voidptr) &C.uiImage
}

fn C.uiInit(o &C.uiInitOptions) &char
fn C.uiFreeInitError(e &char)
fn C.uiFreeText(t &char)
fn C.uiMainStep(wait int) int
fn C.uiQuit()
fn C.uiTimer(ms int, f fn (voidptr) int, data voidptr)
fn C.uiControlShow(c &C.uiControl)
fn C.uiControlDestroy(c &C.uiControl)
fn C.uiNewWindow(title &char, width int, height int, has_menubar int) &C.uiWindow
fn C.uiWindowSetChild(w &C.uiWindow, child &C.uiControl)
fn C.uiWindowSetMargined(w &C.uiWindow, margined int)
fn C.uiWindowOnClosing(w &C.uiWindow, f fn (&C.uiWindow, voidptr) int, data voidptr)
fn C.uiWindowOnKey(w &C.uiWindow, f fn (&C.uiWindow, int, int, voidptr) int, data voidptr)
fn C.uiNewVerticalBox() &C.uiBox
fn C.uiNewHorizontalBox() &C.uiBox
fn C.uiBoxAppend(b &C.uiBox, child &C.uiControl, stretchy int)
fn C.uiBoxSetPadded(b &C.uiBox, padded int)
fn C.uiBoxDelete(b &C.uiBox, index int)
fn C.uiNewForm() &C.uiForm
fn C.uiFormAppend(f &C.uiForm, label &char, child &C.uiControl, stretchy int)
fn C.uiFormSetPadded(f &C.uiForm, padded int)
fn C.uiNewGroup(title &char) &C.uiGroup
fn C.uiGroupSetChild(g &C.uiGroup, child &C.uiControl)
fn C.uiGroupSetMargined(g &C.uiGroup, margined int)
fn C.uiNewButton(text &char) &C.uiButton
fn C.uiButtonOnClicked(b &C.uiButton, f fn (&C.uiButton, voidptr), data voidptr)
fn C.uiNewLabel(text &char) &C.uiLabel
fn C.uiLabelSetText(l &C.uiLabel, text &char)
fn C.uiNewHorizontalSeparator() &C.uiSeparator
fn C.uiNewCheckbox(text &char) &C.uiCheckbox
fn C.uiCheckboxChecked(c &C.uiCheckbox) int
fn C.uiCheckboxSetChecked(c &C.uiCheckbox, checked int)
fn C.uiCheckboxOnToggled(c &C.uiCheckbox, f fn (&C.uiCheckbox, voidptr), data voidptr)
fn C.uiNewEntry() &C.uiEntry
fn C.uiEntryText(e &C.uiEntry) &char
fn C.uiEntrySetText(e &C.uiEntry, text &char)
fn C.uiEntryOnChanged(e &C.uiEntry, f fn (&C.uiEntry, voidptr), data voidptr)
fn C.uiNewSpinbox(min int, max int) &C.uiSpinbox
fn C.uiSpinboxValue(s &C.uiSpinbox) int
fn C.uiSpinboxSetValue(s &C.uiSpinbox, value int)
fn C.uiSpinboxOnChanged(s &C.uiSpinbox, f fn (&C.uiSpinbox, voidptr), data voidptr)
fn C.uiNewSlider(min int, max int) &C.uiSlider
fn C.uiSliderValue(s &C.uiSlider) int
fn C.uiSliderSetValue(s &C.uiSlider, value int)
fn C.uiSliderOnChanged(s &C.uiSlider, f fn (&C.uiSlider, voidptr), data voidptr)
fn C.uiNewProgressBar() &C.uiProgressBar
fn C.uiProgressBarSetValue(p &C.uiProgressBar, n int)
fn C.uiNewTab() &C.uiTab
fn C.uiTabAppend(t &C.uiTab, name &char, c &C.uiControl)
fn C.uiTabSetMargined(t &C.uiTab, index int, margined int)
fn C.uiTabSelected(t &C.uiTab) int
fn C.uiTabSetSelected(t &C.uiTab, index int)
fn C.uiNewCombobox() &C.uiCombobox
fn C.uiComboboxAppend(c &C.uiCombobox, text &char)
fn C.uiComboboxSelected(c &C.uiCombobox) int
fn C.uiComboboxSetSelected(c &C.uiCombobox, index int)
fn C.uiComboboxOnSelected(c &C.uiCombobox, f fn (&C.uiCombobox, voidptr), data voidptr)
fn C.uiNewRadioButtons() &C.uiRadioButtons
fn C.uiRadioButtonsAppend(r &C.uiRadioButtons, text &char)
fn C.uiRadioButtonsSelected(r &C.uiRadioButtons) int
fn C.uiRadioButtonsSetSelected(r &C.uiRadioButtons, index int)
fn C.uiRadioButtonsOnSelected(r &C.uiRadioButtons, f fn (&C.uiRadioButtons, voidptr), data voidptr)
fn C.uiNewMenu(name &char) &C.uiMenu
fn C.uiMenuAppendItem(m &C.uiMenu, name &char) &C.uiMenuItem
fn C.uiMenuAppendQuitItem(m &C.uiMenu) &C.uiMenuItem
fn C.uiMenuAppendSeparator(m &C.uiMenu)
fn C.uiMenuItemOnClicked(mi &C.uiMenuItem, f fn (&C.uiMenuItem, &C.uiWindow, voidptr), data voidptr)
fn C.uiOnShouldQuit(f fn (voidptr) int, data voidptr)
fn C.uiNewTableValueString(str &char) &C.uiTableValue
fn C.uiNewTableModel(mh &C.uiTableModelHandler) &C.uiTableModel
fn C.uiFreeTableModel(m &C.uiTableModel)
fn C.uiTableModelRowInserted(m &C.uiTableModel, new_index int)
fn C.uiTableModelRowChanged(m &C.uiTableModel, index int)
fn C.uiTableModelRowDeleted(m &C.uiTableModel, old_index int)
fn C.uiNewTable(params &C.uiTableParams) &C.uiTable
fn C.uiTableAppendTextColumn(t &C.uiTable, name &char, text_model_column int, text_editable_model_column int, text_params voidptr)
fn C.uiTableAppendCheckboxColumn(t &C.uiTable, name &char, checkbox_model_column int, checkbox_editable_model_column int)
fn C.uiTableAppendButtonColumn(t &C.uiTable, name &char, button_model_column int, button_clickable_model_column int)
fn C.uiNewTableValueInt(i int) &C.uiTableValue
fn C.uiFreeTableValue(v &C.uiTableValue)
fn C.uiTableValueInt(v &C.uiTableValue) int
fn C.uiTableValueString(v &C.uiTableValue) &char

const zgui_table_value_int = 2 // uiTableValueTypeInt (String, Image, Int, Color)
const zgui_column_always_editable = -2 // uiTableModelColumnAlwaysEditable
fn C.uiTableOnRowDoubleClicked(t &C.uiTable, f fn (&C.uiTable, int, voidptr), data voidptr)
fn C.uiTableGetSelection(t &C.uiTable) &C.uiTableSelection
fn C.uiTableSetSelection(t &C.uiTable, sel &C.uiTableSelection)
fn C.uiFreeTableSelection(sel &C.uiTableSelection)

const zgui_table_value_string = 0 // uiTableValueTypeString, the enum's first

fn C.uiNewTreeModel(mh &C.uiTreeModelHandler) &C.uiTreeModel
fn C.uiFreeTreeModel(m &C.uiTreeModel)
fn C.uiTreeModelNodeChanged(m &C.uiTreeModel, node voidptr)
fn C.uiNewTree(m &C.uiTreeModel) &C.uiTree
fn C.uiTreeSetExpanded(t &C.uiTree, node voidptr, expanded int)
fn C.uiTreeExpanded(t &C.uiTree, node voidptr) int
fn C.uiTreeSelection(t &C.uiTree) voidptr
fn C.uiTreeSetSelection(t &C.uiTree, node voidptr)
fn C.uiTreeOnSelectionChanged(t &C.uiTree, f fn (&C.uiTree, voidptr), data voidptr)
fn C.uiTreeOnNodeActivated(t &C.uiTree, f fn (&C.uiTree, voidptr, voidptr), data voidptr)
fn C.uiTreeOnNodeExpanded(t &C.uiTree, f fn (&C.uiTree, voidptr, int, voidptr), data voidptr)
fn C.uiControlSetTooltip(c &C.uiControl, text &char)
fn C.uiClipboardText() &char
fn C.uiClipboardSetText(text &char)
fn C.uiNewToolbar() &C.uiToolbar
fn C.uiWindowSetToolbar(w &C.uiWindow, t &C.uiToolbar)
fn C.uiToolbarAppendItem(t &C.uiToolbar, label &char, icon &C.uiImage, tooltip &char) int
fn C.uiToolbarAppendSeparator(t &C.uiToolbar) int
fn C.uiToolbarClear(t &C.uiToolbar)
fn C.uiToolbarSetItemEnabled(t &C.uiToolbar, index int, enabled int)
fn C.uiToolbarOnClicked(t &C.uiToolbar, f fn (&C.uiToolbar, int, voidptr), data voidptr)
fn C.uiNewImage(width f64, height f64) &C.uiImage
fn C.uiNewArea(ah &C.uiAreaHandler) &C.uiArea
fn C.uiAreaQueueRedrawAll(a &C.uiArea)
fn C.uiControlSetMinSize(c &C.uiControl, width int, height int)
fn C.uiDrawNewPath(fill_mode int) &C.uiDrawPath
fn C.uiDrawFreePath(p &C.uiDrawPath)
fn C.uiDrawPathNewFigure(p &C.uiDrawPath, x f64, y f64)
fn C.uiDrawPathNewFigureWithArc(p &C.uiDrawPath, x_center f64, y_center f64, radius f64, start_angle f64, sweep f64, negative int)
fn C.uiDrawPathLineTo(p &C.uiDrawPath, x f64, y f64)
fn C.uiDrawPathCloseFigure(p &C.uiDrawPath)
fn C.uiDrawPathAddRectangle(p &C.uiDrawPath, x f64, y f64, width f64, height f64)
fn C.uiDrawPathEnd(p &C.uiDrawPath)
fn C.uiDrawStroke(c &C.uiDrawContext, path &C.uiDrawPath, b &C.uiDrawBrush, p &C.uiDrawStrokeParams)
fn C.uiDrawFill(c &C.uiDrawContext, path &C.uiDrawPath, b &C.uiDrawBrush)
fn C.uiNewAttributedString(initial &char) &C.uiAttributedString
fn C.uiFreeAttributedString(s &C.uiAttributedString)
fn C.uiAttributedStringLen(s &C.uiAttributedString) usize
fn C.uiAttributedStringSetAttribute(s &C.uiAttributedString, a &C.uiAttribute, start usize, end usize)
fn C.uiNewColorAttribute(r f64, g f64, b f64, a f64) &C.uiAttribute
fn C.uiLoadControlFont(f &C.uiFontDescriptor)
fn C.uiFreeFontDescriptor(desc &C.uiFontDescriptor)
fn C.uiDrawNewTextLayout(params &C.uiDrawTextLayoutParams) &C.uiDrawTextLayout
fn C.uiDrawFreeTextLayout(tl &C.uiDrawTextLayout)
fn C.uiDrawText(c &C.uiDrawContext, tl &C.uiDrawTextLayout, x f64, y f64)

const zgui_draw_fill_winding = 0 // uiDrawFillModeWinding
const zgui_brush_solid = 0 // uiDrawBrushTypeSolid
const zgui_line_cap_round = 1 // uiDrawLineCapRound
const zgui_line_join_round = 1 // uiDrawLineJoinRound
const zgui_text_align_left = 0 // uiDrawTextAlignLeft
const zgui_pi = 3.141592653589793

fn C.uiNewScintilla() &C.uiScintilla
fn C.uiScintillaSetText(s &C.uiScintilla, text &char, len u32)
fn C.uiScintillaGetLength(s &C.uiScintilla) u32
fn C.uiScintillaGetRange(s &C.uiScintilla, start u32, end u32, text &char)
fn C.uiScintillaSendMessage(s &C.uiScintilla, code u32, w usize, l usize) usize
fn C.uiScintillaOnNotify(s &C.uiScintilla, f fn (&C.uiScintilla, &C.SCNotification, voidptr), data voidptr)
fn C.uiScintillaOnKey(s &C.uiScintilla, f fn (&C.uiScintilla, int, int, voidptr) int, data voidptr)

// the Scintilla messages the editor sends (scintilla/include/Scintilla.h)
const zsci_setcodepage = u32(2037)
const zsci_stylesetfont = u32(2056)
const zsci_stylesetsize = u32(2055)
const zsci_stylesetfore = u32(2051)
const zsci_stylesetback = u32(2052)
const zsci_styleclearall = u32(2050)
const zsci_setmargintypen = u32(2240)
const zsci_setmarginwidthn = u32(2242)
const zsci_setmarginsensitiven = u32(2246)
const zsci_setcaretlinevisible = u32(2096)
const zsci_setcaretlineback = u32(2098)
const zsci_setselback = u32(2068)
const zsci_settabwidth = u32(2036)
const zsci_setreadonly = u32(2171)
const zsci_getcurrentpos = u32(2008)
const zsci_linefromposition = u32(2166)
const zsci_getcolumn = u32(2129)
const zsci_gotoline = u32(2024)
const zsci_appendtext = u32(2282)
const zsci_getlinecount = u32(2154)
const zsci_getendstyled = u32(2028)
const zsci_startstyling = u32(2032)
const zsci_setstylingex = u32(2073)
const zsci_getstyleat = u32(2010)
const zscn_charadded = u32(2001)
const zscn_modified = u32(2008)
const zscn_marginclick = u32(2010)
const zsc_mod_inserttext = 0x1
const zsc_mod_deletetext = 0x2
// the One Dark colours the Zig section configures, as Scintilla's 0xBBGGRR
const zsci_c_bg = usize(0x342c28)
const zsci_c_fg = usize(0xbfb2ab)
const zsci_c_lnfg = usize(0x63524b)
const zsci_c_lnbg = usize(0x2f2823)
const zsci_c_caretln = usize(0x3e3630)
const zsci_c_sel = usize(0x584c3f)

// style slots (32 and 33 are Scintilla's own: STYLE_DEFAULT, STYLE_LINENUMBER)
const zsci_s_default = u8(0)
const zsci_s_keyword = u8(1)
const zsci_s_comment = u8(2)
const zsci_s_string = u8(3)
const zsci_s_number = u8(4)
const zsci_s_type = u8(5)
const zsci_s_func = u8(6)
const zsci_s_op = u8(7)
const zsci_s_preproc = u8(8)

// Scintilla colours are 0xBBGGRR, not RGB (One Dark, as the Zig section)
const zsci_c_keyword = usize(0xdd78c6) // #c678dd
const zsci_c_comment = usize(0x70635c) // #5c6370
const zsci_c_string = usize(0x79c398) // #98c379
const zsci_c_number = usize(0x669ad1) // #d19a66
const zsci_c_type = usize(0x7bc0e5) // #e5c07b
const zsci_c_func = usize(0xefaf61) // #61afef
const zsci_c_op = usize(0xc2b656) // #56b6c2
const zsci_c_preproc = usize(0x9a7de0) // #e07d9a

// A language is DATA: which comment and string forms exist and which words are
// keywords. The one tokenizer (`zgui_ce_tokenize`) reads a spec; adding a
// language is adding a spec, not a tokenizer. The Zig section's tables.
struct ZCeLangSpec {
	name          string
	keywords      []string
	line_comment  string // '#' or '//'; '' = none
	block_comment bool   // C-style /* ... */
	preproc       bool   // '#' at a line's start (after blanks) is a preprocessor line
	char_lit      bool   // 'x' is a char literal (C, Zig), else ' is an operator
	zig_multiline bool   // a `\\` line is a multiline-string line (Zig)
	builtin_at    bool   // `@name` is a builtin call (Zig)
	caps_are_types bool  // a capitalised identifier is a type (Zebra, Zig)
}

const zce_kw_zebra = ['abstract', 'adds', 'allocate', 'and', 'arena', 'as', 'assert', 'assert_eq',
	'assert_false', 'assert_ne', 'assert_true', 'bool', 'branch', 'break', 'capture', 'catch',
	'char', 'class', 'const', 'continue', 'cue', 'def', 'defer', 'else', 'ensure', 'enum',
	'errdefer', 'except', 'export', 'exposing', 'extend', 'extern', 'false', 'float', 'for',
	'guard', 'has', 'if', 'implements', 'implies', 'in', 'int', 'interface', 'invariant', 'is',
	'mixin', 'namespace', 'nil', 'not', 'on', 'or', 'orelse', 'pass', 'print', 'private',
	'public', 'raise', 'readonly', 'require', 'return', 'same', 'sig', 'static', 'struct',
	'test', 'this', 'throws', 'to', 'true', 'type', 'uint', 'union', 'use', 'using', 'var',
	'vari', 'where', 'while', 'with']
const zce_kw_c = ['auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do', 'double', 'else',
	'enum', 'extern', 'float', 'for', 'goto', 'if', 'inline', 'int', 'long', 'register',
	'restrict', 'return', 'short', 'signed', 'sizeof', 'static', 'struct', 'switch', 'typedef',
	'union', 'unsigned', 'void', 'volatile', 'while', '_Bool', '_Static_assert', 'bool', 'true',
	'false', 'NULL', 'size_t', 'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t', 'int8_t',
	'int16_t', 'int32_t', 'int64_t', 'uintptr_t', 'intptr_t', 'ptrdiff_t', 'ssize_t']
const zce_kw_zig = ['addrspace', 'align', 'allowzero', 'and', 'anyframe', 'anytype', 'asm', 'async', 'await',
	'break', 'callconv', 'catch', 'comptime', 'const', 'continue', 'defer', 'else', 'enum',
	'errdefer', 'error', 'export', 'extern', 'fn', 'for', 'if', 'inline', 'linksection',
	'noalias', 'noinline', 'nosuspend', 'opaque', 'or', 'orelse', 'packed', 'pub', 'resume',
	'return', 'struct', 'suspend', 'switch', 'test', 'threadlocal', 'try', 'union', 'unreachable',
	'usingnamespace', 'var', 'volatile', 'while', 'true', 'false', 'null', 'undefined',
	'void', 'bool', 'u8', 'i8', 'u16', 'i16', 'u32', 'i32', 'u64', 'i64', 'u128', 'i128',
	'usize', 'isize', 'f16', 'f32', 'f64', 'f128', 'c_int', 'c_uint', 'c_long', 'c_ulong',
	'c_char', 'c_void', 'anyerror', 'anyopaque', 'noreturn', 'comptime_int', 'comptime_float', 'type']

const zce_lang_zebra = ZCeLangSpec{
	name: 'zebra'
	keywords: zce_kw_zebra
	line_comment: '#'
	caps_are_types: true
}
const zce_lang_c = ZCeLangSpec{
	name: 'c'
	keywords: zce_kw_c
	line_comment: '//'
	block_comment: true
	preproc: true
	char_lit: true
}
const zce_lang_zig = ZCeLangSpec{
	name: 'zig'
	keywords: zce_kw_zig
	line_comment: '//'
	char_lit: true
	zig_multiline: true
	builtin_at: true
	caps_are_types: true
}
const zce_lang_plain = ZCeLangSpec{
	name: 'text'
}

// a language name or a file extension to its spec; unknown = plain, never a guess
fn zgui_ce_spec_by_name(n string) ZCeLangSpec {
	if n == 'zebra' || n == 'zbr' {
		return zce_lang_zebra
	}
	if n == 'c' || n == 'h' || n == 'cpp' || n == 'cxx' || n == 'cc' || n == 'hpp' {
		return zce_lang_c
	}
	if n == 'zig' || n == 'zon' {
		return zce_lang_zig
	}
	return zce_lang_plain
}

fn zgui_ce_spec_for_file(path string) ZCeLangSpec {
	mut i := path.len
	for i > 0 {
		c := path[i - 1]
		if c == `.` {
			return zgui_ce_spec_by_name(path[i..])
		}
		if c == `/` || c == `\\` {
			break
		}
		i--
	}
	return zce_lang_plain
}

fn zce_starts(src string, i int, pat string) bool {
	return pat.len > 0 && i + pat.len <= src.len && src[i..i + pat.len] == pat
}

fn zce_alpha(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

fn zce_digit(c u8) bool {
	return c >= `0` && c <= `9`
}

const zce_ops = '+-*/=<>!&|^~?:.,()[]{}'

fn zce_opch(c u8) bool {
	return zce_ops.index_u8(c) >= 0
}

// The tokenizer proper, the Zig section's verbatim in V: one style byte per
// source byte. Pure: no Scintilla in it.
fn zgui_ce_tokenize(spec ZCeLangSpec, src string) []u8 {
	mut out := []u8{len: src.len}
	mut i := 0
	mut line_start := true // only blanks seen since the last newline
	for i < src.len {
		start := i
		c := src[i]
		mut sty := zsci_s_default
		if c == `\n` {
			i++
			line_start = true
		} else if c == ` ` || c == `\t` || c == `\r` {
			i++
		} else if spec.preproc && line_start && c == `#` {
			for i < src.len && src[i] != `\n` {
				i++
			}
			sty = zsci_s_preproc
			line_start = false
		} else if zce_starts(src, i, spec.line_comment) {
			for i < src.len && src[i] != `\n` {
				i++
			}
			sty = zsci_s_comment
			line_start = false
		} else if spec.block_comment && zce_starts(src, i, '/*') {
			i += 2
			for i < src.len && !zce_starts(src, i, '*/') {
				i++
			}
			if i < src.len {
				i += 2
			}
			sty = zsci_s_comment
			line_start = false
		} else if spec.zig_multiline && zce_starts(src, i, '\\\\') {
			for i < src.len && src[i] != `\n` {
				i++
			}
			sty = zsci_s_string
			line_start = false
		} else if c == `"` || (spec.char_lit && c == `'`) {
			q := c
			i++
			for i < src.len && src[i] != q && src[i] != `\n` {
				if src[i] == `\\` && i + 1 < src.len {
					i++
				}
				i++
			}
			if i < src.len && src[i] == q {
				i++
			}
			sty = zsci_s_string
			line_start = false
		} else if zce_digit(c) {
			for i < src.len && (zce_digit(src[i]) || zce_alpha(src[i]) || src[i] == `.`) {
				i++
			}
			sty = zsci_s_number
			line_start = false
		} else if spec.builtin_at && c == `@` && i + 1 < src.len && zce_alpha(src[i + 1]) {
			i++
			for i < src.len && (zce_alpha(src[i]) || zce_digit(src[i])) {
				i++
			}
			sty = zsci_s_func
			line_start = false
		} else if zce_alpha(c) {
			for i < src.len && (zce_alpha(src[i]) || zce_digit(src[i])) {
				i++
			}
			w := src[start..i]
			if w in spec.keywords {
				sty = zsci_s_keyword
			} else if spec.caps_are_types && w[0] >= `A` && w[0] <= `Z` {
				sty = zsci_s_type
			} else {
				mut j := i
				for j < src.len && src[j] == ` ` {
					j++
				}
				sty = if j < src.len && src[j] == `(` { zsci_s_func } else { zsci_s_default }
			}
			line_start = false
		} else if zce_opch(c) {
			i++
			sty = zsci_s_op
			line_start = false
		} else {
			i++
			line_start = false
		}
		for k := start; k < i; k++ {
			out[k] = sty
		}
	}
	return out
}

fn C.uiNewEditableCombobox() &C.uiEditableCombobox
fn C.uiEditableComboboxAppend(c &C.uiEditableCombobox, text &char)
fn C.uiEditableComboboxText(c &C.uiEditableCombobox) &char
fn C.uiEditableComboboxSetText(c &C.uiEditableCombobox, text &char)
fn C.uiEditableComboboxOnChanged(c &C.uiEditableCombobox, f fn (&C.uiEditableCombobox, voidptr), data voidptr)
fn C.uiMsgBox(parent &C.uiWindow, title &char, description &char)
fn C.uiMsgBoxError(parent &C.uiWindow, title &char, description &char)
fn C.uiOpenFile(parent &C.uiWindow) &char
fn C.uiSaveFile(parent &C.uiWindow) &char
fn C.uiOpenFolder(parent &C.uiWindow) &char
fn C.uiImageAppend(i &C.uiImage, pixels voidptr, pixel_width int, pixel_height int, byte_stride int)

const zgui_slider_steps = 1000 // a slider is 0..1000 under the hood; the value maps onto min..max

// one widget the view declared this frame
@[heap]
struct ZGuiNode {
pub mut:
	kind    string // text | separator | button | toggle | field | spinbox | slider | progress | begin_form | end_form | begin_hbox | end_hbox | begin_vbox | end_vbox | begin_panel | end_panel
	label   string
	ctl     voidptr // the libui control, once built (a container: its box / form / inner box)
	msg     voidptr // a button: the copied Msg bytes
	size    int
	join    bool // the widget after this one was declared on the same line
	text    string // a field's text, from the model
	ival    i64    // a spinbox's value, a toggle's state (0/1), a progress bar's percent
	fval    f64    // a slider's value
	fmin    f64
	fmax    f64
	imin    i64
	imax    i64
	on_bool fn (bool)   = unsafe { nil } // a toggle's sender
	on_text fn (string) = unsafe { nil } // a field's
	on_int  fn (i64)    = unsafe { nil } // a spinbox's
	on_f64  fn (f64)    = unsafe { nil } // a slider's
	on_idx  fn (i64)    = unsafe { nil } // a combobox's or radio's
	items   []string // a combobox's or radio's choices
	tip     string   // a tooltip declared after the widget
	st      &ZGuiState = unsafe { nil }
}

@[heap]
struct ZGuiState {
pub mut:
	window       &C.uiWindow = unsafe { nil }
	root         &C.uiBox    = unsafe { nil } // the window's one child, kept for the program's life
	root_kids    []voidptr // what a rebuild appended to the root: detached and destroyed before the next
	row          &C.uiBox    = unsafe { nil } // the open horizontal row, in the current container
	same         bool // the next widget joins the open row
	prev         []&ZGuiNode // last frame's widgets, in order
	cur          []&ZGuiNode // this frame's
	queue        []voidptr   // Msg copies sent this frame
	queue_sizes  []int       // each copy's size: a literal message is a V int, the Msg may be i64
	size_said    bool
	sent         int  // messages sent since the frame began
	redraw       bool // draw one more frame without waiting
	closing      bool
	frame        int
	script       []string
	trace        bool
	timers       []&ZGuiTimer
	tooltip_said bool
	title        string // the window's, until it exists (made at the first commit, after the menus)
	width        int
	height       int
	menus        []&ZGuiMenu
	cur_menu     &ZGuiMenu = unsafe { nil } // the menu being declared
	menus_frozen bool // libui builds the menubar before the window: the first frame's menus are the menus
	tab_select   map[string]int // `g.selectTab(id, i)` requests, applied at the commit
	tables       map[string]&ZGuiTable
	cur_table    &ZGuiTable = unsafe { nil } // between beginTable and endTable: g.text is a cell
	hot          []u32 // the window's registered chords, (mods << 16) | vk
	keys         []u32 // the chords pressed, taken by takeKey in order
	min_applied  map[string]string // minSize applied, by the container's id: "<w>x<h>" (the trace says it)
	trees        map[string]&ZGuiTree
	cur_tree     &ZGuiTree = unsafe { nil }
	tool_items   []&ZGuiToolItem // this frame's toolbar
	tool_next_on bool = true // toolEnabled: the next item's state
	toolbar      &C.uiToolbar = unsafe { nil }
	tool_built   []string // the labels the strip holds now
	icons        map[string]&C.uiImage
	icon_queue   []ZGuiIconReq // registerIcon runs before Gui.run, before uiInit: queued
	icon_said    map[string]bool
	dialog_answers []string // scripted: what the next dialogs return (`dialog:<path>`; empty = cancelled)
	dialogs_shown  []string // this frame's dialogs, for the trace
	areas          map[string]&ZGuiArea
	editors        map[string]&ZCodeEditor // by the node key `ed:<address>`
	markers_said   bool
	paint          &C.uiAreaDrawParams = unsafe { nil } // inside a draw: the context and size
	paint_area     &ZGuiArea = unsafe { nil }
}

struct ZGuiIconReq {
pub mut:
	name string
	w    int
	h    int
	rgba string
}

// a menu declared in the first frame, and its items
@[heap]
struct ZGuiMenu {
pub mut:
	name  string
	items []&ZGuiMenuItem
}

@[heap]
struct ZGuiMenuItem {
pub mut:
	kind  string // item | separator | quit
	label string
	msg   voidptr
	size  int
	st    &ZGuiState = unsafe { nil }
}

// a `g.every(ms, msg)`: one libui timer, the Msg copy it sends
@[heap]
struct ZGuiTimer {
pub mut:
	ms   i64
	msg  voidptr
	size int
	seen bool // declared this frame (an undeclared timer stops)
	st   &ZGuiState = unsafe { nil }
}

// a table, kept by id across frames: the rows the view fills each frame become
// the model's rows (the model reports `shown`; changes are told to libui row
// by row), the control is made at the first commit and again after a rebuild
@[heap]
struct ZGuiTable {
pub mut:
	handler   C.uiTableModelHandler // FIRST: a callback casts the handler pointer back to the table
	id        string
	ncols     int
	names     []string
	rows      [][]string // this frame's cells
	shown     [][]string // what the model reports (the last committed rows)
	cur_col   int
	model     &C.uiTableModel = unsafe { nil }
	table     &C.uiTable      = unsafe { nil }
	activated int = -1 // a double-clicked row, read once by tableActivatedRow
	check_col  int = -1 // the column kinds, by index (-1: none)
	edit_col   int = -1
	button_col int = -1
	on_check   fn (i64, bool)   = unsafe { nil }
	on_edit    fn (i64, string) = unsafe { nil }
	on_button  fn (i64)         = unsafe { nil }
	st        &ZGuiState = unsafe { nil }
}

// a node of a tree, declared this frame or shown by the model
@[heap]
struct ZGuiTNode {
pub mut:
	key      string
	label    string
	icon     string
	is_node  bool // a node (may have children) against a leaf
	expanded bool
	children []&ZGuiTNode
	parent   &ZGuiTNode = unsafe { nil }
}

// a tree kept by id: the frame's nodes become the model's when the structure
// (the keys and their nesting) is the same; otherwise the frame rebuilds
@[heap]
struct ZGuiTree {
pub mut:
	handler     C.uiTreeModelHandler // FIRST: a callback casts the handler pointer back
	id          string
	roots       []&ZGuiTNode // this frame's
	shown       []&ZGuiTNode // the model's
	stack       []&ZGuiTNode // the open nodes while declaring
	structure   string // the keys with their depth, this frame
	model       &C.uiTreeModel = unsafe { nil }
	tree        &C.uiTree      = unsafe { nil }
	on_select   fn (string) = unsafe { nil }
	on_activate fn (string) = unsafe { nil }
	on_expand   fn (string, bool) = unsafe { nil }
	st          &ZGuiState = unsafe { nil }
}

// an area or canvas: the handler first (a callback casts back), the program's
// closures for this frame (the draw closure captures the model's values, so a
// new one each frame; a redraw is queued every frame since the captures
// cannot be compared, which the Zig section does only when they changed)
@[heap]
struct ZGuiArea {
pub mut:
	handler  C.uiAreaHandler
	id       string
	w        int
	h        int
	draw     fn (Gui)           = unsafe { nil }
	on_click fn (f64, f64, i64) = unsafe { nil }      // an area's click: x, y, button
	on_mouse fn (i64, f64, f64, i64) = unsafe { nil } // a canvas's: ev (1 press 2 release 3 move 4 enter 5 leave), x, y, buttons
	on_key   fn (i64, i64, bool) = unsafe { nil }     // a canvas's: vk, mods (1 ctrl 2 shift 4 alt), down
	area     &C.uiArea = unsafe { nil }
	is_canvas bool
	painted  []string // the primitives of the last draw, for the trace
	st       &ZGuiState = unsafe { nil }
}

// a code editor: one record for the program's life, a Scintilla control while
// the window holds it (the text lives in the control then; it is pulled back
// into `text` before a rebuild destroys the control)
@[heap]
struct ZCodeEditor {
pub mut:
	sci        &C.uiScintilla = unsafe { nil }
	text       string
	read_only  bool
	lang       string = 'zebra'
	ev_modified bool
	ev_char    i64
	ev_margin_line i64 = -1
	hot        []u32 // registered chords, (mods << 16) | vk
	keys       []u32 // chords pressed, taken by takeKey in order
	st         &ZGuiState = unsafe { nil }
}

// the handle a program holds (`CodeEditor?` in Zebra; copies share the record)
pub struct CodeEditor {
pub mut:
	ed &ZCodeEditor = unsafe { nil }
}

// `code_editor.for_zebra()` and the other constructors, as the emitter spells
// Zebra's `CodeEditor.forZebra()`
pub struct CodeEditorKind {}

pub const code_editor = CodeEditorKind{}

@[heap]
struct ZGuiToolItem {
pub mut:
	kind    string // item | separator
	label   string
	icon    string
	tip     string
	msg     voidptr
	size    int
	enabled bool
	index   int = -1 // libui's, once appended
}

// the handle the program's view receives (by value; the state is shared)
pub struct Gui {
pub mut:
	st &ZGuiState = unsafe { nil }
}

// `gui.run(...)` is how the emitter spells Zebra's `Gui.run(...)`
pub const gui = Gui{}

// the one state: made by the first call that needs it (registerIcon runs
// before Gui.run), used by run
__global zgui_state = &ZGuiState(unsafe { nil })

fn zgui_global_state() &ZGuiState {
	if zgui_state == unsafe { nil } {
		zgui_state = &ZGuiState{}
	}
	return zgui_state
}

fn zgui_cstr(s string) &char {
	return unsafe { &char(s.str) }
}

fn zgui_push(st &ZGuiState, p voidptr) {
	zgui_push_sized(st, p, 0)
}

fn zgui_push_sized(st &ZGuiState, p voidptr, size int) {
	mut s := unsafe { st }
	s.queue << p
	s.queue_sizes << size
	s.sent++
}

fn zgui_on_closing(w &C.uiWindow, data voidptr) int {
	mut st := unsafe { &ZGuiState(data) }
	st.closing = true
	C.uiQuit()
	return 1
}

fn zgui_on_click(b &C.uiButton, data voidptr) {
	n := unsafe { &ZGuiNode(data) }
	zgui_push_sized(n.st, n.msg, n.size)
}

fn zgui_on_toggled(c &C.uiCheckbox, data voidptr) {
	mut n := unsafe { &ZGuiNode(data) }
	v := C.uiCheckboxChecked(c) != 0
	n.ival = if v { i64(1) } else { i64(0) }
	n.on_bool(v)
}

fn zgui_on_entry_changed(e &C.uiEntry, data voidptr) {
	mut n := unsafe { &ZGuiNode(data) }
	raw := C.uiEntryText(e)
	t := unsafe { cstring_to_vstring(raw) }
	C.uiFreeText(raw)
	n.text = t
	n.on_text(t)
}

fn zgui_on_spin_changed(s &C.uiSpinbox, data voidptr) {
	mut n := unsafe { &ZGuiNode(data) }
	v := i64(C.uiSpinboxValue(s))
	n.ival = v
	n.on_int(v)
}

fn zgui_on_slider_changed(s &C.uiSlider, data voidptr) {
	mut n := unsafe { &ZGuiNode(data) }
	step := C.uiSliderValue(s)
	v := n.fmin + (n.fmax - n.fmin) * f64(step) / f64(zgui_slider_steps)
	n.fval = v
	n.on_f64(v)
}

fn zgui_on_should_quit(data voidptr) int {
	mut st := unsafe { &ZGuiState(data) }
	st.closing = true
	return 1
}

fn zgui_on_combo_selected(c &C.uiCombobox, data voidptr) {
	mut n := unsafe { &ZGuiNode(data) }
	v := i64(C.uiComboboxSelected(c))
	n.ival = v
	n.on_idx(v)
}

fn zgui_on_radio_selected(r &C.uiRadioButtons, data voidptr) {
	mut n := unsafe { &ZGuiNode(data) }
	v := i64(C.uiRadioButtonsSelected(r))
	n.ival = v
	n.on_idx(v)
}

fn zgui_on_menu_clicked(mi &C.uiMenuItem, w &C.uiWindow, data voidptr) {
	it := unsafe { &ZGuiMenuItem(data) }
	zgui_push_sized(it.st, it.msg, it.size)
}

// the first frame's menus, built before the window (libui's order)
fn zgui_build_menus(st &ZGuiState) {
	mut s := unsafe { st }
	for m in s.menus {
		um := C.uiNewMenu(zgui_cstr(m.name))
		for it in m.items {
			match it.kind {
				'item' {
					ui := C.uiMenuAppendItem(um, zgui_cstr(it.label))
					C.uiMenuItemOnClicked(ui, zgui_on_menu_clicked, voidptr(it))
				}
				'separator' {
					C.uiMenuAppendSeparator(um)
				}
				'quit' {
					C.uiMenuAppendQuitItem(um)
				}
				else {}
			}
		}
	}
	s.menus_frozen = true
}

// libui wants premultiplied alpha; a registered icon arrives straight
fn zgui_premultiply(rgba []u8) []u8 {
	mut out := []u8{len: rgba.len}
	for i := 0; i + 3 < rgba.len; i += 4 {
		a := u32(rgba[i + 3])
		out[i] = u8((u32(rgba[i]) * a + 127) / 255)
		out[i + 1] = u8((u32(rgba[i + 1]) * a + 127) / 255)
		out[i + 2] = u8((u32(rgba[i + 2]) * a + 127) / 255)
		out[i + 3] = u8(a)
	}
	return out
}

fn zgui_image(pixels []u8, w int, h int) &C.uiImage {
	img := C.uiNewImage(f64(w), f64(h))
	C.uiImageAppend(img, voidptr(pixels.data), w, h, w * 4)
	return img
}

fn zgui_icon_px(mut buf []u8, x int, y int, r u8, g u8, b u8, a u8) {
	if x < 0 || y < 0 || x >= 16 || y >= 16 {
		return
	}
	o := (y * 16 + x) * 4
	buf[o] = u8((u32(r) * u32(a)) / 255)
	buf[o + 1] = u8((u32(g) * u32(a)) / 255)
	buf[o + 2] = u8((u32(b) * u32(a)) / 255)
	buf[o + 3] = a
}

fn zgui_icon_rect(mut buf []u8, x0 int, y0 int, x1 int, y1 int, r u8, g u8, b u8) {
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			zgui_icon_px(mut buf, x, y, r, g, b, 255)
		}
	}
}

// the built-in icons, 16x16 premultiplied RGBA, as the Zig section paints them
fn zgui_paint_icon(name string) []u8 {
	mut buf := []u8{len: 16 * 16 * 4}
	match name {
		'folder' { // a tab and a body, warm yellow with a darker outline
			zgui_icon_rect(mut buf, 1, 3, 7, 5, 0xC9, 0x9A, 0x2E)
			zgui_icon_rect(mut buf, 1, 5, 15, 14, 0xC9, 0x9A, 0x2E)
			zgui_icon_rect(mut buf, 2, 6, 14, 13, 0xF2, 0xC4, 0x5A)
		}
		'file' { // a white page, grey outline, folded corner
			zgui_icon_rect(mut buf, 3, 1, 13, 15, 0x77, 0x77, 0x77)
			zgui_icon_rect(mut buf, 4, 2, 12, 14, 0xFC, 0xFC, 0xFC)
			for i := 0; i < 4; i++ {
				zgui_icon_rect(mut buf, 9 + i, 1, 13, 2 + i, 0x77, 0x77, 0x77)
				zgui_icon_rect(mut buf, 9, 2 + i, 13, 3 + i, 0xE0, 0xE0, 0xE0)
			}
			zgui_icon_rect(mut buf, 6, 7, 11, 8, 0xAA, 0xAA, 0xAA)
			zgui_icon_rect(mut buf, 6, 10, 11, 11, 0xAA, 0xAA, 0xAA)
		}
		'dot' { // a blue disc
			for y := 0; y < 16; y++ {
				for x := 0; x < 16; x++ {
					dx := x * 2 - 15
					dy := y * 2 - 15
					if dx * dx + dy * dy <= 11 * 11 {
						zgui_icon_px(mut buf, x, y, 0x2A, 0x6E, 0xBB, 255)
					}
				}
			}
		}
		'warn' { // an amber triangle with a dark bang (the amber is this section's own: the Zig line is cut in the source read)
			for y := 2; y < 15; y++ {
				half := ((y - 2) * 7) / 12
				for x := 8 - half; x <= 8 + half && x < 16; x++ {
					zgui_icon_px(mut buf, x, y, 0xF0, 0xA8, 0x20, 255)
				}
			}
			zgui_icon_rect(mut buf, 7, 6, 9, 11, 0x33, 0x22, 0x00)
			zgui_icon_rect(mut buf, 7, 12, 9, 14, 0x33, 0x22, 0x00)
		}
		else {}
	}
	return buf
}

fn zgui_area_draw(h &C.uiAreaHandler, a &C.uiArea, p &C.uiAreaDrawParams) {
	mut ar := unsafe { &ZGuiArea(h) }
	if ar.draw == unsafe { nil } {
		return
	}
	mut st := ar.st
	unsafe {
		st.paint = p // libui's, valid for this call: V's escape rule wants the unsafe
	}
	st.paint_area = ar
	ar.painted = []string{}
	ar.draw(Gui{ st: st })
	st.paint = unsafe { nil }
	st.paint_area = unsafe { nil }
}

fn zgui_area_mouse(h &C.uiAreaHandler, a &C.uiArea, e &C.uiAreaMouseEvent) {
	ar := unsafe { &ZGuiArea(h) }
	if ar.is_canvas {
		if ar.on_mouse == unsafe { nil } {
			return
		}
		if e.Down != 0 {
			ar.on_mouse(1, e.X, e.Y, i64(e.Down))
		} else if e.Up != 0 {
			ar.on_mouse(2, e.X, e.Y, i64(e.Up))
		} else {
			ar.on_mouse(3, e.X, e.Y, i64(e.Held1To64 & 0xffff))
		}
		return
	}
	if e.Down == 0 || ar.on_click == unsafe { nil } {
		return
	}
	ar.on_click(e.X, e.Y, i64(e.Down))
}

fn zgui_area_crossed(h &C.uiAreaHandler, a &C.uiArea, left int) {
	ar := unsafe { &ZGuiArea(h) }
	if ar.is_canvas && ar.on_mouse != unsafe { nil } {
		ar.on_mouse(if left != 0 { 5 } else { 4 }, -1, -1, 0)
	}
}

fn zgui_area_drag_broken(h &C.uiAreaHandler, a &C.uiArea) {
}

// libui's key event as the hotkey vocabulary (letters upper-case ASCII, digits,
// F1..F12 at 0x70.., the navigation keys' VK codes); unmapped is 0, not delivered
fn zgui_key_vk(e &C.uiAreaKeyEvent) i64 {
	if e.Key != 0 {
		c := i64(u8(e.Key))
		if c >= 97 && c <= 122 {
			return c - 32
		}
		if c == 10 || c == 13 {
			return 0x0D
		}
		if c == 9 {
			return 0x09
		}
		if c == 8 || c == 127 {
			return 0x08
		}
		return c
	}
	k := e.ExtKey
	if k >= 12 && k <= 23 {
		return 0x70 + i64(k - 12)
	}
	if k >= 24 && k <= 33 {
		return 48 + i64(k - 24)
	}
	return match k {
		1 { 0x1B }
		2 { 0x2D }
		3 { 0x2E }
		4 { 0x24 }
		5 { 0x23 }
		6 { 0x21 }
		7 { 0x22 }
		8 { 0x26 }
		9 { 0x28 }
		10 { 0x25 }
		11 { 0x27 }
		34 { 46 }
		35 { 0x0D }
		36 { 43 }
		37 { 45 }
		38 { 42 }
		39 { 47 }
		else { 0 }
	}
}

fn zgui_area_key(h &C.uiAreaHandler, a &C.uiArea, e &C.uiAreaKeyEvent) int {
	ar := unsafe { &ZGuiArea(h) }
	if !ar.is_canvas || ar.on_key == unsafe { nil } {
		return 0
	}
	vk := zgui_key_vk(e)
	if vk == 0 {
		return 0
	}
	mut mods := i64(0)
	if e.Modifiers & 1 != 0 {
		mods |= 1 // ctrl
	}
	if e.Modifiers & 4 != 0 {
		mods |= 2 // shift
	}
	if e.Modifiers & 2 != 0 {
		mods |= 4 // alt
	}
	ar.on_key(vk, mods, e.Up == 0)
	return 1
}

fn zgui_brush(color i64) C.uiDrawBrush {
	c := u32(color & 0xffffff)
	return C.uiDrawBrush{
		Type: zgui_brush_solid
		R: f64((c >> 16) & 0xff) / 255.0
		G: f64((c >> 8) & 0xff) / 255.0
		B: f64(c & 0xff) / 255.0
		A: 1.0
		Stops: unsafe { nil }
		NumStops: 0
	}
}

fn zgui_stroke_path(st &ZGuiState, path &C.uiDrawPath, color i64, thickness f64) {
	mut b := zgui_brush(color)
	mut sp := C.uiDrawStrokeParams{
		Cap: zgui_line_cap_round
		Join: zgui_line_join_round
		Thickness: if thickness > 0 { thickness } else { 1.0 }
		MiterLimit: 10.0
		Dashes: unsafe { nil }
		NumDashes: 0
	}
	C.uiDrawStroke(st.paint.Context, path, &b, &sp)
}

fn zgui_fill_path(st &ZGuiState, path &C.uiDrawPath, color i64) {
	mut b := zgui_brush(color)
	C.uiDrawFill(st.paint.Context, path, &b)
}

// the primitives record what they painted, for the trace
fn zgui_painted(st &ZGuiState, what string) {
	if st.paint_area != unsafe { nil } {
		mut ar := st.paint_area
		ar.painted << what
	}
}

fn zgui_ce_notify(s &C.uiScintilla, n &C.SCNotification, data voidptr) {
	mut ed := unsafe { &ZCodeEditor(data) }
	match n.nmhdr.code {
		zscn_modified {
			if n.modificationType & (zsc_mod_inserttext | zsc_mod_deletetext) != 0 {
				ed.ev_modified = true
			}
		}
		zscn_charadded {
			ed.ev_char = i64(n.ch)
		}
		zscn_marginclick {
			pos := if n.position > 0 { usize(n.position) } else { usize(0) }
			ed.ev_margin_line = i64(C.uiScintillaSendMessage(s, zsci_linefromposition, pos, 0))
		}
		else {}
	}
}

fn zgui_ce_key(s &C.uiScintilla, vk int, mods int, data voidptr) int {
	mut ed := unsafe { &ZCodeEditor(data) }
	chord := (u32(mods & 0xffff) << 16) | u32(vk & 0xffff)
	if chord in ed.hot {
		ed.keys << chord
		return 1
	}
	return 0
}

fn zgui_ce_send(ed &ZCodeEditor, code u32, w usize, l usize) usize {
	if ed.sci == unsafe { nil } {
		return 0
	}
	return C.uiScintillaSendMessage(ed.sci, code, w, l)
}

// the Zig section's configuration: UTF-8, Consolas 11, One Dark, a line-number
// margin, the caret line, a four-space tab
fn zgui_ce_configure(ed &ZCodeEditor) {
	font := 'Consolas'
	zgui_ce_send(ed, zsci_setcodepage, 65001, 0)
	zgui_ce_send(ed, zsci_stylesetfont, 32, usize(voidptr(font.str)))
	zgui_ce_send(ed, zsci_stylesetsize, 32, 11)
	zgui_ce_send(ed, zsci_stylesetfore, 32, zsci_c_fg)
	zgui_ce_send(ed, zsci_stylesetback, 32, zsci_c_bg)
	zgui_ce_send(ed, zsci_styleclearall, 0, 0)
	zgui_ce_send(ed, zsci_stylesetfore, usize(zsci_s_keyword), zsci_c_keyword)
	zgui_ce_send(ed, zsci_stylesetfore, usize(zsci_s_comment), zsci_c_comment)
	zgui_ce_send(ed, zsci_stylesetfore, usize(zsci_s_string), zsci_c_string)
	zgui_ce_send(ed, zsci_stylesetfore, usize(zsci_s_number), zsci_c_number)
	zgui_ce_send(ed, zsci_stylesetfore, usize(zsci_s_type), zsci_c_type)
	zgui_ce_send(ed, zsci_stylesetfore, usize(zsci_s_func), zsci_c_func)
	zgui_ce_send(ed, zsci_stylesetfore, usize(zsci_s_op), zsci_c_op)
	zgui_ce_send(ed, zsci_stylesetfore, usize(zsci_s_preproc), zsci_c_preproc)
	zgui_ce_send(ed, zsci_stylesetfore, 33, zsci_c_lnfg)
	zgui_ce_send(ed, zsci_stylesetback, 33, zsci_c_lnbg)
	zgui_ce_send(ed, zsci_setmargintypen, 0, 1)
	zgui_ce_send(ed, zsci_setmarginwidthn, 0, 56)
	zgui_ce_send(ed, zsci_setmarginsensitiven, 0, 1)
	zgui_ce_send(ed, zsci_setcaretlinevisible, 1, 0)
	zgui_ce_send(ed, zsci_setcaretlineback, zsci_c_caretln, 0)
	zgui_ce_send(ed, zsci_setselback, 1, zsci_c_sel)
	zgui_ce_send(ed, zsci_settabwidth, 4, 0)
}

// the control over the record: made at the first render and again after a
// rebuild, with the record's text
fn zgui_ce_make_control(ed &ZCodeEditor) voidptr {
	mut e := unsafe { ed }
	sci := C.uiNewScintilla()
	e.sci = sci
	zgui_ce_configure(e)
	C.uiScintillaOnNotify(sci, zgui_ce_notify, voidptr(e))
	C.uiScintillaOnKey(sci, zgui_ce_key, voidptr(e))
	if e.text.len > 0 {
		C.uiScintillaSetText(sci, zgui_cstr(e.text), u32(e.text.len))
		zgui_ce_style(e)
	}
	e.ev_modified = false // the set is not an edit
	if e.read_only {
		zgui_ce_send(e, zsci_setreadonly, 1, 0)
	}
	return voidptr(sci)
}

// the control's text into the record (before the control goes, or on getText)
fn zgui_ce_pull_text(ed &ZCodeEditor) {
	mut e := unsafe { ed }
	if e.sci == unsafe { nil } {
		return
	}
	n := C.uiScintillaGetLength(e.sci)
	if n == 0 {
		e.text = ''
		return
	}
	mut buf := []u8{len: int(n) + 1}
	C.uiScintillaGetRange(e.sci, 0, n, unsafe { &char(buf.data) })
	e.text = buf[..int(n)].bytestr()
}

// the record's text tokenized by its language and the style bytes sent to the
// control (one per source byte, from 0)
fn zgui_ce_style(ed &ZCodeEditor) {
	if ed.sci == unsafe { nil } || ed.text.len == 0 {
		return
	}
	out := zgui_ce_tokenize(zgui_ce_spec_by_name(ed.lang), ed.text)
	zgui_ce_send(ed, zsci_startstyling, 0, 0)
	zgui_ce_send(ed, zsci_setstylingex, usize(out.len), usize(voidptr(out.data)))
}

// an edit moves Scintilla's end-styled watermark back to where it happened:
// when it is short of the length, pull the live text and restyle it (two
// messages when nothing changed; libui routes no notification for it)
fn zgui_ce_restyle_if_dirty(ed &ZCodeEditor) {
	if ed.sci == unsafe { nil } {
		return
	}
	n := C.uiScintillaGetLength(ed.sci)
	if n == 0 {
		return
	}
	if zgui_ce_send(ed, zsci_getendstyled, 0, 0) >= usize(n) {
		return
	}
	zgui_ce_pull_text(ed)
	zgui_ce_style(ed)
}

// the trace's tally of the control's own style bytes (read back from
// Scintilla, not from the tokenizer: what the control shows), the first
// 4096 bytes at most
fn zgui_ce_style_words(ed &ZCodeEditor) string {
	if ed.sci == unsafe { nil } {
		return ' (no control)'
	}
	n := int(C.uiScintillaGetLength(ed.sci))
	lim := if n > 4096 { 4096 } else { n }
	mut tally := []int{len: 9}
	for i := 0; i < lim; i++ {
		st := int(zgui_ce_send(ed, zsci_getstyleat, usize(i), 0))
		if st >= 0 && st < 9 {
			tally[st]++
		}
	}
	mut w := ' kw=${tally[1]} cm=${tally[2]} st=${tally[3]} nu=${tally[4]} ty=${tally[5]} fn=${tally[6]} op=${tally[7]} pp=${tally[8]}'
	if n > lim {
		w += ' (first ${lim})'
	}
	return w
}

fn zgui_on_editcombo_changed(c &C.uiEditableCombobox, data voidptr) {
	mut n := unsafe { &ZGuiNode(data) }
	raw := C.uiEditableComboboxText(c)
	t := unsafe { cstring_to_vstring(raw) }
	C.uiFreeText(raw)
	n.text = t
	n.on_text(t)
}

fn zgui_tbl_num_columns(mh &C.uiTableModelHandler, m &C.uiTableModel) int {
	t := unsafe { &ZGuiTable(mh) }
	return t.ncols
}

fn zgui_tbl_column_type(mh &C.uiTableModelHandler, m &C.uiTableModel, column int) int {
	t := unsafe { &ZGuiTable(mh) }
	if column == t.check_col {
		return zgui_table_value_int
	}
	return zgui_table_value_string
}

fn zgui_tbl_num_rows(mh &C.uiTableModelHandler, m &C.uiTableModel) int {
	t := unsafe { &ZGuiTable(mh) }
	return t.shown.len
}

fn zgui_tbl_cell_value(mh &C.uiTableModelHandler, m &C.uiTableModel, row int, column int) &C.uiTableValue {
	t := unsafe { &ZGuiTable(mh) }
	mut text := ''
	if row >= 0 && row < t.shown.len && column >= 0 && column < t.shown[row].len {
		text = t.shown[row][column]
	}
	if column == t.check_col {
		return C.uiNewTableValueInt(if text == '1' { 1 } else { 0 })
	}
	return C.uiNewTableValueString(zgui_cstr(text))
}

// a check toggled, a cell edited or a button clicked: to the program's closure
// for that column; the model is NOT changed here -- the message goes to update,
// the next frame's rows carry the answer (or not, if update declined)
fn zgui_tbl_set_cell_value(mh &C.uiTableModelHandler, m &C.uiTableModel, row int, column int, v &C.uiTableValue) {
	t := unsafe { &ZGuiTable(mh) }
	if column == t.button_col {
		// a button column: libui calls with no value for the click
		if t.on_button != unsafe { nil } {
			t.on_button(i64(row))
		}
		return
	}
	if v == unsafe { nil } {
		return
	}
	if column == t.edit_col {
		if t.on_edit != unsafe { nil } {
			// (copied: libui frees the value when this returns, the message is handled later)
			text := unsafe { cstring_to_vstring(C.uiTableValueString(v)) }
			t.on_edit(i64(row), text)
		}
		return
	}
	if column == t.check_col && t.on_check != unsafe { nil } {
		t.on_check(i64(row), C.uiTableValueInt(v) != 0)
	}
}

fn zgui_on_row_double_clicked(tb &C.uiTable, row int, data voidptr) {
	mut t := unsafe { &ZGuiTable(data) }
	t.activated = row
	// a redraw, so the view reads it: a frame is drawn after any event anyway
}

// the table control over the model, with its columns
fn zgui_make_table_control(t &ZGuiTable) voidptr {
	mut tt := unsafe { t }
	if tt.model == unsafe { nil } {
		tt.handler = C.uiTableModelHandler{
			NumColumns: zgui_tbl_num_columns
			ColumnType: zgui_tbl_column_type
			NumRows: zgui_tbl_num_rows
			CellValue: zgui_tbl_cell_value
			SetCellValue: zgui_tbl_set_cell_value
		}
		tt.shown = tt.rows.clone()
		tt.model = C.uiNewTableModel(&tt.handler)
	}
	params := C.uiTableParams{
		Model: tt.model
		RowBackgroundColorModelColumn: -1
	}
	tb := C.uiNewTable(&params)
	for c := 0; c < tt.ncols; c++ {
		name := if c < tt.names.len { tt.names[c] } else { '' }
		if c == tt.check_col {
			C.uiTableAppendCheckboxColumn(tb, zgui_cstr(name), c, zgui_column_always_editable)
		} else if c == tt.edit_col {
			C.uiTableAppendTextColumn(tb, zgui_cstr(name), c, zgui_column_always_editable, unsafe { nil })
		} else if c == tt.button_col {
			C.uiTableAppendButtonColumn(tb, zgui_cstr(name), c, zgui_column_always_editable)
		} else {
			C.uiTableAppendTextColumn(tb, zgui_cstr(name), c, -1, unsafe { nil })
		}
	}
	C.uiTableOnRowDoubleClicked(tb, zgui_on_row_double_clicked, voidptr(tt))
	tt.table = tb
	return voidptr(tb)
}

// this frame's rows into the model, row by row (libui is told what changed)
fn zgui_table_update_rows(t &ZGuiTable) {
	mut tt := unsafe { t }
	if tt.model == unsafe { nil } {
		return
	}
	old := tt.shown.len
	new := tt.rows.len
	common := if old < new { old } else { new }
	for i := 0; i < common; i++ {
		if tt.shown[i] != tt.rows[i] {
			tt.shown[i] = tt.rows[i].clone()
			C.uiTableModelRowChanged(tt.model, i)
		}
	}
	for i := old - 1; i >= new; i-- {
		tt.shown.delete_last()
		C.uiTableModelRowDeleted(tt.model, i)
	}
	for i := old; i < new; i++ {
		tt.shown << tt.rows[i].clone()
		C.uiTableModelRowInserted(tt.model, i)
	}
}

fn zgui_tree_num_children(mh &C.uiTreeModelHandler, m &C.uiTreeModel, parent voidptr) int {
	t := unsafe { &ZGuiTree(mh) }
	if parent == unsafe { nil } {
		return t.shown.len
	}
	pn := unsafe { &ZGuiTNode(parent) }
	return pn.children.len
}

fn zgui_tree_child(mh &C.uiTreeModelHandler, m &C.uiTreeModel, parent voidptr, index int) voidptr {
	t := unsafe { &ZGuiTree(mh) }
	if parent == unsafe { nil } {
		if index >= 0 && index < t.shown.len {
			return voidptr(t.shown[index])
		}
		return voidptr(0)
	}
	pn := unsafe { &ZGuiTNode(parent) }
	if index >= 0 && index < pn.children.len {
		return voidptr(pn.children[index])
	}
	return voidptr(0)
}

fn zgui_tree_text(mh &C.uiTreeModelHandler, m &C.uiTreeModel, node voidptr) &char {
	n := unsafe { &ZGuiTNode(node) }
	return zgui_cstr(n.label) // a V string is NUL-terminated and lives with the shown node
}

fn zgui_tree_has_children(mh &C.uiTreeModelHandler, m &C.uiTreeModel, node voidptr) int {
	n := unsafe { &ZGuiTNode(node) }
	return if n.is_node { 1 } else { 0 }
}

fn zgui_tree_icon(mh &C.uiTreeModelHandler, m &C.uiTreeModel, node voidptr) &C.uiImage {
	t := unsafe { &ZGuiTree(mh) }
	n := unsafe { &ZGuiTNode(node) }
	if n.icon == '' {
		return unsafe { nil }
	}
	if img := t.st.icons[n.icon] {
		return img
	}
	mut st := t.st
	if n.icon !in st.icon_said {
		eprintln('[zgui] icon "' + n.icon + '" is neither built in (folder, file, dot, warn) nor registered (Gui.registerIcon): drawn without')
		st.icon_said[n.icon] = true
	}
	return unsafe { nil }
}

fn zgui_on_tree_selection(tr &C.uiTree, data voidptr) {
	t := unsafe { &ZGuiTree(data) }
	p := C.uiTreeSelection(tr)
	if p == unsafe { nil } {
		return
	}
	n := unsafe { &ZGuiTNode(p) }
	t.on_select(n.key)
}

fn zgui_on_tree_activated(tr &C.uiTree, node voidptr, data voidptr) {
	t := unsafe { &ZGuiTree(data) }
	n := unsafe { &ZGuiTNode(node) }
	t.on_activate(n.key)
}

fn zgui_on_tree_expanded(tr &C.uiTree, node voidptr, expanded int, data voidptr) {
	t := unsafe { &ZGuiTree(data) }
	n := unsafe { &ZGuiTNode(node) }
	t.on_expand(n.key, expanded != 0)
}

fn zgui_tree_set_expanded(t &ZGuiTree, nodes []&ZGuiTNode) {
	for n in nodes {
		if n.is_node {
			C.uiTreeSetExpanded(t.tree, voidptr(n), if n.expanded { 1 } else { 0 })
			zgui_tree_set_expanded(t, n.children)
		}
	}
}

// the tree control over the model, from this frame's nodes
fn zgui_make_tree_control(t &ZGuiTree) voidptr {
	mut tt := unsafe { t }
	tt.handler = C.uiTreeModelHandler{
		NumChildren: zgui_tree_num_children
		Child: zgui_tree_child
		Text: zgui_tree_text
		HasChildren: zgui_tree_has_children
		Icon: zgui_tree_icon
	}
	tt.shown = tt.roots
	tt.model = C.uiNewTreeModel(&tt.handler)
	tr := C.uiNewTree(tt.model)
	tt.tree = tr
	C.uiTreeOnSelectionChanged(tr, zgui_on_tree_selection, voidptr(tt))
	C.uiTreeOnNodeActivated(tr, zgui_on_tree_activated, voidptr(tt))
	C.uiTreeOnNodeExpanded(tr, zgui_on_tree_expanded, voidptr(tt))
	zgui_tree_set_expanded(tt, tt.shown)
	return voidptr(tr)
}

// the same structure: labels and expansion brought up to the frame's, in place
fn zgui_tree_update_nodes(t &ZGuiTree, shown []&ZGuiTNode, cur []&ZGuiTNode) {
	for i in 0 .. shown.len {
		mut sn := shown[i]
		cn := cur[i]
		if sn.label != cn.label || sn.icon != cn.icon {
			sn.label = cn.label
			sn.icon = cn.icon
			C.uiTreeModelNodeChanged(t.model, voidptr(sn))
		}
		if sn.is_node {
			open := C.uiTreeExpanded(t.tree, voidptr(sn)) != 0
			if open != cn.expanded {
				C.uiTreeSetExpanded(t.tree, voidptr(sn), if cn.expanded { 1 } else { 0 })
			}
			sn.expanded = cn.expanded
			zgui_tree_update_nodes(t, sn.children, cn.children)
		}
	}
}

fn zgui_tree_find(nodes []&ZGuiTNode, key string) &ZGuiTNode {
	for n in nodes {
		if n.key == key {
			return n
		}
		if n.is_node {
			f := zgui_tree_find(n.children, key)
			if f != unsafe { nil } {
				return f
			}
		}
	}
	return unsafe { nil }
}

fn zgui_on_tool_clicked(tb &C.uiToolbar, index int, data voidptr) {
	st := unsafe { &ZGuiState(data) }
	for it in st.tool_items {
		if it.kind == 'item' && it.index == index {
			zgui_push_sized(st, it.msg, it.size)
			return
		}
	}
}

// the window's toolbar: the strip's items re-appended when the labels changed,
// each item's enabled state brought up to the frame's
fn zgui_sync_toolbar(st &ZGuiState) {
	mut s := unsafe { st }
	if s.window == unsafe { nil } {
		return
	}
	if s.tool_items.len == 0 && s.toolbar == unsafe { nil } {
		return
	}
	if s.toolbar == unsafe { nil } {
		s.toolbar = C.uiNewToolbar()
		C.uiToolbarOnClicked(s.toolbar, zgui_on_tool_clicked, voidptr(s))
		C.uiWindowSetToolbar(s.window, s.toolbar)
	}
	mut labels := []string{}
	for it in s.tool_items {
		labels << it.kind + ':' + it.label
	}
	if labels != s.tool_built {
		C.uiToolbarClear(s.toolbar)
		for mut it in s.tool_items {
			if it.kind == 'separator' {
				it.index = C.uiToolbarAppendSeparator(s.toolbar)
				continue
			}
			mut img := &C.uiImage(unsafe { nil })
			if it.icon != '' {
				if found := s.icons[it.icon] {
					img = found
				} else if it.icon !in s.icon_said {
					eprintln('[zgui] icon "' + it.icon + '" is neither built in (folder, file, dot, warn) nor registered (Gui.registerIcon): drawn without')
					s.icon_said[it.icon] = true
				}
			}
			it.index = C.uiToolbarAppendItem(s.toolbar, zgui_cstr(it.label), img, zgui_cstr(it.tip))
		}
		s.tool_built = labels
	} else {
		// the same strip: the indices are the built ones, by position
		mut idx := 0
		for mut it in s.tool_items {
			it.index = idx
			idx++
		}
	}
	for it in s.tool_items {
		if it.kind == 'item' && it.index >= 0 {
			C.uiToolbarSetItemEnabled(s.toolbar, it.index, if it.enabled { 1 } else { 0 })
		}
	}
}

fn zgui_on_timer(data voidptr) int {
	t := unsafe { &ZGuiTimer(data) }
	if !t.seen || t.st.closing {
		return 0 // the view stopped declaring it: the timer ends
	}
	zgui_push_sized(t.st, t.msg, t.size)
	return 1
}

fn zgui_init(st &ZGuiState, title string, width int, height int) {
	mut s := unsafe { st }
	o := C.uiInitOptions{
		Size: sizeof(C.uiInitOptions)
	}
	err := C.uiInit(&o)
	if err != unsafe { nil } {
		msg := unsafe { cstring_to_vstring(err) }
		C.uiFreeInitError(err)
		panic('libui init failed: ' + msg)
	}
	for r in s.icon_queue {
		if r.rgba.len < r.w * r.h * 4 {
			eprintln('[zgui] registerIcon ' + r.name + ': ' + r.rgba.len.str() + ' bytes for ' + r.w.str() + 'x' + r.h.str() + ' RGBA (wants ' + (r.w * r.h * 4).str() + '): not registered')
			continue
		}
		s.icons[r.name] = zgui_image(zgui_premultiply(r.rgba.bytes()), r.w, r.h)
	}
	s.icon_queue = []ZGuiIconReq{}
	// the built-in set: folder, file, dot, warn (the Zig section's painters)
	for name in ['folder', 'file', 'dot', 'warn'] {
		s.icons[name] = zgui_image(zgui_paint_icon(name), 16, 16)
	}
	// the window is made at the first commit, after the first frame's menus
	s.title = title
	s.width = width
	s.height = height
	C.uiOnShouldQuit(zgui_on_should_quit, voidptr(s))
	s.script = zgui_env('ZGUI_SCRIPT').split(';').filter(it != '')
	s.trace = zgui_env('ZGUI_TRACE') != ''
}

// (C's getenv, not os.getenv: the emission imports only what the program uses,
// and the section must not depend on that)
fn C.getenv(name &char) &char

fn zgui_env(name string) string {
	p := C.getenv(zgui_cstr(name))
	if p == unsafe { nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(p) }
}

fn zgui_slider_step(n &ZGuiNode) int {
	span := n.fmax - n.fmin
	if span <= 0 {
		return 0
	}
	mut step := int((n.fval - n.fmin) / span * f64(zgui_slider_steps))
	if step < 0 {
		step = 0
	}
	if step > zgui_slider_steps {
		step = zgui_slider_steps
	}
	return step
}

fn zgui_same_shape(a &ZGuiNode, b &ZGuiNode) bool {
	if a.kind != b.kind {
		return false
	}
	// a label is part of the identity for everything but a text (which is updated in place)
	if a.kind != 'text' && a.label != b.label {
		return false
	}
	if a.kind == 'spinbox' && (a.imin != b.imin || a.imax != b.imax) {
		return false
	}
	if (a.kind == 'combobox' || a.kind == 'radio' || a.kind == 'editcombo') && a.items.join('\x01') != b.items.join('\x01') {
		return false
	}
	if a.kind == 'table' && a.items.join('\x01') != b.items.join('\x01') {
		return false // the columns changed
	}
	if a.kind == 'tree' && a.text != b.text {
		return false // the keys or their nesting changed
	}
	if a.kind == 'area' && (a.imin != b.imin || a.imax != b.imax) {
		return false // the size changed
	}
	return true
}

// a control with no label of its own gets one beside it (or its form row's)
fn zgui_needs_label(kind string) bool {
	return kind == 'field' || kind == 'spinbox' || kind == 'slider' || kind == 'progress' || kind == 'editcombo'
}

// one control for a node, built fresh
fn zgui_build_control(n &ZGuiNode) voidptr {
	mut m := unsafe { n }
	match n.kind {
		'text' {
			return voidptr(C.uiNewLabel(zgui_cstr(n.label)))
		}
		'button' {
			b := C.uiNewButton(zgui_cstr(n.label))
			C.uiButtonOnClicked(b, zgui_on_click, voidptr(m))
			return voidptr(b)
		}
		'separator' {
			return voidptr(C.uiNewHorizontalSeparator())
		}
		'toggle' {
			c := C.uiNewCheckbox(zgui_cstr(n.label))
			C.uiCheckboxSetChecked(c, int(n.ival))
			C.uiCheckboxOnToggled(c, zgui_on_toggled, voidptr(m))
			return voidptr(c)
		}
		'field' {
			e := C.uiNewEntry()
			C.uiEntrySetText(e, zgui_cstr(n.text))
			C.uiEntryOnChanged(e, zgui_on_entry_changed, voidptr(m))
			return voidptr(e)
		}
		'spinbox' {
			s := C.uiNewSpinbox(int(n.imin), int(n.imax))
			C.uiSpinboxSetValue(s, int(n.ival))
			C.uiSpinboxOnChanged(s, zgui_on_spin_changed, voidptr(m))
			return voidptr(s)
		}
		'slider' {
			s := C.uiNewSlider(0, zgui_slider_steps)
			C.uiSliderSetValue(s, zgui_slider_step(n))
			C.uiSliderOnChanged(s, zgui_on_slider_changed, voidptr(m))
			return voidptr(s)
		}
		'progress' {
			p := C.uiNewProgressBar()
			C.uiProgressBarSetValue(p, int(n.ival))
			return voidptr(p)
		}
		'table' {
			t := m.st.tables[n.label] or { panic('zgui: no table ' + n.label) }
			return zgui_make_table_control(t)
		}
		'tree' {
			t := m.st.trees[n.label] or { panic('zgui: no tree ' + n.label) }
			return zgui_make_tree_control(t)
		}
		'area' {
			mut ar := m.st.areas[n.label] or { panic('zgui: no area ' + n.label) }
			ar.handler = C.uiAreaHandler{
				Draw: zgui_area_draw
				MouseEvent: zgui_area_mouse
				MouseCrossed: zgui_area_crossed
				DragBroken: zgui_area_drag_broken
				KeyEvent: zgui_area_key
			}
			a := C.uiNewArea(&ar.handler)
			C.uiControlSetMinSize(unsafe { &C.uiControl(a) }, ar.w, ar.h)
			ar.area = a
			return voidptr(a)
		}
		'editor' {
			ed := m.st.editors[n.label] or { panic('zgui: no editor ' + n.label) }
			return zgui_ce_make_control(ed)
		}
		'editcombo' {
			c := C.uiNewEditableCombobox()
			for it in n.items {
				C.uiEditableComboboxAppend(c, zgui_cstr(it))
			}
			C.uiEditableComboboxSetText(c, zgui_cstr(n.text))
			C.uiEditableComboboxOnChanged(c, zgui_on_editcombo_changed, voidptr(m))
			return voidptr(c)
		}
		'combobox' {
			c := C.uiNewCombobox()
			for it in n.items {
				C.uiComboboxAppend(c, zgui_cstr(it))
			}
			C.uiComboboxSetSelected(c, int(n.ival))
			C.uiComboboxOnSelected(c, zgui_on_combo_selected, voidptr(m))
			return voidptr(c)
		}
		'radio' {
			r := C.uiNewRadioButtons()
			for it in n.items {
				C.uiRadioButtonsAppend(r, zgui_cstr(it))
			}
			C.uiRadioButtonsSetSelected(r, int(n.ival))
			C.uiRadioButtonsOnSelected(r, zgui_on_radio_selected, voidptr(m))
			return voidptr(r)
		}
		else {
			panic('zgui: no control for widget kind ' + n.kind)
		}
	}
	return voidptr(0)
}

// the new frame's widgets against the last: the same shape reuses the controls
// (values updated in place where the model's differ); otherwise rebuild
fn zgui_commit(st &ZGuiState) {
	mut s := unsafe { st }
	mut same := s.prev.len == s.cur.len
	if same {
		for i, n in s.cur {
			if !zgui_same_shape(s.prev[i], n) {
				same = false
				break
			}
		}
	}
	if same && s.root != unsafe { nil } {
		for i, mut n in s.cur {
			p := s.prev[i]
			n.ctl = p.ctl
			if n.tip != p.tip && n.ctl != unsafe { nil } {
				C.uiControlSetTooltip(unsafe { &C.uiControl(n.ctl) }, zgui_cstr(n.tip))
			}
			match n.kind {
				'text' {
					if p.label != n.label {
						C.uiLabelSetText(unsafe { &C.uiLabel(n.ctl) }, zgui_cstr(n.label))
					}
				}
				'button' {
					C.uiButtonOnClicked(unsafe { &C.uiButton(n.ctl) }, zgui_on_click, voidptr(n))
				}
				'toggle' {
					if p.ival != n.ival {
						C.uiCheckboxSetChecked(unsafe { &C.uiCheckbox(n.ctl) }, int(n.ival))
					}
					C.uiCheckboxOnToggled(unsafe { &C.uiCheckbox(n.ctl) }, zgui_on_toggled, voidptr(n))
				}
				'field' {
					if p.text != n.text {
						C.uiEntrySetText(unsafe { &C.uiEntry(n.ctl) }, zgui_cstr(n.text))
					}
					C.uiEntryOnChanged(unsafe { &C.uiEntry(n.ctl) }, zgui_on_entry_changed, voidptr(n))
				}
				'spinbox' {
					if p.ival != n.ival {
						C.uiSpinboxSetValue(unsafe { &C.uiSpinbox(n.ctl) }, int(n.ival))
					}
					C.uiSpinboxOnChanged(unsafe { &C.uiSpinbox(n.ctl) }, zgui_on_spin_changed, voidptr(n))
				}
				'slider' {
					if p.fval != n.fval {
						C.uiSliderSetValue(unsafe { &C.uiSlider(n.ctl) }, zgui_slider_step(n))
					}
					C.uiSliderOnChanged(unsafe { &C.uiSlider(n.ctl) }, zgui_on_slider_changed, voidptr(n))
				}
				'progress' {
					if p.ival != n.ival {
						C.uiProgressBarSetValue(unsafe { &C.uiProgressBar(n.ctl) }, int(n.ival))
					}
				}
				'table' {
					t := s.tables[n.label] or { panic('zgui: no table ' + n.label) }
					zgui_table_update_rows(t)
				}
				'tree' {
					t := s.trees[n.label] or { panic('zgui: no tree ' + n.label) }
					zgui_tree_update_nodes(t, t.shown, t.roots)
				}
				'area' {
					ar := s.areas[n.label] or { panic('zgui: no area ' + n.label) }
					if ar.area != unsafe { nil } {
						C.uiAreaQueueRedrawAll(ar.area) // the draw closure is this frame's: redraw
					}
				}
				'editor' {
					// the control is the record's; an edit since the last frame is restyled
					ed := s.editors[n.label] or { panic('zgui: no editor ' + n.label) }
					zgui_ce_restyle_if_dirty(ed)
				}
				'editcombo' {
					if p.text != n.text {
						C.uiEditableComboboxSetText(unsafe { &C.uiEditableCombobox(n.ctl) }, zgui_cstr(n.text))
					}
					C.uiEditableComboboxOnChanged(unsafe { &C.uiEditableCombobox(n.ctl) }, zgui_on_editcombo_changed, voidptr(n))
				}
				'combobox' {
					if p.ival != n.ival {
						C.uiComboboxSetSelected(unsafe { &C.uiCombobox(n.ctl) }, int(n.ival))
					}
					C.uiComboboxOnSelected(unsafe { &C.uiCombobox(n.ctl) }, zgui_on_combo_selected, voidptr(n))
				}
				'radio' {
					if p.ival != n.ival {
						C.uiRadioButtonsSetSelected(unsafe { &C.uiRadioButtons(n.ctl) }, int(n.ival))
					}
					C.uiRadioButtonsOnSelected(unsafe { &C.uiRadioButtons(n.ctl) }, zgui_on_radio_selected, voidptr(n))
				}
				else {}
			}
		}
		s.prev = s.cur
		zgui_apply_tab_selects(s)
		zgui_sync_toolbar(s)
		return
	}
	// rebuild: the window's content is one vertical box kept for the program's
	// life (libui refuses to destroy a control that still has a parent: the
	// rebuild DETACHES each top-level child with uiBoxDelete, then destroys it);
	// a container stack holds where the next control goes; a sameLine joins
	// the open row
	if s.window == unsafe { nil } {
		zgui_build_menus(s)
		s.window = C.uiNewWindow(zgui_cstr(s.title), s.width, s.height, if s.menus.len > 0 { 1 } else { 0 })
		C.uiWindowSetMargined(s.window, 1)
		C.uiWindowOnClosing(s.window, zgui_on_closing, voidptr(s))
		C.uiWindowOnKey(s.window, zgui_on_window_key, voidptr(s))
	}
	if s.root == unsafe { nil } {
		s.root = C.uiNewVerticalBox()
		C.uiBoxSetPadded(s.root, 1)
		C.uiWindowSetChild(s.window, unsafe { &C.uiControl(s.root) })
	} else {
		for _, mut ed in s.editors {
			if ed.sci != unsafe { nil } {
				zgui_ce_pull_text(ed) // before the destroy below takes the control
			}
		}
		for i := s.root_kids.len - 1; i >= 0; i-- {
			C.uiBoxDelete(s.root, i)
			C.uiControlDestroy(unsafe { &C.uiControl(s.root_kids[i]) })
		}
		s.root_kids = []voidptr{}
		// the destroyed tables' and trees' models go too (a model can hold no control when freed)
		for _, mut t in s.tables {
			if t.table != unsafe { nil } {
				t.table = unsafe { nil }
				C.uiFreeTableModel(t.model)
				t.model = unsafe { nil }
			}
		}
		for _, mut t in s.trees {
			if t.tree != unsafe { nil } {
				t.tree = unsafe { nil }
				C.uiFreeTreeModel(t.model)
				t.model = unsafe { nil }
			}
		}
		for _, mut ar in s.areas {
			ar.area = unsafe { nil }
		}
		for _, mut ed in s.editors {
			if ed.sci != unsafe { nil } {
				zgui_ce_pull_text(ed) // the text lives in the control: keep it
				ed.sci = unsafe { nil }
			}
		}
	}
	s.row = unsafe { nil }
	mut stack := []&ZGuiNode{} // the open containers (begin_* nodes)
	mut top_kind := 'vbox'
	mut top := voidptr(s.root)
	for mut n in s.cur {
		match n.kind {
			'begin_form' {
				f := C.uiNewForm()
				C.uiFormSetPadded(f, 1)
				zgui_place(s, top_kind, top, unsafe { &C.uiControl(f) }, false)
				n.ctl = voidptr(f)
				stack << n
				top_kind = 'form'
				top = voidptr(f)
				s.row = unsafe { nil }
				continue
			}
			'begin_hbox', 'begin_vbox' {
				b := if n.kind == 'begin_hbox' { C.uiNewHorizontalBox() } else { C.uiNewVerticalBox() }
				C.uiBoxSetPadded(b, 1)
				zgui_place(s, top_kind, top, unsafe { &C.uiControl(b) }, n.join)
				n.ctl = voidptr(b)
				stack << n
				top_kind = if n.kind == 'begin_hbox' { 'hbox' } else { 'vbox' }
				top = voidptr(b)
				s.row = unsafe { nil }
				continue
			}
			'begin_tabs' {
				t := C.uiNewTab()
				zgui_place(s, top_kind, top, unsafe { &C.uiControl(t) }, false)
				n.ctl = voidptr(t)
				stack << n
				top_kind = 'tabs'
				top = voidptr(t)
				s.row = unsafe { nil }
				continue
			}
			'begin_tab_page' {
				if top_kind != 'tabs' {
					panic('zgui: beginTabPage outside beginTabs / endTabs')
				}
				page := C.uiNewVerticalBox()
				C.uiBoxSetPadded(page, 1)
				tab := unsafe { &C.uiTab(top) }
				C.uiTabAppend(tab, zgui_cstr(n.text), unsafe { &C.uiControl(page) })
				C.uiTabSetMargined(tab, int(n.ival), 1)
				n.ctl = voidptr(page)
				stack << n
				top_kind = 'vbox'
				top = voidptr(page)
				s.row = unsafe { nil }
				continue
			}
			'begin_menu', 'menu_item', 'menu_separator', 'menu_quit', 'end_menu' {
				continue // the menubar is built before the window, from the first frame's declarations
			}
			'begin_panel' {
				g := C.uiNewGroup(zgui_cstr(n.label))
				C.uiGroupSetMargined(g, 1)
				inner := C.uiNewVerticalBox()
				C.uiBoxSetPadded(inner, 1)
				C.uiGroupSetChild(g, unsafe { &C.uiControl(inner) })
				zgui_place(s, top_kind, top, unsafe { &C.uiControl(g) }, false)
				n.ctl = voidptr(inner)
				stack << n
				top_kind = 'vbox'
				top = voidptr(inner)
				s.row = unsafe { nil }
				continue
			}
			'end_form', 'end_hbox', 'end_vbox', 'end_panel', 'end_tabs', 'end_tab_page' {
				if stack.len == 0 {
					panic('zgui: ' + n.kind + ' without a begin')
				}
				stack.delete_last()
				s.row = unsafe { nil }
				if stack.len == 0 {
					top_kind = 'vbox'
					top = voidptr(s.root)
				} else {
					last := stack[stack.len - 1]
					top = last.ctl
					top_kind = match last.kind {
						'begin_form' { 'form' }
						'begin_hbox' { 'hbox' }
						'begin_tabs' { 'tabs' }
						else { 'vbox' }
					}
				}
				continue
			}
			else {}
		}
		ctl := zgui_build_control(n)
		n.ctl = ctl
		if n.tip != '' {
			C.uiControlSetTooltip(unsafe { &C.uiControl(ctl) }, zgui_cstr(n.tip))
		}
		if top_kind == 'form' {
			// a form row: the widget's label on the left, the control on the right
			row_label := if n.kind == 'toggle' { '' } else { n.label }
			C.uiFormAppend(unsafe { &C.uiForm(top) }, zgui_cstr(row_label), unsafe { &C.uiControl(ctl) }, 0)
			continue
		}
		if n.kind == 'table' || n.kind == 'tree' || n.kind == 'area' || n.kind == 'editor' {
			zgui_place_stretchy(s, top_kind, top, unsafe { &C.uiControl(ctl) })
			continue
		}
		if zgui_needs_label(n.kind) && n.label != '' && !n.label.starts_with('##') {
			// a labelled row: [label] [control], joined to the open row if any
			lab := C.uiNewLabel(zgui_cstr(n.label))
			zgui_place(s, top_kind, top, unsafe { &C.uiControl(lab) }, true)
			zgui_place(s, top_kind, top, unsafe { &C.uiControl(ctl) }, n.join)
		} else {
			zgui_place(s, top_kind, top, unsafe { &C.uiControl(ctl) }, n.join)
		}
	}
	if s.frame == 0 {
		C.uiControlShow(unsafe { &C.uiControl(s.window) })
	}
	s.prev = s.cur
	zgui_apply_tab_selects(s)
	zgui_sync_toolbar(s)
}

// `g.selectTab(id, i)` requests from the frame, applied to the built tabs
fn zgui_apply_tab_selects(st &ZGuiState) {
	mut s := unsafe { st }
	if s.tab_select.len == 0 {
		return
	}
	for n in s.prev {
		if n.kind == 'begin_tabs' && n.label in s.tab_select {
			C.uiTabSetSelected(unsafe { &C.uiTab(n.ctl) }, s.tab_select[n.label])
		}
	}
	s.tab_select = map[string]int{}
}

// put a control into the open container: a vertical box gets rows (a sameLine
// keeps the row open), a horizontal box gets the control directly
fn zgui_place(st &ZGuiState, top_kind string, top voidptr, ctl &C.uiControl, keep_row bool) {
	mut s := unsafe { st }
	if top_kind == 'hbox' {
		C.uiBoxAppend(unsafe { &C.uiBox(top) }, ctl, 0)
		return
	}
	if top_kind == 'tabs' {
		panic('zgui: a widget directly inside beginTabs: declare it inside a beginTabPage')
	}
	if s.row == unsafe { nil } {
		s.row = C.uiNewHorizontalBox()
		C.uiBoxSetPadded(s.row, 1)
		C.uiBoxAppend(unsafe { &C.uiBox(top) }, unsafe { &C.uiControl(s.row) }, 0)
		if top == voidptr(s.root) {
			s.root_kids << voidptr(s.row) // a top-level row: the next rebuild takes it down
		}
	}
	C.uiBoxAppend(s.row, ctl, 0)
	if !keep_row {
		s.row = unsafe { nil }
	}
}

// a control that takes the room it is given (a table): stretchy in its box
fn zgui_place_stretchy(st &ZGuiState, top_kind string, top voidptr, ctl &C.uiControl) {
	mut s := unsafe { st }
	if top_kind == 'form' {
		C.uiFormAppend(unsafe { &C.uiForm(top) }, zgui_cstr(''), ctl, 1)
		return
	}
	s.row = unsafe { nil }
	C.uiBoxAppend(unsafe { &C.uiBox(top) }, ctl, 1)
	if top == voidptr(s.root) {
		s.root_kids << voidptr(ctl)
	}
}

// the window's key hook: a registered chord is consumed and queued, any other
// key passes to the focused control (the fork's uiWindowOnKey)
fn zgui_on_window_key(w &C.uiWindow, vk int, mods int, data voidptr) int {
	mut s := unsafe { &ZGuiState(data) }
	chord := (u32(mods & 0xffff) << 16) | u32(vk & 0xffff)
	if chord in s.hot {
		s.keys << chord
		return 1
	}
	return 0
}

fn zgui_script_action(st &ZGuiState, act string) bool {
	mut s := unsafe { st }
	if act == 'quit' {
		return false
	}
	if act == 'tick' {
		for t in s.timers {
			if t.seen {
				zgui_push_sized(s, t.msg, t.size)
			}
		}
		return true
	}
	colon := act.index(':') or { panic('ZGUI_SCRIPT: no verb in ' + act) }
	verb := act[..colon]
	rest := act[colon + 1..]
	mut label := rest
	mut value := ''
	if verb == 'menu' {
		for m in s.menus {
			for it in m.items {
				if it.kind == 'item' && it.label == label {
					zgui_push_sized(s, it.msg, it.size)
					return true
				}
			}
		}
		panic('ZGUI_SCRIPT: no menu item labelled ' + label)
	}
	if verb == 'edtype' || verb == 'edkey' || verb == 'edmargin' {
		// edtype:<text> (appended through Scintilla: an edit, so modified fires),
		// edkey:<vk>,<mods> (a chord to the editor's key hook), edmargin:<line>
		// (a margin click at that line's start); on the first editor placed
		mut target := &ZCodeEditor(unsafe { nil })
		for n in s.prev {
			if n.kind == 'editor' {
				target = s.editors[n.label] or { continue }
				break
			}
		}
		if target == unsafe { nil } || target.sci == unsafe { nil } {
			panic('ZGUI_SCRIPT: ' + verb + ' with no editor placed')
		}
		match verb {
			'edtype' {
				C.uiScintillaSendMessage(target.sci, zsci_appendtext, usize(rest.len), usize(voidptr(rest.str)))
			}
			'edkey' {
				f := rest.split(',')
				if f.len != 2 {
					panic('ZGUI_SCRIPT: edkey wants <vk>,<mods>')
				}
				zgui_ce_key(target.sci, f[0].int(), f[1].int(), voidptr(target))
			}
			else {
				mut n := C.SCNotification{
					text: unsafe { nil }
				}
				n.nmhdr.code = zscn_marginclick
				n.margin = 0
				n.position = isize(C.uiScintillaSendMessage(target.sci, u32(2167), usize(rest.int()), 0)) // SCI_POSITIONFROMLINE
				zgui_ce_notify(target.sci, &n, voidptr(target))
			}
		}
		return true
	}
	if verb == 'winkey' {
		// winkey:<vk>,<mods>: a key-down to the window's hook
		f := rest.split(',')
		if f.len != 2 {
			panic('ZGUI_SCRIPT: winkey wants <vk>,<mods>')
		}
		if s.window == unsafe { nil } {
			panic('ZGUI_SCRIPT: winkey before the window exists')
		}
		zgui_on_window_key(s.window, f[0].int(), f[1].int(), voidptr(s))
		return true
	}
	if verb == 'mouse' || verb == 'key' {
		// mouse:<id>=<ev>,<x>,<y>,<b>  key:<id>=<vk>,<mods>,<0|1>
		eq := rest.index('=') or { panic('ZGUI_SCRIPT: ' + verb + ' wants <id>=...') }
		ar := s.areas[rest[..eq]] or { panic('ZGUI_SCRIPT: no area ' + rest[..eq]) }
		f := rest[eq + 1..].split(',')
		if verb == 'mouse' {
			if f.len != 4 {
				panic('ZGUI_SCRIPT: mouse wants <id>=<ev>,<x>,<y>,<b>')
			}
			ev := f[0].int()
			if ar.is_canvas {
				ar.on_mouse(i64(ev), f[1].f64(), f[2].f64(), i64(f[3].int()))
			} else if ev == 1 {
				ar.on_click(f[1].f64(), f[2].f64(), i64(f[3].int()))
			}
		} else {
			if f.len != 3 {
				panic('ZGUI_SCRIPT: key wants <id>=<vk>,<mods>,<0|1>')
			}
			if ar.is_canvas {
				ar.on_key(i64(f[0].int()), i64(f[1].int()), f[2] == '1')
			}
		}
		return true
	}
	if verb == 'dialog' {
		// the next dialog's answer (an empty path: cancelled)
		s.dialog_answers << rest
		return true
	}
	if verb == 'tool' {
		for it in s.tool_items {
			if it.kind == 'item' && it.label == label {
				zgui_push_sized(s, it.msg, it.size)
				return true
			}
		}
		panic('ZGUI_SCRIPT: no tool labelled ' + label)
	}
	if verb == 'treesel' || verb == 'treeact' || verb == 'treeexp' {
		eq := rest.index('=') or { panic('ZGUI_SCRIPT: ' + verb + ' wants <id>=<key>') }
		t := s.trees[rest[..eq]] or { panic('ZGUI_SCRIPT: no tree ' + rest[..eq]) }
		mut key := rest[eq + 1..]
		mut open := true
		if verb == 'treeexp' {
			eq2 := key.index('=') or { panic('ZGUI_SCRIPT: treeexp wants <id>=<key>=<0|1>') }
			open = key[eq2 + 1..] == '1'
			key = key[..eq2]
		}
		n := zgui_tree_find(t.shown, key)
		if n == unsafe { nil } {
			panic('ZGUI_SCRIPT: no tree node keyed ' + key)
		}
		match verb {
			'treesel' {
				C.uiTreeSetSelection(t.tree, voidptr(n))
				t.on_select(n.key)
			}
			'treeact' { t.on_activate(n.key) }
			else { t.on_expand(n.key, open) }
		}
		return true
	}
	if verb == 'cellcheck' || verb == 'celledit' || verb == 'cellbutton' {
		// <id>=<row>[=<value>]
		eq := rest.index('=') or { panic('ZGUI_SCRIPT: ' + verb + ' wants <id>=<row>[=<value>]') }
		t := s.tables[rest[..eq]] or { panic('ZGUI_SCRIPT: no table ' + rest[..eq]) }
		mut rowtext := rest[eq + 1..]
		mut val := ''
		if eq2 := rowtext.index('=') {
			val = rowtext[eq2 + 1..]
			rowtext = rowtext[..eq2]
		}
		row := rowtext.int()
		match verb {
			'cellcheck' {
				v := C.uiNewTableValueInt(if val == '1' { 1 } else { 0 })
				zgui_tbl_set_cell_value(&t.handler, t.model, row, t.check_col, v)
				C.uiFreeTableValue(v)
			}
			'celledit' {
				v := C.uiNewTableValueString(zgui_cstr(val))
				zgui_tbl_set_cell_value(&t.handler, t.model, row, t.edit_col, v)
				C.uiFreeTableValue(v)
			}
			else {
				zgui_tbl_set_cell_value(&t.handler, t.model, row, t.button_col, unsafe { nil })
			}
		}
		return true
	}
	if verb == 'dblclick' || verb == 'select' {
		eq := rest.index('=') or { panic('ZGUI_SCRIPT: ' + verb + ' wants <id>=<row>') }
		mut t := s.tables[rest[..eq]] or { panic('ZGUI_SCRIPT: no table ' + rest[..eq]) }
		row := rest[eq + 1..].int()
		if verb == 'dblclick' {
			zgui_on_row_double_clicked(t.table, row, voidptr(t))
		} else {
			mut rows := [row]
			sel := C.uiTableSelection{
				NumRows: 1
				Rows: unsafe { &rows[0] }
			}
			C.uiTableSetSelection(t.table, &sel)
		}
		return true
	}
	if verb == 'set' || verb == 'spin' || verb == 'slide' || verb == 'pick' || verb == 'tab' {
		eq := rest.index('=') or { panic('ZGUI_SCRIPT: ' + verb + ' wants <label>=<value>') }
		label = rest[..eq]
		value = rest[eq + 1..]
	}
	for n in s.prev {
		if n.label != label {
			continue
		}
		match verb {
			'click' {
				if n.kind == 'button' {
					zgui_on_click(unsafe { &C.uiButton(n.ctl) }, voidptr(n))
					return true
				}
			}
			'toggle' {
				if n.kind == 'toggle' {
					c := unsafe { &C.uiCheckbox(n.ctl) }
					C.uiCheckboxSetChecked(c, if n.ival == 0 { 1 } else { 0 })
					zgui_on_toggled(c, voidptr(n))
					return true
				}
			}
			'set' {
				if n.kind == 'field' {
					e := unsafe { &C.uiEntry(n.ctl) }
					C.uiEntrySetText(e, zgui_cstr(value))
					zgui_on_entry_changed(e, voidptr(n))
					return true
				}
				if n.kind == 'editcombo' {
					c := unsafe { &C.uiEditableCombobox(n.ctl) }
					C.uiEditableComboboxSetText(c, zgui_cstr(value))
					zgui_on_editcombo_changed(c, voidptr(n))
					return true
				}
			}
			'spin' {
				if n.kind == 'spinbox' {
					sp := unsafe { &C.uiSpinbox(n.ctl) }
					C.uiSpinboxSetValue(sp, value.int())
					zgui_on_spin_changed(sp, voidptr(n))
					return true
				}
			}
			'pick' {
				if n.kind == 'combobox' {
					c := unsafe { &C.uiCombobox(n.ctl) }
					C.uiComboboxSetSelected(c, value.int())
					zgui_on_combo_selected(c, voidptr(n))
					return true
				}
				if n.kind == 'radio' {
					r := unsafe { &C.uiRadioButtons(n.ctl) }
					C.uiRadioButtonsSetSelected(r, value.int())
					zgui_on_radio_selected(r, voidptr(n))
					return true
				}
			}
			'tab' {
				if n.kind == 'begin_tabs' {
					C.uiTabSetSelected(unsafe { &C.uiTab(n.ctl) }, value.int())
					return true
				}
			}
			'slide' {
				if n.kind == 'slider' {
					sl := unsafe { &C.uiSlider(n.ctl) }
					mut m := unsafe { n }
					m.fval = value.f64()
					C.uiSliderSetValue(sl, zgui_slider_step(n))
					zgui_on_slider_changed(sl, voidptr(n))
					return true
				}
			}
			else {
				panic('ZGUI_SCRIPT: unknown verb ' + verb)
			}
		}
	}
	panic('ZGUI_SCRIPT: no ' + verb + ' target labelled ' + label)
}

fn zgui_new_frame(st &ZGuiState) bool {
	mut s := unsafe { st }
	if s.closing {
		return false
	}
	if s.script.len > 0 {
		// scripted: no waiting on events; one action per frame, after the first draw
		if s.frame > 0 {
			act := s.script[0]
			s.script = s.script[1..].clone()
			if !zgui_script_action(s, act) {
				return false
			}
		}
		C.uiMainStep(0)
	} else if s.frame > 0 && !s.redraw {
		if C.uiMainStep(1) == 0 {
			return false
		}
		if s.closing {
			return false
		}
	}
	s.redraw = false
	s.sent = 0
	s.cur = []&ZGuiNode{}
	s.same = false
	s.tool_items = []&ZGuiToolItem{}
	s.tool_next_on = true
	for mut t in s.timers {
		t.seen = false
	}
	return true
}

fn zgui_trace_line(s &ZGuiState) string {
	mut parts := []string{}
	for n in s.prev {
		parts << match n.kind {
			'field' { 'field(' + n.label + '=' + n.text + ')' }
			'editcombo' { 'editcombo(' + n.label + '=' + n.text + ')' }
			'toggle' { 'toggle(' + n.label + '=' + (if n.ival != 0 { 'on' } else { 'off' }) + ')' }
			'spinbox' { 'spinbox(' + n.label + '=' + n.ival.str() + ')' }
			'slider' { 'slider(' + n.label + '=' + n.fval.str() + ')' }
			'progress' { 'progress(' + n.label + '=' + n.ival.str() + '%)' }
			'combobox', 'radio' { n.kind + '(' + n.label + '=' + n.ival.str() + ')' }
			'begin_tabs' { 'tabs(' + n.label + '=' + C.uiTabSelected(unsafe { &C.uiTab(n.ctl) }).str() + ')' }
			'begin_tab_page' { 'page(' + n.text + ')' }
			'begin_vbox', 'begin_hbox' { n.kind + '(' + n.label + (if n.label in s.min_applied { ' min ' + s.min_applied[n.label] } else { '' }) + ')' }
			'table' { 'table(' + n.label + ' ' + zgui_table_words(s.tables[n.label] or { panic('no table') }) + ')' }
			'tree' { 'tree(' + n.label + ' ' + zgui_tree_words((s.trees[n.label] or { panic('no tree') }).shown) + ')' }
			'area' { (if (s.areas[n.label] or { panic('no area') }).is_canvas { 'canvas(' } else { 'area(' }) + n.label + ' ' + (s.areas[n.label] or { panic('no area') }).painted.join(' ') + ')' }
			'editor' { 'editor(' + zgui_ce_send(s.editors[n.label] or { panic('no editor') }, zsci_getlinecount, 0, 0).str() + ' lines' + zgui_ce_style_words(s.editors[n.label] or { panic('no editor') }) + ')' }
			else { n.kind + '(' + n.label + ')' }
		}
	}
	return parts.join(' ')
}

// a table's rows as words: `3 rows: [1 main.zbr] [0 Parser.zbr] [1 README.md]`
fn zgui_table_words(t &ZGuiTable) string {
	mut parts := []string{}
	for r in t.shown {
		parts << '[' + r.join(' ') + ']'
	}
	return t.shown.len.str() + ' rows: ' + parts.join(' ')
}

// a tree's nodes as words: `src/[+main.zbr Parser.zbr gui/[-tree.zbr]] docs/[-README.md] build.zbr`
fn zgui_tree_words(nodes []&ZGuiTNode) string {
	mut parts := []string{}
	for n in nodes {
		if n.is_node {
			parts << n.label + '[' + (if n.expanded { '+' } else { '-' }) + zgui_tree_words(n.children) + ']'
		} else {
			parts << n.label
		}
	}
	return parts.join(' ')
}

fn zgui_end_frame(st &ZGuiState) {
	mut s := unsafe { st }
	zgui_commit(s)
	if s.trace {
		mut tb := ''
		if s.tool_items.len > 0 {
			mut ws := []string{}
			for it in s.tool_items {
				ws << if it.kind == 'separator' { '|' } else { it.label + (if it.enabled { '' } else { '(off)' }) }
			}
			tb = 'toolbar(' + ws.join(' ') + ') '
		}
		mut dl := ''
		if s.dialogs_shown.len > 0 {
			dl = 'dialogs(' + s.dialogs_shown.join(' ') + ') '
		}
		println('[zgui] frame ' + s.frame.str() + ': ' + tb + dl + zgui_trace_line(s))
	}
	s.dialogs_shown = []string{}
	s.frame++
	s.redraw = s.sent > 0
}

// -- the widgets the view declares --------------------------------------------

fn (g Gui) node(kind string, label string) &ZGuiNode {
	mut s := g.st
	n := &ZGuiNode{
		kind: kind
		label: label
		st: s
	}
	if s.same && s.cur.len > 0 {
		s.cur[s.cur.len - 1].join = true // the previous widget keeps its row open
	}
	s.same = false
	s.cur << n
	return n
}

pub fn (g Gui) text(s string) {
	mut st := g.st
	if st.cur_table != unsafe { nil } {
		// a cell: the current column of the current row (a second text in one
		// cell joins with a space, as the Zig section does)
		mut t := st.cur_table
		if t.rows.len == 0 {
			t.rows << []string{}
		}
		mut row := t.rows[t.rows.len - 1]
		for row.len < t.cur_col {
			row << ''
		}
		if row.len == t.cur_col {
			row << s
		} else {
			row[t.cur_col] = row[t.cur_col] + ' ' + s
		}
		t.rows[t.rows.len - 1] = row
		t.cur_col++
		return
	}
	g.node('text', s)
}

pub fn (g Gui) separator() {
	g.node('separator', '')
}

pub fn (g Gui) same_line() {
	mut s := g.st
	s.same = true
}

pub fn (g Gui) spacing() {
	g.node('text', '')
}

// a tooltip on the widget declared just before
pub fn (g Gui) tooltip(tip string) {
	mut s := g.st
	if s.cur.len == 0 {
		return
	}
	mut last := s.cur[s.cur.len - 1]
	last.tip = tip
}

// -- trees (the fork's uiTree): the view declares the whole tree each frame --

pub fn (g Gui) begin_tree[G](id string, on_select fn (string) G, on_activate fn (string) G, on_expand fn (string, bool) G) {
	mut st := g.st
	mut t := st.trees[id] or {
		nt := &ZGuiTree{
			id: id
			st: st
		}
		st.trees[id] = nt
		nt
	}
	t.roots = []&ZGuiTNode{}
	t.stack = []&ZGuiTNode{}
	t.on_select = fn [on_select, st] [G](k string) {
		m := on_select(k)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
	t.on_activate = fn [on_activate, st] [G](k string) {
		m := on_activate(k)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
	t.on_expand = fn [on_expand, st] [G](k string, open bool) {
		m := on_expand(k, open)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
	st.cur_tree = t
}

fn (g Gui) tree_add(key string, label string, is_node bool, expanded bool, icon string) {
	mut t := g.st.cur_tree
	if t == unsafe { nil } {
		panic('zgui: a tree node outside beginTree / endTree')
	}
	mut n := &ZGuiTNode{
		key: key
		label: label
		icon: icon
		is_node: is_node
		expanded: expanded
	}
	if t.stack.len > 0 {
		mut parent := t.stack[t.stack.len - 1]
		n.parent = parent
		parent.children << n
	} else {
		t.roots << n
	}
	if is_node {
		t.stack << n
	}
}

pub fn (g Gui) tree_node(key string, label string, expanded bool) {
	g.tree_add(key, label, true, expanded, '')
}

pub fn (g Gui) tree_node_icon(key string, label string, expanded bool, icon string) {
	g.tree_add(key, label, true, expanded, icon)
}

pub fn (g Gui) tree_leaf(key string, label string) {
	g.tree_add(key, label, false, false, '')
}

pub fn (g Gui) tree_leaf_icon(key string, label string, icon string) {
	g.tree_add(key, label, false, false, icon)
}

pub fn (g Gui) tree_pop() {
	mut t := g.st.cur_tree
	if t != unsafe { nil } && t.stack.len > 0 {
		t.stack.delete_last()
	}
}

fn zgui_tree_structure(nodes []&ZGuiTNode, depth int) string {
	mut parts := []string{}
	for n in nodes {
		parts << depth.str() + ':' + n.key
		if n.is_node {
			parts << zgui_tree_structure(n.children, depth + 1)
		}
	}
	return parts.join('\x01')
}

pub fn (g Gui) end_tree() {
	mut st := g.st
	mut t := st.cur_tree
	if t == unsafe { nil } {
		return
	}
	st.cur_tree = unsafe { nil }
	t.structure = zgui_tree_structure(t.roots, 0)
	mut n := g.node('tree', t.id)
	n.text = t.structure // the keys and their nesting are the node's identity
}

// -- the toolbar: a strip under the menubar, declared every frame --

pub fn (g Gui) begin_toolbar() {
	mut s := g.st
	s.tool_items = []&ZGuiToolItem{}
	s.tool_next_on = true
}

pub fn (g Gui) tool_icon[T](label string, icon string, tip string, msg T) {
	mut s := g.st
	s.tool_items << &ZGuiToolItem{
		kind: 'item'
		label: label
		icon: icon
		tip: tip
		msg: unsafe { memdup(&msg, int(sizeof(T))) }
		size: int(sizeof(T))
		enabled: s.tool_next_on
	}
	s.tool_next_on = true
}

pub fn (g Gui) tool[T](label string, msg T) {
	g.tool_icon(label, '', '', msg)
}

pub fn (g Gui) tool_separator() {
	mut s := g.st
	s.tool_items << &ZGuiToolItem{
		kind: 'separator'
		enabled: true
	}
}

// the next item's enabled state
pub fn (g Gui) tool_enabled(enabled bool) {
	mut s := g.st
	s.tool_next_on = enabled
}

pub fn (g Gui) end_toolbar() {
}

// -- drawing: an area (a click) or a canvas (mouse and keys), painted by the
// draw closure inside libui's draw callback --

fn (g Gui) area_node(id string, w i64, h i64, draw fn (Gui), is_canvas bool) &ZGuiArea {
	mut st := g.st
	mut ar := st.areas[id] or {
		na := &ZGuiArea{
			id: id
			st: st
			is_canvas: is_canvas
		}
		st.areas[id] = na
		na
	}
	ar.w = int(w)
	ar.h = int(h)
	ar.draw = draw
	ar.is_canvas = is_canvas
	mut n := g.node('area', id)
	n.imin = w
	n.imax = h
	return ar
}

pub fn (g Gui) area[G](id string, w i64, h i64, draw fn (Gui), on fn (f64, f64, i64) G) {
	mut ar := g.area_node(id, w, h, draw, false)
	st := g.st
	ar.on_click = fn [on, st] [G](x f64, y f64, b i64) {
		m := on(x, y, b)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) canvas[G](id string, w i64, h i64, draw fn (Gui), on_mouse fn (i64, f64, f64, i64) G, on_key fn (i64, i64, bool) G) {
	mut ar := g.area_node(id, w, h, draw, true)
	st := g.st
	ar.on_mouse = fn [on_mouse, st] [G](ev i64, x f64, y f64, b i64) {
		m := on_mouse(ev, x, y, b)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
	ar.on_key = fn [on_key, st] [G](vk i64, mods i64, down bool) {
		m := on_key(vk, mods, down)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

// the drawing primitives: valid inside a draw closure, nothing elsewhere
pub fn (g Gui) canvas_width() f64 {
	if g.st.paint == unsafe { nil } {
		return 0.0
	}
	return g.st.paint.AreaWidth
}

pub fn (g Gui) canvas_height() f64 {
	if g.st.paint == unsafe { nil } {
		return 0.0
	}
	return g.st.paint.AreaHeight
}

pub fn (g Gui) line(x1 f64, y1 f64, x2 f64, y2 f64, color i64, thickness f64) {
	st := g.st
	if st.paint == unsafe { nil } {
		return
	}
	path := C.uiDrawNewPath(zgui_draw_fill_winding)
	C.uiDrawPathNewFigure(path, x1, y1)
	C.uiDrawPathLineTo(path, x2, y2)
	C.uiDrawPathEnd(path)
	zgui_stroke_path(st, path, color, thickness)
	C.uiDrawFreePath(path)
	zgui_painted(st, 'line')
}

pub fn (g Gui) rect(x f64, y f64, w f64, h f64, color i64, thickness f64) {
	st := g.st
	if st.paint == unsafe { nil } {
		return
	}
	path := C.uiDrawNewPath(zgui_draw_fill_winding)
	C.uiDrawPathAddRectangle(path, x, y, w, h)
	C.uiDrawPathEnd(path)
	zgui_stroke_path(st, path, color, thickness)
	C.uiDrawFreePath(path)
	zgui_painted(st, 'rect')
}

pub fn (g Gui) fill_rect(x f64, y f64, w f64, h f64, color i64) {
	st := g.st
	if st.paint == unsafe { nil } {
		return
	}
	path := C.uiDrawNewPath(zgui_draw_fill_winding)
	C.uiDrawPathAddRectangle(path, x, y, w, h)
	C.uiDrawPathEnd(path)
	zgui_fill_path(st, path, color)
	C.uiDrawFreePath(path)
	zgui_painted(st, 'fillRect')
}

pub fn (g Gui) circle(cx f64, cy f64, r f64, color i64, thickness f64) {
	st := g.st
	if st.paint == unsafe { nil } {
		return
	}
	path := C.uiDrawNewPath(zgui_draw_fill_winding)
	C.uiDrawPathNewFigureWithArc(path, cx, cy, r, 0.0, 2.0 * zgui_pi, 0)
	C.uiDrawPathCloseFigure(path)
	C.uiDrawPathEnd(path)
	zgui_stroke_path(st, path, color, thickness)
	C.uiDrawFreePath(path)
	zgui_painted(st, 'circle')
}

pub fn (g Gui) fill_circle(cx f64, cy f64, r f64, color i64) {
	st := g.st
	if st.paint == unsafe { nil } {
		return
	}
	path := C.uiDrawNewPath(zgui_draw_fill_winding)
	C.uiDrawPathNewFigureWithArc(path, cx, cy, r, 0.0, 2.0 * zgui_pi, 0)
	C.uiDrawPathCloseFigure(path)
	C.uiDrawPathEnd(path)
	zgui_fill_path(st, path, color)
	C.uiDrawFreePath(path)
	zgui_painted(st, 'fillCircle')
}

pub fn (g Gui) draw_text(x f64, y f64, text string, color i64, size f64) {
	st := g.st
	if st.paint == unsafe { nil } {
		return
	}
	astr := C.uiNewAttributedString(zgui_cstr(text))
	c := u32(color & 0xffffff)
	attr := C.uiNewColorAttribute(f64((c >> 16) & 0xff) / 255.0, f64((c >> 8) & 0xff) / 255.0, f64(c & 0xff) / 255.0, 1.0)
	C.uiAttributedStringSetAttribute(astr, attr, 0, C.uiAttributedStringLen(astr))
	mut fd := C.uiFontDescriptor{
		Family: unsafe { nil }
	}
	C.uiLoadControlFont(&fd)
	if size > 0 {
		fd.Size = size
	}
	mut width := st.paint.AreaWidth - x
	if width < 1.0 {
		width = 1.0
	}
	params := C.uiDrawTextLayoutParams{
		String: astr
		DefaultFont: &fd
		Width: width
		Align: zgui_text_align_left
	}
	tl := C.uiDrawNewTextLayout(&params)
	C.uiDrawText(st.paint.Context, tl, x, y)
	C.uiDrawFreeTextLayout(tl)
	C.uiFreeFontDescriptor(&fd)
	C.uiFreeAttributedString(astr)
	zgui_painted(st, 'text')
}

// -- the code editor (Scintilla through the fork's shim) --

fn zgui_ce_new(lang string) CodeEditor {
	ed := &ZCodeEditor{
		lang: lang
		st: zgui_global_state()
	}
	return CodeEditor{
		ed: ed
	}
}

pub fn (k CodeEditorKind) new() CodeEditor {
	return zgui_ce_new('zebra')
}

pub fn (k CodeEditorKind) for_zebra() CodeEditor {
	return zgui_ce_new('zebra')
}

pub fn (k CodeEditorKind) for_language(name string) CodeEditor {
	return zgui_ce_new(name)
}

pub fn (k CodeEditorKind) for_c() CodeEditor {
	return zgui_ce_new('c')
}

pub fn (k CodeEditorKind) for_zig() CodeEditor {
	return zgui_ce_new('zig')
}

// by the extension; an unknown one is plain text, never a guess
pub fn (k CodeEditorKind) for_file(path string) CodeEditor {
	return zgui_ce_new(zgui_ce_spec_for_file(path.to_lower()).name)
}

pub fn (c CodeEditor) set_text(text string) {
	mut ed := c.ed
	ed.text = text
	if ed.sci != unsafe { nil } {
		C.uiScintillaSetText(ed.sci, zgui_cstr(text), u32(text.len))
		zgui_ce_style(ed)
		ed.ev_modified = false // a set is not an edit
	}
}

pub fn (c CodeEditor) get_text() string {
	zgui_ce_pull_text(c.ed)
	return c.ed.text
}

pub fn (c CodeEditor) set_read_only(v bool) {
	mut ed := c.ed
	ed.read_only = v
	zgui_ce_send(ed, zsci_setreadonly, if v { usize(1) } else { usize(0) }, 0)
}

pub fn (c CodeEditor) set_language(name string) {
	mut ed := c.ed
	ed.lang = name
	c.restyle()
}

pub fn (c CodeEditor) get_language() string {
	return c.ed.lang
}

// the live text pulled and styled again (a language change, a program's ask)
pub fn (c CodeEditor) restyle() {
	if c.ed.sci == unsafe { nil } {
		return
	}
	zgui_ce_pull_text(c.ed)
	zgui_ce_style(c.ed)
}

pub fn (c CodeEditor) take_modified() bool {
	mut ed := c.ed
	v := ed.ev_modified
	ed.ev_modified = false
	return v
}

pub fn (c CodeEditor) take_char_added() i64 {
	mut ed := c.ed
	v := ed.ev_char
	ed.ev_char = 0
	return v
}

pub fn (c CodeEditor) take_margin_click() i64 {
	mut ed := c.ed
	v := ed.ev_margin_line
	ed.ev_margin_line = -1
	return v
}

pub fn (c CodeEditor) hotkey(vk i64, mods i64) {
	mut ed := c.ed
	chord := (u32(mods & 0xffff) << 16) | u32(vk & 0xffff)
	if chord !in ed.hot {
		ed.hot << chord
	}
}

// the chords pressed, in order: (mods << 16) | vk, 0 when none
pub fn (c CodeEditor) take_key() i64 {
	mut ed := c.ed
	if ed.keys.len == 0 {
		return 0
	}
	v := ed.keys[0]
	ed.keys = ed.keys[1..].clone()
	return i64(v)
}

// the editor placed where the view says; one record, one control, whatever id
// the view passes (the node is keyed by the record's address)
pub fn (c CodeEditor) render(g Gui, id string, w f64, h f64) {
	mut st := g.st
	key := 'ed:' + u64(voidptr(c.ed)).hex()
	st.editors[key] = c.ed
	g.node('editor', key)
}

pub fn (c CodeEditor) set_error_markers[T](m T) {
	mut st := c.ed.st
	if !st.markers_said {
		eprintln('[zgui] setErrorMarkers is accepted and not acted on by the V libui_ng backend yet')
		st.markers_said = true
	}
}

pub fn (c CodeEditor) get_cursor_line() i64 {
	if c.ed.sci == unsafe { nil } {
		return 1
	}
	pos := zgui_ce_send(c.ed, zsci_getcurrentpos, 0, 0)
	return i64(zgui_ce_send(c.ed, zsci_linefromposition, pos, 0)) + 1
}

pub fn (c CodeEditor) get_cursor_col() i64 {
	if c.ed.sci == unsafe { nil } {
		return 1
	}
	pos := zgui_ce_send(c.ed, zsci_getcurrentpos, 0, 0)
	return i64(zgui_ce_send(c.ed, zsci_getcolumn, pos, 0)) + 1
}

// The hatch: any Scintilla message from Zebra (markers, folding, indicators,
// find, zoom: a message and constants each). 0 before the control exists.
// Scintilla ignores an unknown message (0), so a caller that can read a
// value back should.
pub fn (c CodeEditor) sci(msg i64, wparam i64, lparam i64) i64 {
	if c.ed.sci == unsafe { nil } {
		return 0
	}
	return i64(zgui_ce_send(c.ed, u32(msg), usize(wparam), usize(lparam)))
}

// the string-lParam form (SETTEXT, INSERTTEXT, SEARCHINTARGET, MARKERDEFINE
// ...): a V string is NUL-terminated and outlives the call
pub fn (c CodeEditor) sci_str(msg i64, wparam i64, text string) i64 {
	if c.ed.sci == unsafe { nil } {
		return 0
	}
	return i64(zgui_ce_send(c.ed, u32(msg), usize(wparam), usize(voidptr(text.str))))
}

pub fn (c CodeEditor) set_cursor_position(line i64, col i64) {
	l := if line > 1 { usize(line - 1) } else { usize(0) }
	zgui_ce_send(c.ed, zsci_gotoline, l, 0)
}

// -- the editable combobox and the dialogs --

pub fn (g Gui) combobox_editable[G](label string, items &ZList[string], text string, on fn (string) G) {
	mut n := g.node('editcombo', label)
	n.items = items.items.clone()
	n.text = text
	st := g.st
	n.on_text = fn [on, st] [G](t string) {
		m := on(t)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

// a file dialog: libui's modal one, or, scripted, the next `dialog:` answer
fn (g Gui) file_dialog(kind string) ?string {
	mut s := g.st
	s.dialogs_shown << kind
	if s.script.len > 0 || s.dialog_answers.len > 0 {
		if s.dialog_answers.len == 0 {
			panic('ZGUI_SCRIPT: a ' + kind + ' dialog opened with no dialog:<path> answer queued')
		}
		ans := s.dialog_answers[0]
		s.dialog_answers = s.dialog_answers[1..].clone()
		if ans == '' {
			return none
		}
		return ans
	}
	if s.window == unsafe { nil } {
		return none
	}
	p := match kind {
		'open_file' { C.uiOpenFile(s.window) }
		'save_file' { C.uiSaveFile(s.window) }
		else { C.uiOpenFolder(s.window) }
	}
	if p == unsafe { nil } {
		return none
	}
	t := unsafe { cstring_to_vstring(p) }
	C.uiFreeText(p)
	return t
}

pub fn (g Gui) open_file() ?string {
	return g.file_dialog('open_file')
}

pub fn (g Gui) save_file() ?string {
	return g.file_dialog('save_file')
}

pub fn (g Gui) open_folder() ?string {
	return g.file_dialog('open_folder')
}

fn (g Gui) message_box(kind string, title string, description string) {
	mut s := g.st
	s.dialogs_shown << kind + '(' + title + ')'
	if s.script.len > 0 || s.window == unsafe { nil } {
		return // scripted: recorded in the trace, not shown
	}
	if kind == 'msgbox' {
		C.uiMsgBox(s.window, zgui_cstr(title), zgui_cstr(description))
	} else {
		C.uiMsgBoxError(s.window, zgui_cstr(title), zgui_cstr(description))
	}
}

pub fn (g Gui) msg_box(title string, description string) {
	g.message_box('msgbox', title, description)
}

pub fn (g Gui) msg_box_error(title string, description string) {
	g.message_box('msgbox_error', title, description)
}

// -- the clipboard and the icons (Gui.setClipboardText / clipboardText / registerIcon) --

pub fn (g Gui) set_clipboard_text(text string) {
	C.uiClipboardSetText(zgui_cstr(text))
}

pub fn (g Gui) clipboard_text() string {
	p := C.uiClipboardText()
	if p == unsafe { nil } {
		return ''
	}
	t := unsafe { cstring_to_vstring(p) }
	C.uiFreeText(p)
	return t
}

// straight-alpha RGBA, w*h*4 bytes; called before Gui.run, so the image is
// made once libui is initialised
pub fn (g Gui) register_icon(name string, w i64, h i64, rgba string) {
	mut s := zgui_global_state()
	s.icon_queue << ZGuiIconReq{
		name: name
		w: int(w)
		h: int(h)
		rgba: rgba
	}
}

pub fn (g Gui) button[T](label string, msg T) {
	mut n := g.node('button', label)
	n.size = int(sizeof(T))
	n.msg = unsafe { memdup(&msg, n.size) }
}

// a message sent outright from the view
pub fn (g Gui) send[T](msg T) {
	p := unsafe { memdup(&msg, int(sizeof(T))) }
	zgui_push_sized(g.st, p, int(sizeof(T)))
}

pub fn (g Gui) toggle[G](label string, checked bool, on fn (bool) G) {
	mut n := g.node('toggle', label)
	n.ival = if checked { i64(1) } else { i64(0) }
	st := g.st
	n.on_bool = fn [on, st] [G](b bool) {
		m := on(b)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) field[G](label string, text string, on fn (string) G) {
	mut n := g.node('field', label)
	n.text = text
	st := g.st
	n.on_text = fn [on, st] [G](t string) {
		m := on(t)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) spinbox[G](label string, value i64, min i64, max i64, on fn (i64) G) {
	mut n := g.node('spinbox', label)
	n.ival = value
	n.imin = min
	n.imax = max
	st := g.st
	n.on_int = fn [on, st] [G](v i64) {
		m := on(v)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) slider[G](label string, value f64, min f64, max f64, on fn (f64) G) {
	mut n := g.node('slider', label)
	n.fval = value
	n.fmin = min
	n.fmax = max
	st := g.st
	n.on_f64 = fn [on, st] [G](v f64) {
		m := on(v)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) progress_bar(label string, value f64) {
	mut n := g.node('progress', label)
	mut pct := int(value * 100.0)
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	n.ival = i64(pct)
}

// `g.every(ms, msg)`: the Msg sent every ms while the view keeps declaring it
pub fn (g Gui) every[T](ms i64, msg T) {
	mut s := g.st
	for mut t in s.timers {
		if t.ms == ms {
			t.seen = true
			return
		}
	}
	t := &ZGuiTimer{
		ms: ms
		msg: unsafe { memdup(&msg, int(sizeof(T))) }
		size: int(sizeof(T))
		seen: true
		st: s
	}
	s.timers << t
	if s.script.len == 0 {
		C.uiTimer(int(ms), zgui_on_timer, voidptr(t))
	}
}

pub fn (g Gui) begin_form(id string) {
	g.node('begin_form', id)
}

pub fn (g Gui) end_form(id string) {
	g.node('end_form', id)
}

pub fn (g Gui) begin_hbox(id string, stretch bool) {
	g.node('begin_hbox', id)
}

pub fn (g Gui) end_hbox() {
	g.node('end_hbox', '')
}

pub fn (g Gui) begin_vbox(id string, stretch bool) {
	g.node('begin_vbox', id)
}

pub fn (g Gui) end_vbox() {
	g.node('end_vbox', '')
}

pub fn (g Gui) combobox[G](label string, items &ZList[string], selected i64, on fn (i64) G) {
	mut n := g.node('combobox', label)
	n.items = items.items.clone() // a Zebra list is the runtime's boxed ZList
	n.ival = selected
	st := g.st
	n.on_idx = fn [on, st] [G](i i64) {
		m := on(i)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) radio[G](label string, items &ZList[string], selected i64, on fn (i64) G) {
	mut n := g.node('radio', label)
	n.items = items.items.clone() // a Zebra list is the runtime's boxed ZList
	n.ival = selected
	st := g.st
	n.on_idx = fn [on, st] [G](i i64) {
		m := on(i)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) begin_tabs(id string, stretch bool) {
	g.node('begin_tabs', id)
}

pub fn (g Gui) begin_tab_page(id string, label string) {
	mut n := g.node('begin_tab_page', id)
	n.text = label
	// the page's index among its tabs' pages, for the margin
	mut idx := i64(0)
	mut s := g.st
	for i := s.cur.len - 2; i >= 0; i-- {
		k := s.cur[i].kind
		if k == 'begin_tabs' {
			break
		}
		if k == 'begin_tab_page' {
			idx++
		}
	}
	n.ival = idx
}

pub fn (g Gui) end_tab_page() {
	g.node('end_tab_page', '')
}

pub fn (g Gui) end_tabs() {
	g.node('end_tabs', '')
}

// the selected page of the tabs with this id, as drawn last frame (-1 before)
pub fn (g Gui) tab_selected(id string) i64 {
	for n in g.st.prev {
		if n.kind == 'begin_tabs' && n.label == id && n.ctl != unsafe { nil } {
			return i64(C.uiTabSelected(unsafe { &C.uiTab(n.ctl) }))
		}
	}
	return -1
}

pub fn (g Gui) select_tab(id string, index i64) {
	mut s := g.st
	s.tab_select[id] = int(index)
}

// menus: declared in the first frame, built before the window; later
// declarations are accepted and ignored (the menubar is frozen, said here)
pub fn (g Gui) begin_menu(name string) {
	mut s := g.st
	g.node('begin_menu', name)
	if s.menus_frozen {
		return
	}
	for m in s.menus {
		if m.name == name {
			s.cur_menu = m
			return
		}
	}
	m := &ZGuiMenu{
		name: name
	}
	s.menus << m
	s.cur_menu = m
}

pub fn (g Gui) menu_item[T](label string, msg T) {
	mut s := g.st
	g.node('menu_item', label)
	if s.menus_frozen || s.cur_menu == unsafe { nil } {
		return
	}
	s.cur_menu.items << &ZGuiMenuItem{
		kind: 'item'
		label: label
		msg: unsafe { memdup(&msg, int(sizeof(T))) }
		size: int(sizeof(T))
		st: s
	}
}

pub fn (g Gui) menu_separator() {
	mut s := g.st
	g.node('menu_separator', '')
	if s.menus_frozen || s.cur_menu == unsafe { nil } {
		return
	}
	s.cur_menu.items << &ZGuiMenuItem{
		kind: 'separator'
		st: s
	}
}

pub fn (g Gui) menu_quit() {
	mut s := g.st
	g.node('menu_quit', '')
	if s.menus_frozen || s.cur_menu == unsafe { nil } {
		return
	}
	s.cur_menu.items << &ZGuiMenuItem{
		kind: 'quit'
		st: s
	}
}

pub fn (g Gui) end_menu() {
	mut s := g.st
	g.node('end_menu', '')
	s.cur_menu = unsafe { nil }
}

// the handles `using g.vbox(id, stretch)` binds: begin() / end()
pub struct ZGuiBox {
pub:
	g        Gui
	id       string
	stretch  bool
	vertical bool
}

pub fn (g Gui) vbox(id string, stretch bool) ZGuiBox {
	return ZGuiBox{g, id, stretch, true}
}

pub fn (g Gui) hbox(id string, stretch bool) ZGuiBox {
	return ZGuiBox{g, id, stretch, false}
}

pub fn (b ZGuiBox) begin() {
	if b.vertical {
		b.g.begin_vbox(b.id, b.stretch)
	} else {
		b.g.begin_hbox(b.id, b.stretch)
	}
}

pub fn (b ZGuiBox) end() {
	if b.vertical {
		b.g.end_vbox()
	} else {
		b.g.end_hbox()
	}
}

// a table: the view fills its rows between beginTable and endTable (g.text is a
// cell); the control is one node, its rows the model's
pub fn (g Gui) begin_table(id string, cols i64) bool {
	mut st := g.st
	mut t := st.tables[id] or {
		nt := &ZGuiTable{
			id: id
			st: st
		}
		st.tables[id] = nt
		nt
	}
	t.ncols = int(cols)
	t.names = []string{}
	t.rows = [][]string{}
	t.cur_col = 0
	t.check_col = -1
	t.edit_col = -1
	t.button_col = -1
	st.cur_table = t
	return true
}

pub fn (g Gui) table_setup_column(label string) {
	mut t := g.st.cur_table
	if t != unsafe { nil } {
		t.names << label
	}
}

// the column kinds: a check column (a cell is `tableCheck`), an editable text
// column, a button column (a cell's text is the button's); each with the
// program's closure for the row's toggle, edit or click
pub fn (g Gui) table_setup_check_column[G](label string, on fn (i64, bool) G) {
	mut t := g.st.cur_table
	if t == unsafe { nil } {
		return
	}
	t.check_col = t.names.len
	t.names << label
	st := g.st
	t.on_check = fn [on, st] [G](row i64, checked bool) {
		m := on(row, checked)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) table_setup_edit_column[G](label string, on fn (i64, string) G) {
	mut t := g.st.cur_table
	if t == unsafe { nil } {
		return
	}
	t.edit_col = t.names.len
	t.names << label
	st := g.st
	t.on_edit = fn [on, st] [G](row i64, text string) {
		m := on(row, text)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

pub fn (g Gui) table_setup_button_column[G](label string, on fn (i64) G) {
	mut t := g.st.cur_table
	if t == unsafe { nil } {
		return
	}
	t.button_col = t.names.len
	t.names << label
	st := g.st
	t.on_button = fn [on, st] [G](row i64) {
		m := on(row)
		zgui_push_sized(st, unsafe { memdup(&m, int(sizeof(G))) }, int(sizeof(G)))
	}
}

// a check cell: 1 or 0 as the cell's text (the model reads it as an int)
pub fn (g Gui) table_check(checked bool) {
	g.text(if checked { '1' } else { '0' })
}

pub fn (g Gui) table_headers_row() {
	// the column names are the headers: nothing more to declare
}

pub fn (g Gui) table_next_row() {
	mut t := g.st.cur_table
	if t != unsafe { nil } {
		t.rows << []string{}
		t.cur_col = 0
	}
}

pub fn (g Gui) table_next_column() {
	mut t := g.st.cur_table
	if t != unsafe { nil } && t.rows.len > 0 && t.rows[t.rows.len - 1].len > t.cur_col {
		t.cur_col++
	}
}

pub fn (g Gui) end_table() {
	mut st := g.st
	t := st.cur_table
	if t == unsafe { nil } {
		return
	}
	st.cur_table = unsafe { nil }
	mut n := g.node('table', t.id)
	n.items = t.names.clone() // the columns are the node's identity
}

pub fn (g Gui) table_selected_row(id string) i64 {
	t := g.st.tables[id] or { return -1 }
	if t.table == unsafe { nil } {
		return -1
	}
	sel := C.uiTableGetSelection(t.table)
	if sel == unsafe { nil } {
		return -1
	}
	mut row := i64(-1)
	if sel.NumRows > 0 && sel.Rows != unsafe { nil } {
		row = i64(unsafe { *sel.Rows })
	}
	C.uiFreeTableSelection(sel)
	return row
}

// the double-clicked row since the last read (-1 when none)
pub fn (g Gui) table_activated_row(id string) i64 {
	mut t := g.st.tables[id] or { return -1 }
	v := t.activated
	t.activated = -1
	return i64(v)
}

pub fn (g Gui) hotkey(vk i64, mods i64) {
	mut st := g.st
	chord := (u32(mods & 0xffff) << 16) | u32(vk & 0xffff)
	if chord !in st.hot {
		st.hot << chord
	}
}

// the chords pressed since the last take, in order: (mods << 16) | vk, 0 when none
pub fn (g Gui) take_key() i64 {
	mut st := g.st
	if st.keys.len == 0 {
		return 0
	}
	v := st.keys[0]
	st.keys = st.keys[1..].clone()
	return i64(v)
}

// the minimum size of the container the view keyed `id` last frame (its
// control exists then; the first frame's call finds nothing, as the Zig
// section's)
pub fn (g Gui) min_size(id string, width i64, height i64) {
	for n in g.st.prev {
		if n.label == id && n.ctl != unsafe { nil } {
			w := if width > 0 { int(width) } else { 0 }
			h := if height > 0 { int(height) } else { 0 }
			C.uiControlSetMinSize(unsafe { &C.uiControl(n.ctl) }, w, h)
			mut st := g.st
			st.min_applied[id] = '${w}x${h}'
			return
		}
	}
}

pub fn (g Gui) begin_panel(label string) {
	g.node('begin_panel', label)
}

pub fn (g Gui) end_panel(label string) {
	g.node('end_panel', label)
}

// -- the run loop (Zebra's Gui.run) -----------------------------------------------

pub fn (g Gui) run[M, G](title string, width int, height int, init_fn fn () M, update_fn fn (M, G) M, view_fn fn (Gui, M)) {
	mut st := zgui_global_state()
	handle := Gui{
		st: st
	}
	zgui_init(st, title, width, height)
	mut model := init_fn()
	for zgui_new_frame(st) {
		view_fn(handle, model)
		for i, p in st.queue {
			size := st.queue_sizes[i]
			if size > 0 && size < int(sizeof(G)) {
				// a smaller copy than the Msg: a literal message (`g.every(100, 1)`) is
				// a V int where the program's Msg is i64; read zero-extended, said once
				if !st.size_said {
					eprintln('[zgui] a message of ' + size.str() + ' bytes read as a Msg of ' + int(sizeof(G)).str() + ' bytes (a literal message is a V int): zero-extended')
					st.size_said = true
				}
				mut buf := []u8{len: int(sizeof(G)), init: 0}
				unsafe { vmemcpy(&buf[0], p, size) }
				gp := unsafe { &G(voidptr(&buf[0])) }
				model = update_fn(model, *gp)
				continue
			}
			// (bound to a pointer first: `*(&G(p))` in one expression is emitted as
			// void for a sum type G, 2026-10-14)
			gp := unsafe { &G(p) }
			model = update_fn(model, *gp)
		}
		st.queue = []voidptr{}
		st.queue_sizes = []int{}
		zgui_end_frame(st)
	}
}
