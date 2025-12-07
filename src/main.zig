// ==================================================================================
//
// db       .d88b.  d888888b db   db  .d88b.  d8888b.  .d8b.  d8888b. d88888b d8888b.
// 88      .8P  Y8. `~~88~~' 88   88 .8P  Y8. 88  `8D d8' `8b 88  `8D 88'     88  `8D
// 88      88    88    88    88ooo88 88    88 88oodD' 88ooo88 88oodD' 88ooooo 88oobY'
// 88      88    88    88    88~~~88 88    88 88~~~   88~~~88 88~~~   88~~~~~ 88`8b
// 88booo. `8b  d8'    88    88   88 `8b  d8' 88      88   88 88      88.     88 `88.
// Y88888P  `Y88P'     YP    YP   YP  `Y88P'  88      YP   YP 88      Y88888P 88   YD
//
// ===================================Version 1.0.0==================================
//
// Authors:
// - Theo, Loqor
//
// Written in pure, unbridled, messy Zig!
// License: GPL-3.0

const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const egl = @cImport({
    @cDefine("EGL_EGLEXT_PROTOTYPES", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("wayland-egl.h");
});

const gl = @cImport({
    @cInclude("GLES2/gl2.h");
});

// max number of monitors we support (configurable)
const MaxOutputs = 8;

// Per-output window state
const OutputWindow = struct {
    output: *wl.Output,
    surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,
    egl_window: ?*egl.wl_egl_window,
    egl_surface: egl.EGLSurface,
    width: i32,
    height: i32,
    configured: bool,
    closed: bool,
};

// Context for global Wayland objects
const Context = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    layer: ?*zwlr.LayerShellV1 = null,

    outputs: [MaxOutputs]?*wl.Output = .{null} ** MaxOutputs,
    output_count: usize = 0,
};

// Global output windows array
var g_windows: [MaxOutputs]OutputWindow = undefined;
var g_window_count: usize = 0;

var default_win_w: i32 = 400;
var default_win_h: i32 = 300;

