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
// in the same places reuse their controls (a label's text updated in place);
// any difference rebuilds the window's content from scratch. A frame runs
// after each event (uiMainStep waits), and once more without waiting when the
// previous frame sent a message, so the updated model is drawn at once.
//
// Messages: `g.button(label, msg)` takes the program's own Msg type (a V sum
// type here), which this file cannot name; the generic method copies the
// value's bytes (memdup, sizeof(T)) into the queue, and the generic run loop
// reads them back as G. A click callback carries the node that holds the copy.
//
// Not here (the Zig section has them): checkbox, slider, input, tables, trees,
// tabs, menus, toolbar, the CodeEditor, drawing. A call to one of those is a V
// compile error naming the method, not a silent no-op.
//
// Test hook: ZGUI_SCRIPT="click:+;click:+;click:-;quit" drives the window
// without a mouse (each frame takes the next action; a click fires the named
// button's callback), and ZGUI_TRACE=1 prints each frame's widgets to stdout,
// so a test reads what the window shows.

// the library: `zig build -Doptimize=ReleaseFast -p zig-out-fast` in libui-ng --
// zig's Debug build instruments the C with the undefined-behaviour sanitizer, and
// that archive wants the sanitizer runtime at link (284 references)
#flag -I $env('ZEBRA_LIBUI_NG')
#flag -L $env('ZEBRA_LIBUI_NG')/zig-out-fast/lib
#flag -lui
// (-lc++: libui-ng's Windows backend has C++ in it; the C driver does not add the C++ runtime)
#flag windows -static -lc++ -luser32 -lkernel32 -lgdi32 -lcomctl32 -luxtheme -lmsimg32 -lcomdlg32 -ld2d1 -ldwrite -lole32 -loleaut32 -loleacc -luuid -lwindowscodecs
#include "ui.h"

struct C.uiInitOptions {
	Size usize
}
struct C.uiControl {}
struct C.uiWindow {}
struct C.uiBox {}
struct C.uiButton {}
struct C.uiLabel {}
struct C.uiSeparator {}

fn C.uiInit(o &C.uiInitOptions) &char
fn C.uiFreeInitError(e &char)
fn C.uiMainStep(wait int) int
fn C.uiQuit()
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
fn C.uiNewButton(text &char) &C.uiButton
fn C.uiButtonSetText(b &C.uiButton, text &char)
fn C.uiButtonOnClicked(b &C.uiButton, f fn (&C.uiButton, voidptr), data voidptr)
fn C.uiNewLabel(text &char) &C.uiLabel
fn C.uiLabelSetText(l &C.uiLabel, text &char)
fn C.uiNewHorizontalSeparator() &C.uiSeparator

// one widget the view declared this frame
@[heap]
struct ZGuiNode {
pub mut:
	kind  string  // text | button | separator
	label string
	ctl   voidptr // the libui control, once built
	msg   voidptr // a button: the copied Msg bytes
	size  int
	join  bool    // the widget after this one was declared on the same line
	st    &ZGuiState = unsafe { nil }
}

