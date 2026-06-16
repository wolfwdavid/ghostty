//! Minimal WGL glue for the embedded (Qt) OpenGL renderer on Windows.
//!
//! libghostty's embedded apprt is handed a host-created OpenGL context (an
//! HGLRC) plus the native window (HWND) via GHOSTTY_PLATFORM_QT. The renderer
//! runs on its own thread, so here we make that host context current on the
//! calling (render) thread and present via SwapBuffers. The host (e.g. the Qt
//! app) must NOT keep the context current on any other thread.
//!
//! Only referenced on Windows; the extern declarations are inert on other
//! targets because nothing calls them there.
const std = @import("std");

pub const Error = error{MakeCurrentFailed};

const HWND = *anyopaque;
const HDC = *anyopaque;
const HGLRC = *anyopaque;
const HMODULE = *anyopaque;
const BOOL = i32;

/// Opaque GL function pointer, matching glad's expectation.
pub const GlProc = *const fn () callconv(.c) void;

extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: ?HDC) callconv(.winapi) i32;
extern "gdi32" fn SwapBuffers(hdc: ?HDC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?GlProc;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: ?HMODULE, name: [*:0]const u8) callconv(.winapi) ?GlProc;

var opengl32_module: ?HMODULE = null;

/// glad-compatible loader. wglGetProcAddress resolves GL 1.2+/extension
/// entry points but returns null (or a small sentinel) for the GL 1.0/1.1
/// core, which must come from opengl32.dll directly.
pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?GlProc {
    if (wglGetProcAddress(name)) |p| {
        const addr = @intFromPtr(p);
        const neg1: usize = @bitCast(@as(isize, -1));
        if (addr > 3 and addr != neg1) return p;
    }
    if (opengl32_module == null) opengl32_module = LoadLibraryA("opengl32.dll");
    if (opengl32_module) |m| return GetProcAddress(m, name);
    return null;
}

// The render thread is the only GL thread, so thread-local state mirrors how
// glad already stores its context.
threadlocal var cur_hwnd: ?HWND = null;
threadlocal var cur_hdc: ?HDC = null;

/// Make the host's GL context current on the calling thread.
pub fn makeCurrent(native_window: *anyopaque, gl_context: *anyopaque) Error!void {
    const hwnd: HWND = @ptrCast(native_window);
    const hdc = GetDC(hwnd) orelse return error.MakeCurrentFailed;
    if (wglMakeCurrent(hdc, @ptrCast(gl_context)) == 0) {
        _ = ReleaseDC(hwnd, hdc);
        return error.MakeCurrentFailed;
    }
    cur_hwnd = hwnd;
    cur_hdc = hdc;
}

/// Swap the front/back buffers for the current thread's window.
pub fn swapBuffers() void {
    if (cur_hdc) |hdc| _ = SwapBuffers(hdc);
}

/// Release the context (and DC) on the calling thread.
pub fn clearCurrent() void {
    _ = wglMakeCurrent(null, null);
    if (cur_hwnd) |hwnd| {
        if (cur_hdc) |hdc| _ = ReleaseDC(hwnd, hdc);
    }
    cur_hwnd = null;
    cur_hdc = null;
}