pub fn main() !void {
    const startTime = std.time.nanoTimestamp();

    // Connect to wayland
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    var context = Context{};
    registry.setListener(*Context, registryListener, &context);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = context.compositor orelse return error.NoWlCompositor;
    const wm_base = context.wm_base orelse return error.NoXdgWmBase;
    const layer_shell = context.layer orelse return error.NoZwlrLayer;

    wm_base.setListener(*Context, wmBaseListener, &context);

    if (context.output_count == 0) {
        std.debug.print("No wl_output found; nothing to show.\n", .{});
        return;
    }

    // EGL init (shared for all outputs)
    const eglDisplay = egl.eglGetDisplay(@ptrCast(display));
    var major: c_int = 0;
    var minor: c_int = 0;

    if (egl.eglInitialize(eglDisplay, &major, &minor) == 0)
        return error.EGLInitFailed;
    defer _ = egl.eglTerminate(eglDisplay);

    _ = egl.eglBindAPI(egl.EGL_OPENGL_ES_API);

    const attribs = [_]egl.EGLint{
        egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_ES2_BIT,
        egl.EGL_SURFACE_TYPE,    egl.EGL_WINDOW_BIT,
        egl.EGL_RED_SIZE,        8,
        egl.EGL_GREEN_SIZE,      8,
        egl.EGL_BLUE_SIZE,       8,
        egl.EGL_ALPHA_SIZE,      8,
        egl.EGL_NONE,
    };

    var config: egl.EGLConfig = undefined;
    var num: egl.EGLint = 0;
    _ = egl.eglChooseConfig(eglDisplay, &attribs, &config, 1, &num);

    // Shared gl context for all displays
    const ctxAttribs = [_]egl.EGLint{
        egl.EGL_CONTEXT_CLIENT_VERSION, 2,
        egl.EGL_NONE,
    };
    const eglContext = egl.eglCreateContext(
        eglDisplay,
        config,
        egl.EGL_NO_CONTEXT,
        &ctxAttribs,
    );
    defer _ = egl.eglDestroyContext(eglDisplay, eglContext);

    // Allocator for shader loading
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    // Make context current once (on a temporary surface) so it can create the program/VBO
    {
        var tmp_surface = try compositor.createSurface();
        defer tmp_surface.destroy();

        const tmp_layer = try layer_shell.getLayerSurface(
            tmp_surface,
            context.outputs[0].?,
            zwlr.LayerShellV1.Layer.background,
            "zig-layer-demo-init",
        );
        defer tmp_layer.destroy();
        tmp_layer.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        tmp_layer.setExclusiveZone(-1);
        tmp_surface.commit();
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const tmp_egl_window = egl.wl_egl_window_create(@ptrCast(tmp_surface), default_win_w, default_win_h);
        defer _ = egl.wl_egl_window_destroy(tmp_egl_window);

        const tmp_egl_surface = egl.eglCreateWindowSurface(
            eglDisplay,
            config,
            @intFromPtr(tmp_egl_window),
            null,
        );
        defer _ = egl.eglDestroySurface(eglDisplay, tmp_egl_surface);

        _ = egl.eglMakeCurrent(eglDisplay, tmp_egl_surface, tmp_egl_surface, eglContext);
    }

    // Build shader paths under $HOME/.config/lothopaper/config
    const vert_path = try getConfigPath(allocator, "vert.glsl");
    defer allocator.free(vert_path);

    const frag_path = try getConfigPath(allocator, "frag.glsl");
    defer allocator.free(frag_path);

    const programID = try LoadProgram(allocator, vert_path, frag_path);

    // Bullshit geometry setup for the fullscreen quad - can be removed
    var vbo: gl.GLuint = 0;
    gl.glGenBuffers(1, &vbo);

    const vertices = [_]f32{
        -1.0, -1.0, 0.0,
        3.0,  -1.0, 0.0,
        -1.0, 3.0,  0.0,
    };

    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(
        gl.GL_ARRAY_BUFFER,
        @sizeOf(@TypeOf(vertices)),
        &vertices,
        gl.GL_STATIC_DRAW,
    );

    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(
        0,
        3,
        gl.GL_FLOAT,
        gl.GL_FALSE,
        0,
        null,
    );

    const timeLoc = gl.glGetUniformLocation(programID, "Time");
    const resLoc = gl.glGetUniformLocation(programID, "Resolution");

    // Create a layer surface and EGL window per output
    g_window_count = 0;

    for (context.outputs[0..context.output_count]) |maybe_out| {
        if (maybe_out) |out| {
            if (g_window_count >= MaxOutputs) break;

            // wl_surface for this output
            var surface = try compositor.createSurface();

            // zwlr_layer_surface_v1 bound to this specific output
            const layerSurface = try layer_shell.getLayerSurface(
                surface,
                out,
                zwlr.LayerShellV1.Layer.background,
                "zig-layer-demo",
            );

            layerSurface.setAnchor(.{
                .top = true,
                .bottom = true,
                .left = true,
                .right = true,
            });

            // This is legit z offset idk why they have to be fancy and call it exclusive zone
            layerSurface.setExclusiveZone(-1);

            // Initialize window slots
            g_windows[g_window_count] = .{
                .output = out,
                .surface = surface,
                .layer_surface = layerSurface,
                .egl_window = null,
                .egl_surface = null,
                .width = default_win_w,
                .height = default_win_h,
                .configured = false,
                .closed = false,
            };
            const win_ptr: *OutputWindow = &g_windows[g_window_count];

            // Per-output listener
            layerSurface.setListener(*OutputWindow, zwlrLayerListenerPerOutput, win_ptr);

            // First commit triggers configuration
            surface.commit();

            g_window_count += 1;
        }
    }

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Different sizes for configure -> create EGL windows per output
    var i: usize = 0;
    while (i < g_window_count) : (i += 1) {
        const w = &g_windows[i];
        if (w.closed) continue;

        // fallback, if compositor gave us 0x0, use the defaults
        if (w.width <= 0) w.width = default_win_w;
        if (w.height <= 0) w.height = default_win_h;

        const eglWindow = egl.wl_egl_window_create(@ptrCast(w.surface), w.width, w.height);
        // eglWindow is ?*..., but we know it's not null if the creation works
        w.egl_window = eglWindow;

        const eglSurface = egl.eglCreateWindowSurface(
            eglDisplay,
            config,
            @intFromPtr(eglWindow.?),
            null,
        );
        w.egl_surface = eglSurface;
    }

    if (g_window_count == 0) {
        std.debug.print("No output windows created.\n", .{});
        return;
    }

    std.debug.print("Running. Close all layer surfaces to exit.\n", .{});

    var running = true;

    // Main rendering loop
    while (running) {
        // pending wayland events
        const disp_res = display.dispatchPending();
        if (disp_res != .SUCCESS) {
            std.debug.print("dispatchPending error: {}\n", .{disp_res});
            break;
        }

        // flush requests to compositor
        _ = display.flush();

        const tnow = std.time.nanoTimestamp();
        const elapsedSec = @as(f32, @floatFromInt(tnow - startTime)) / 1_000_000_000.0;

        running = false;

        // Render a single frame per window
        i = 0;
        while (i < g_window_count) : (i += 1) {
            const w = &g_windows[i];
            if (w.closed or !w.configured) continue;
            if (w.egl_window == null) continue;

            running = true;

            _ = egl.eglMakeCurrent(eglDisplay, w.egl_surface, w.egl_surface, eglContext);

            gl.glUseProgram(programID);

            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
            gl.glEnableVertexAttribArray(0);
            gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, 0, null);

            gl.glViewport(0, 0, w.width, w.height);
            gl.glClearColor(1.0, 1.0, 1.0, 1.0);
            gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

            gl.glUniform1f(timeLoc, elapsedSec);
            gl.glUniform4f(resLoc, @floatFromInt(w.width), @floatFromInt(w.height), 0, 0);

            gl.glDrawArrays(gl.GL_TRIANGLES, 0, 3);

            _ = egl.eglSwapBuffers(eglDisplay, w.egl_surface);
        }

        std.Thread.sleep(5_000_000); // 5ms i think
    }

    // Nuke 'em
    i = 0;
    while (i < g_window_count) : (i += 1) {
        const w = &g_windows[i];

        if (w.egl_surface != null) {
            _ = egl.eglDestroySurface(eglDisplay, w.egl_surface);
        }
        if (w.egl_window) |ew| {
            _ = egl.wl_egl_window_destroy(ew);
        }
        w.layer_surface.destroy();
        w.surface.destroy();
    }

    std.debug.print("Exit.\n", .{});
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, ctx: *Context) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);

            if (mem.eql(u8, iface, std.mem.span(wl.Compositor.interface.name))) {
                ctx.compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(xdg.WmBase.interface.name))) {
                ctx.wm_base = registry.bind(g.name, xdg.WmBase, 1) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(wl.Shm.interface.name))) {
                ctx.shm = registry.bind(g.name, wl.Shm, 1) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                ctx.layer = registry.bind(g.name, zwlr.LayerShellV1, 4) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(wl.Output.interface.name))) {
                if (ctx.output_count < MaxOutputs) {
                    const out = registry.bind(g.name, wl.Output, 3) catch return;
                    ctx.outputs[ctx.output_count] = out;
                    ctx.output_count += 1;
                }
            }
        },
        else => {},
    }
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, context: *Context) void {
    _ = context;

    switch (event) {
        .ping => |p| {
            wm_base.pong(p.serial);
        },
    }
}