@[heap]
struct ZGuiState {
pub mut:
	window   &C.uiWindow = unsafe { nil }
	root     &C.uiBox    = unsafe { nil }
	row      &C.uiBox    = unsafe { nil } // the open horizontal row
	same     bool  // the next widget joins the open row
	prev     []&ZGuiNode // last frame's widgets, in order
	cur      []&ZGuiNode // this frame's
	queue    []voidptr   // Msg copies sent this frame
	sizes    []int
	sent     int   // messages sent since the frame began
	redraw   bool  // draw one more frame without waiting
	closing  bool
	frame    int
	script   []string
	trace    bool
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

fn zgui_on_closing(w &C.uiWindow, data voidptr) int {
	mut st := unsafe { &ZGuiState(data) }
	st.closing = true
	C.uiQuit()
	return 1
}

fn zgui_on_click(b &C.uiButton, data voidptr) {
	mut n := unsafe { &ZGuiNode(data) }
	mut st := n.st
	st.queue << n.msg
	st.sizes << n.size
	st.sent++
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
	s.script = os.getenv('ZGUI_SCRIPT').split(';').filter(it != '')
	s.trace = os.getenv('ZGUI_TRACE') != ''
}

// the new frame's widgets against the last: same kinds and labels in the same
// order reuse the controls (labels updated in place); otherwise rebuild
fn zgui_commit(st &ZGuiState) {
	mut s := unsafe { st }
	mut same := s.prev.len == s.cur.len
	if same {
		for i, n in s.cur {
			if s.prev[i].kind != n.kind {
				same = false
				break
			}
			if n.kind == 'button' && s.prev[i].label != n.label {
				same = false
				break
			}
		}
	}
	if same && s.root != unsafe { nil } {
		for i, mut n in s.cur {
			p := s.prev[i]
			n.ctl = p.ctl
			if n.kind == 'text' && p.label != n.label {
				C.uiLabelSetText(unsafe { &C.uiLabel(n.ctl) }, zgui_cstr(n.label))
			}
			if n.kind == 'button' {
				// the callback's data is the node; point the old control at the new node
				C.uiButtonOnClicked(unsafe { &C.uiButton(n.ctl) }, zgui_on_click, voidptr(n))
			}
		}
		s.prev = s.cur
		return
	}
	// rebuild: a vertical box of rows; a sameLine joins the open row
	if s.root != unsafe { nil } {
		C.uiControlDestroy(unsafe { &C.uiControl(s.root) })
	}
	s.root = C.uiNewVerticalBox()
	C.uiBoxSetPadded(s.root, 1)
	s.row = unsafe { nil }
	for mut n in s.cur {
		mut ctl := voidptr(0)
		match n.kind {
			'text' {
				ctl = voidptr(C.uiNewLabel(zgui_cstr(n.label)))
			}
			'button' {
				b := C.uiNewButton(zgui_cstr(n.label))
				C.uiButtonOnClicked(b, zgui_on_click, voidptr(n))
				ctl = voidptr(b)
			}
			'separator' {
				ctl = voidptr(C.uiNewHorizontalSeparator())
			}
			else {
				panic('zgui: unknown widget kind ' + n.kind)
			}
		}
		n.ctl = ctl
		if s.row == unsafe { nil } {
			s.row = C.uiNewHorizontalBox()
			C.uiBoxSetPadded(s.row, 1)
			C.uiBoxAppend(s.root, unsafe { &C.uiControl(s.row) }, 0)
		}
		C.uiBoxAppend(s.row, unsafe { &C.uiControl(ctl) }, 0)
		if !n.join {
			s.row = unsafe { nil }
		}
	}
	C.uiWindowSetChild(s.window, unsafe { &C.uiControl(s.root) })
	if s.frame == 0 {
		C.uiControlShow(unsafe { &C.uiControl(s.window) })
	}
	s.prev = s.cur
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
			if act == 'quit' {
				return false
			}
			if act.starts_with('click:') {
				label := act['click:'.len..]
				mut hit := false
				for n in s.prev {
					if n.kind == 'button' && n.label == label {
						zgui_on_click(unsafe { &C.uiButton(n.ctl) }, voidptr(n))
						hit = true
						break
					}
				}
				if !hit {
					panic('ZGUI_SCRIPT: no button labelled ' + label)
				}
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
	return true
}

fn zgui_end_frame(st &ZGuiState) {
	mut s := unsafe { st }
	zgui_commit(s)
	if s.trace {
		mut parts := []string{}
		for n in s.prev {
			parts << n.kind + '(' + n.label + ')'
		}
		println('[zgui] frame ' + s.frame.str() + ': ' + parts.join(' '))
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

pub fn (g Gui) button[T](label string, msg T) {
	mut n := g.node('button', label)
	n.size = int(sizeof(T))
	n.msg = unsafe { memdup(&msg, n.size) }
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
		st.sizes = []int{}
		zgui_end_frame(st)
	}
}
