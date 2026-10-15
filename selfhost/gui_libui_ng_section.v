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
// Not here (the Zig section has them): trees, toolbar, the editable combobox,
// the check / edit / button table columns, the CodeEditor, drawing, the
// dialogs. A call to one of those is a V compile error naming the method, not
// a silent no-op; tooltip, hotkey, takeKey and minSize are accepted and not
// acted on (said once each).
//
// Test hook: ZGUI_SCRIPT drives the window without a mouse, one action per
// frame after the first draw: `click:<label>`, `toggle:<label>`,
// `set:<label>=<text>` (a field), `spin:<label>=<n>`, `slide:<label>=<x>`,
// `pick:<label>=<index>` (a combobox or radio), `tab:<id>=<index>`,
// `menu:<label>` (a menu item), `dblclick:<table id>=<row>`,
// `select:<table id>=<row>`, `tick` (every timer fires once), `quit`.
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
fn C.uiTableOnRowDoubleClicked(t &C.uiTable, f fn (&C.uiTable, int, voidptr), data voidptr)
fn C.uiTableGetSelection(t &C.uiTable) &C.uiTableSelection
fn C.uiTableSetSelection(t &C.uiTable, sel &C.uiTableSelection)
fn C.uiFreeTableSelection(sel &C.uiTableSelection)

const zgui_table_value_string = 0 // uiTableValueTypeString, the enum's first

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
	stubs_said   map[string]bool // hotkey / takeKey / minSize: accepted, not acted on, said once each
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
	st        &ZGuiState = unsafe { nil }
}

// the handle the program's view receives (by value; the state is shared)
pub struct Gui {
pub mut:
	st &ZGuiState = unsafe { nil }
}

// `gui.run(...)` is how the emitter spells Zebra's `Gui.run(...)`
pub const gui = Gui{}

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

fn zgui_tbl_num_columns(mh &C.uiTableModelHandler, m &C.uiTableModel) int {
	t := unsafe { &ZGuiTable(mh) }
	return t.ncols
}

fn zgui_tbl_column_type(mh &C.uiTableModelHandler, m &C.uiTableModel, column int) int {
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
	return C.uiNewTableValueString(zgui_cstr(text))
}

fn zgui_tbl_set_cell_value(mh &C.uiTableModelHandler, m &C.uiTableModel, row int, column int, v &C.uiTableValue) {
	// the columns are not editable: nothing to set
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
		C.uiTableAppendTextColumn(tb, zgui_cstr(name), c, -1, unsafe { nil })
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
	if (a.kind == 'combobox' || a.kind == 'radio') && a.items.join('\x01') != b.items.join('\x01') {
		return false
	}
	if a.kind == 'table' && a.items.join('\x01') != b.items.join('\x01') {
		return false // the columns changed
	}
	return true
}

// a control with no label of its own gets one beside it (or its form row's)
fn zgui_needs_label(kind string) bool {
	return kind == 'field' || kind == 'spinbox' || kind == 'slider' || kind == 'progress'
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
	}
	if s.root == unsafe { nil } {
		s.root = C.uiNewVerticalBox()
		C.uiBoxSetPadded(s.root, 1)
		C.uiWindowSetChild(s.window, unsafe { &C.uiControl(s.root) })
	} else {
		for i := s.root_kids.len - 1; i >= 0; i-- {
			C.uiBoxDelete(s.root, i)
			C.uiControlDestroy(unsafe { &C.uiControl(s.root_kids[i]) })
		}
		s.root_kids = []voidptr{}
		// the destroyed tables' models go too (a model can hold no table when freed)
		for _, mut t in s.tables {
			if t.table != unsafe { nil } {
				t.table = unsafe { nil }
				C.uiFreeTableModel(t.model)
				t.model = unsafe { nil }
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
		if top_kind == 'form' {
			// a form row: the widget's label on the left, the control on the right
			row_label := if n.kind == 'toggle' { '' } else { n.label }
			C.uiFormAppend(unsafe { &C.uiForm(top) }, zgui_cstr(row_label), unsafe { &C.uiControl(ctl) }, 0)
			continue
		}
		if n.kind == 'table' {
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
			'toggle' { 'toggle(' + n.label + '=' + (if n.ival != 0 { 'on' } else { 'off' }) + ')' }
			'spinbox' { 'spinbox(' + n.label + '=' + n.ival.str() + ')' }
			'slider' { 'slider(' + n.label + '=' + n.fval.str() + ')' }
			'progress' { 'progress(' + n.label + '=' + n.ival.str() + '%)' }
			'combobox', 'radio' { n.kind + '(' + n.label + '=' + n.ival.str() + ')' }
			'begin_tabs' { 'tabs(' + n.label + '=' + C.uiTabSelected(unsafe { &C.uiTab(n.ctl) }).str() + ')' }
			'begin_tab_page' { 'page(' + n.text + ')' }
			'table' { 'table(' + n.label + ' ' + (s.tables[n.label] or { panic('no table') }).shown.len.str() + ' rows)' }
			else { n.kind + '(' + n.label + ')' }
		}
	}
	return parts.join(' ')
}

fn zgui_end_frame(st &ZGuiState) {
	mut s := unsafe { st }
	zgui_commit(s)
	if s.trace {
		println('[zgui] frame ' + s.frame.str() + ': ' + zgui_trace_line(s))
	}
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

pub fn (g Gui) tooltip(tip string) {
	mut s := g.st
	if !s.tooltip_said {
		eprintln('[zgui] tooltip is not on the V libui_ng backend yet (dropped: ' + tip + ')')
		s.tooltip_said = true
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
	st.cur_table = t
	return true
}

pub fn (g Gui) table_setup_column(label string) {
	mut t := g.st.cur_table
	if t != unsafe { nil } {
		t.names << label
	}
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

fn (g Gui) stub(name string) {
	mut st := g.st
	if name !in st.stubs_said {
		eprintln('[zgui] ' + name + ' is accepted and not acted on by the V libui_ng backend yet')
		st.stubs_said[name] = true
	}
}

pub fn (g Gui) hotkey(vk i64, mods i64) {
	g.stub('hotkey')
}

pub fn (g Gui) take_key() i64 {
	g.stub('takeKey')
	return 0
}

pub fn (g Gui) min_size(id string, width i64, height i64) {
	g.stub('minSize')
}

pub fn (g Gui) begin_panel(label string) {
	g.node('begin_panel', label)
}

pub fn (g Gui) end_panel(label string) {
	g.node('end_panel', label)
}

// -- the run loop (Zebra's Gui.run) -----------------------------------------------

pub fn (g Gui) run[M, G](title string, width int, height int, init_fn fn () M, update_fn fn (M, G) M, view_fn fn (Gui, M)) {
	mut st := &ZGuiState{}
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
				gp := unsafe { &G(&buf[0]) }
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
