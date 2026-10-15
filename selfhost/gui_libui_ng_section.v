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
// Not here (the Zig section has them): tables, trees, tabs, menus, toolbar,
// combobox, radio, the CodeEditor, drawing, the dialogs, the single-call
// vbox/hbox handles. A call to one of those is a V compile error naming the
// method, not a silent no-op; tooltip is accepted and dropped (said once).
//
// Test hook: ZGUI_SCRIPT drives the window without a mouse, one action per
// frame after the first draw: `click:<label>`, `toggle:<label>`,
// `set:<label>=<text>` (a field), `spin:<label>=<n>`, `slide:<label>=<x>`,
// `tick` (every timer fires once), `quit`. ZGUI_TRACE=1 prints each frame's
// widgets with their values, so a test reads what the window shows.

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
	sent         int  // messages sent since the frame began
	redraw       bool // draw one more frame without waiting
	closing      bool
	frame        int
	script       []string
	trace        bool
	timers       []&ZGuiTimer
	tooltip_said bool
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
	mut s := unsafe { st }
	s.queue << p
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
	zgui_push(n.st, n.msg)
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

fn zgui_on_timer(data voidptr) int {
	t := unsafe { &ZGuiTimer(data) }
	if !t.seen || t.st.closing {
		return 0 // the view stopped declaring it: the timer ends
	}
	zgui_push(t.st, t.msg)
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
	s.window = C.uiNewWindow(zgui_cstr(title), width, height, 0)
	C.uiWindowSetMargined(s.window, 1)
	C.uiWindowOnClosing(s.window, zgui_on_closing, voidptr(s))
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
				else {}
			}
		}
		s.prev = s.cur
		return
	}
	// rebuild: the window's content is one vertical box kept for the program's
	// life (libui refuses to destroy a control that still has a parent: the
	// rebuild DETACHES each top-level child with uiBoxDelete, then destroys it);
	// a container stack holds where the next control goes; a sameLine joins
	// the open row
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
			'end_form', 'end_hbox', 'end_vbox', 'end_panel' {
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
}

// put a control into the open container: a vertical box gets rows (a sameLine
// keeps the row open), a horizontal box gets the control directly
fn zgui_place(st &ZGuiState, top_kind string, top voidptr, ctl &C.uiControl, keep_row bool) {
	mut s := unsafe { st }
	if top_kind == 'hbox' {
		C.uiBoxAppend(unsafe { &C.uiBox(top) }, ctl, 0)
		return
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

fn zgui_script_action(st &ZGuiState, act string) bool {
	mut s := unsafe { st }
	if act == 'quit' {
		return false
	}
	if act == 'tick' {
		for t in s.timers {
			if t.seen {
				zgui_push(s, t.msg)
			}
		}
		return true
	}
	colon := act.index(':') or { panic('ZGUI_SCRIPT: no verb in ' + act) }
	verb := act[..colon]
	rest := act[colon + 1..]
	mut label := rest
	mut value := ''
	if verb == 'set' || verb == 'spin' || verb == 'slide' {
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
	zgui_push(g.st, p)
}

pub fn (g Gui) toggle[G](label string, checked bool, on fn (bool) G) {
	mut n := g.node('toggle', label)
	n.ival = if checked { i64(1) } else { i64(0) }
	st := g.st
	n.on_bool = fn [on, st] [G](b bool) {
		m := on(b)
		zgui_push(st, unsafe { memdup(&m, int(sizeof(G))) })
	}
}

pub fn (g Gui) field[G](label string, text string, on fn (string) G) {
	mut n := g.node('field', label)
	n.text = text
	st := g.st
	n.on_text = fn [on, st] [G](t string) {
		m := on(t)
		zgui_push(st, unsafe { memdup(&m, int(sizeof(G))) })
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
		zgui_push(st, unsafe { memdup(&m, int(sizeof(G))) })
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
		zgui_push(st, unsafe { memdup(&m, int(sizeof(G))) })
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
		for p in st.queue {
			// (bound to a pointer first: `*(&G(p))` in one expression is emitted as
			// void for a sum type G, 2026-10-14)
			gp := unsafe { &G(p) }
			model = update_fn(model, *gp)
		}
		st.queue = []voidptr{}
		zgui_end_frame(st)
	}
}