// Shell listener for zwlr and each monitor
fn zwlrLayerListenerPerOutput(
    layer_surface: *zwlr.LayerSurfaceV1,
    event: zwlr.LayerSurfaceV1.Event,
    win: *OutputWindow,
) void {
    switch (event) {
        .configure => |cfg| {
            win.width = @intCast(cfg.width);
            win.height = @intCast(cfg.height);

            std.debug.print(
                "Configure for output {p}: {} x {}\n",
                .{ win.output, win.width, win.height },
            );

            layer_surface.ackConfigure(cfg.serial);

            // if the eglwindow exists just resize
            if (win.egl_window) |w_egl| {
                egl.wl_egl_window_resize(w_egl, win.width, win.height, 0, 0);
            }

            win.configured = true;
        },
        .closed => {
            std.debug.print("Layer closed for output {p}\n", .{win.output});
            win.closed = true;
        },
    }
}

// Shader loader
fn LoadShader(allocator: std.mem.Allocator, shader_type: u32, path: []const u8) !u32 {
    const source_slice = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(source_slice);

    const source_buf = try allocator.alloc(u8, source_slice.len + 1);
    defer allocator.free(source_buf);

    std.mem.copyForwards(u8, source_buf, source_slice);
    source_buf[source_slice.len] = 0;

    const source_c: [*c]const u8 = @as([*c]const u8, source_buf.ptr);

    const shader = gl.glCreateShader(shader_type);
    const sources = [_][*c]const u8{source_c};
    gl.glShaderSource(shader, 1, &sources, null);
    gl.glCompileShader(shader);

    var status: i32 = 0;
    gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var log_len: i32 = 0;
        gl.glGetShaderiv(shader, gl.GL_INFO_LOG_LENGTH, &log_len);
        if (log_len > 0) {
            const buf = try allocator.alloc(u8, @intCast(log_len + 1));
            defer allocator.free(buf);
            gl.glGetShaderInfoLog(shader, log_len, null, buf.ptr);
            std.debug.print("Shader compile log ({s}):\n{s}\n", .{ path, buf });
        } else {
            std.debug.print("Shader {s} failed to compile (no info log)\n", .{path});
        }
        return error.ShaderCompileFailed;
    }

    return shader;
}

