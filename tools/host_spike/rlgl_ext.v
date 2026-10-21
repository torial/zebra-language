// The seven rlgl entry points the engine's host uses and vlang/raylib does
// not declare (it binds raylib.h, not rlgl.h): declared by hand against the
// same raylib library, as the host port would carry them. 2026-10-20.
module main

#include <rlgl.h>

fn C.rlPushMatrix()
fn C.rlPopMatrix()
fn C.rlTranslatef(x f32, y f32, z f32)
fn C.rlMultMatrixf(matf &f32)
fn C.rlGetCullDistanceNear() f64
fn C.rlGetCullDistanceFar() f64
fn C.rlDrawRenderBatchActive()

pub fn rl_push_matrix() {
	C.rlPushMatrix()
}

pub fn rl_pop_matrix() {
	C.rlPopMatrix()
}

pub fn rl_translatef(x f32, y f32, z f32) {
	C.rlTranslatef(x, y, z)
}

pub fn rl_get_cull_distance_near() f64 {
	return C.rlGetCullDistanceNear()
}

pub fn rl_get_cull_distance_far() f64 {
	return C.rlGetCullDistanceFar()
}

pub fn rl_draw_render_batch_active() {
	C.rlDrawRenderBatchActive()
}
