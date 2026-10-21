// The V host spike (2026-10-20, the V docket's item 5, first act): the
// sandbox scene -- a window, a camera, a floor, a box, a text line -- through
// vlang/raylib, N frames drawn, the frame time measured, then the window
// closed. Not a port of the host; the question it answers is whether the
// binding builds and links against the raylib the engine already builds, and
// what a frame costs on this machine through it.
import raylib as rl
import time
import os
import math

fn main() {
	frames := if os.args.len > 1 { os.args[1].int() } else { 120 }
	rl.set_trace_log_level(int(rl.TraceLogLevel.log_warning))
	rl.init_window(1280, 720, 'Zebra host spike (V, raylib)')
	rl.set_target_fps(0)
	mut cam := rl.Camera3D{
		position:   rl.Vector3{ x: 10.0, y: 8.0, z: 10.0 }
		target:     rl.Vector3{ x: 0.0, y: 1.0, z: 0.0 }
		up:         rl.Vector3{ x: 0.0, y: 1.0, z: 0.0 }
		fovy:       45.0
		projection: int(rl.CameraProjection.camera_perspective)
	}
	mut n := 0
	mut worst := 0.0
	mut total := 0.0
	t0 := time.now()
	for n < frames && !rl.window_should_close() {
		f0 := time.now()
		cam.position.x = 10.0 * f32(math.cos(f64(n) * 0.02))
		cam.position.z = 10.0 * f32(math.sin(f64(n) * 0.02))
		rl.begin_drawing()
		rl.clear_background(rl.Color{ r: 30, g: 36, b: 48, a: 255 })
		rl.begin_mode_3d(cam)
		rl.draw_plane(rl.Vector3{ x: 0.0, y: 0.0, z: 0.0 }, rl.Vector2{ x: 40.0, y: 40.0 }, rl.Color{ r: 70, g: 110, b: 70, a: 255 })
		rl.draw_cube(rl.Vector3{ x: 0.0, y: 1.0, z: 0.0 }, 2.0, 2.0, 2.0, rl.Color{ r: 200, g: 120, b: 60, a: 255 })
		rl.draw_cube_wires(rl.Vector3{ x: 0.0, y: 1.0, z: 0.0 }, 2.0, 2.0, 2.0, rl.Color{ r: 20, g: 20, b: 20, a: 255 })
		// a second cube through rlgl's matrix stack, as the host draws its outlines
		rl_push_matrix()
		rl_translatef(4.0, 1.0, 0.0)
		rl.draw_cube(rl.Vector3{ x: 0.0, y: 0.0, z: 0.0 }, 1.0, 1.0, 1.0, rl.Color{ r: 80, g: 140, b: 220, a: 255 })
		rl_pop_matrix()
		rl.draw_grid(20, 1.0)
		rl.end_mode_3d()
		rl.draw_text('V host spike: frame ${n}', 10, 10, 20, rl.Color{ r: 240, g: 240, b: 240, a: 255 })
		rl.end_drawing()
		ms := f64(time.since(f0).microseconds()) / 1000.0
		total += ms
		if ms > worst {
			worst = ms
		}
		n++
	}
	wall := f64(time.since(t0).milliseconds()) / 1000.0
	cull_near := rl_get_cull_distance_near()   // not `near` / `far`: macros in the Windows headers
	cull_far := rl_get_cull_distance_far()
	rl.close_window()
	println('spike: ${n} frames in ${wall:.2f} s; mean ${total / f64(n):.2f} ms, worst ${worst:.2f} ms; cull near ${cull_near:.2f} far ${cull_far:.0f}')
}