// merge the vertex and fragment shaders into a shaderprogram
fn LoadProgram(allocator: std.mem.Allocator, vert_path: []const u8, frag_path: []const u8) !u32 {
    const vert_shader = try LoadShader(allocator, gl.GL_VERTEX_SHADER, vert_path);
    const frag_shader = try LoadShader(allocator, gl.GL_FRAGMENT_SHADER, frag_path);

    const program = gl.glCreateProgram();
    gl.glAttachShader(program, vert_shader);
    gl.glAttachShader(program, frag_shader);

    // Bind the "position" attribute to location 0
    gl.glBindAttribLocation(program, 0, "position");

    gl.glLinkProgram(program);

    // Check link up status (homie)
    var link_status: i32 = 0;
    gl.glGetProgramiv(program, gl.GL_LINK_STATUS, &link_status);
    if (link_status == 0) {
        var log_len: i32 = 0;
        gl.glGetProgramiv(program, gl.GL_INFO_LOG_LENGTH, &log_len);
        if (log_len > 0) {
            const buf = try allocator.alloc(u8, @intCast(log_len + 1));
            defer allocator.free(buf);
            gl.glGetProgramInfoLog(program, log_len, null, buf.ptr);
            std.debug.print("Program link log:\n{s}\n", .{buf});
        } else {
            std.debug.print("Program failed to link (no info log)\n", .{});
        }
        return error.ShaderCompileFailed;
    }

    // Delete those fuckers
    gl.glDeleteShader(vert_shader);
    gl.glDeleteShader(frag_shader);

    return program;
}

// Build ~/.config/lothopaper/config/<filename>
fn getConfigPath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    // Get the environment variable "$HOME"
    const home = try std.process.getEnvVarOwned(allocator, "HOME");

    const parts = [_][]const u8{
        home,
        ".config",
        "lothopaper",
        "config",
        filename,
    };

    const path_joined = try std.fs.path.join(allocator, &parts);
    return path_joined;
}
