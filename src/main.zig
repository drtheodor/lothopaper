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

const config = @import("config.zig");

const gl = @cImport({
    @cInclude("GLES2/gl2.h");
});

const EGL = @import("egl.zig");

const vertices = [_]f32{
    -1.0, -1.0, 0.0,
    3.0,  -1.0, 0.0,
    -1.0, 3.0,  0.0,
};

const fps = 60;
const sleepTime: u64 = std.time.ns_per_s / fps;

// Per-output window state
const OutputWindow = struct {
    output: *wl.Output,
    surface: *wl.Surface,
    layerSurface: *zwlr.LayerSurfaceV1,
    eglWindow: EGL.Window = undefined,
    width: i32 = 0,
    height: i32 = 0,

    configured: bool = false,
    closed: bool = false,

    inline fn createWindow(self: *@This(), egl: EGL) void {
        self.eglWindow = EGL.Window.init(egl, self.surface, self.width, self.height);
    }

    inline fn swapBuffers(self: @This(), egl: EGL) void {
        self.eglWindow.swapBuffers(egl);
    }

    inline fn makeCurrent(self: @This(), egl: EGL) void {
        self.eglWindow.makeCurrent(egl);
    }

    inline fn valid(self: @This()) bool {
        return self.configured and !self.closed and self.eglWindow.valid();
    }

    inline fn invalid(self: @This()) bool {
        return !self.valid();
    }

    inline fn deinit(self: @This(), egl: EGL) void {
        self.eglWindow.deinit(egl);
        self.layerSurface.destroy();
        self.surface.destroy();
    }
};

// Context for global Wayland objects
const Context = struct {
    compositor: ?*wl.Compositor = null,
    wm: ?*xdg.WmBase = null,
    layer: ?*zwlr.LayerShellV1 = null,
    outputs: [maxOutputs]?*wl.Output = .{null} ** maxOutputs,
    outputCount: usize = 0,
};

// max number of monitors we support (configurable)
const maxOutputs = 8;

pub fn main() !void {
    // Allocator for shader loading
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const startTime = std.time.nanoTimestamp();

    // Connect to wayland
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    var context: Context = .{};

    registry.setListener(*Context, registryListener, &context);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = context.compositor orelse return error.NoWlCompositor;
    const wmBase = context.wm orelse return error.NoXdgWmBase;
    const layerShell = context.layer orelse return error.NoZwlrLayer;

    wmBase.setListener(*Context, wmBaseListener, &context);

    const egl = try EGL.init(compositor, layerShell, display);
    defer egl.deinit();

    if (context.outputCount == 0) {
        std.debug.print("No wl_output found; nothing to show.\n", .{});
        return;
    }

    const programID = try applyConfigShader(allocator);

    const timeLoc = gl.glGetUniformLocation(programID, "Time");
    const resLoc = gl.glGetUniformLocation(programID, "Resolution");

    // Bullshit geometry setup for the fullscreen quad - can be removed
    var vbo: gl.GLuint = 0;
    gl.glGenBuffers(1, &vbo);

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

    // Create a layer surface and EGL window per output
    var windowCount: usize = 0;
    // Global output windows array
    var windows: [maxOutputs]OutputWindow = undefined;

    for (context.outputs[0..context.outputCount]) |maybeOut| {
        if (maybeOut) |out| {
            if (windowCount >= maxOutputs) break;

            // wl_surface for this output
            var surface = try compositor.createSurface();

            // zwlr_layer_surface_v1 bound to this specific output
            const layerSurface = try layerShell.getLayerSurface(
                surface,
                out,
                zwlr.LayerShellV1.Layer.background,
                "lothopaper",
            );

            layerSurface.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });

            // This is legit z offset idk why they have to be fancy and call it exclusive zone
            layerSurface.setExclusiveZone(-1);

            // Initialize window slots
            windows[windowCount] = .{
                .output = out,
                .surface = surface,
                .layerSurface = layerSurface,
            };

            // Per-output listener
            layerSurface.setListener(*OutputWindow, zwlrLayerListenerPerOutput, &windows[windowCount]);

            // First commit triggers configuration
            surface.commit();

            windowCount += 1;
        }
    }

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Must be done after roundtrip.
    // Different sizes for configure -> create EGL windows per output
    {
        var i: usize = 0;
        while (i < windowCount) : (i += 1) {
            windows[i].createWindow(egl);
        }
    }

    if (windowCount == 0) {
        std.debug.print("No output windows created.\n", .{});
        return error.NoWindows;
    }

    std.debug.print("Running. Close all layer surfaces to exit.\n", .{});

    const running = true;

    // Main rendering loop
    while (running) {
        // pending wayland events
        const disp = display.dispatchPending();

        if (disp != .SUCCESS) {
            std.debug.print("dispatchPending error: {}\n", .{disp});
            break;
        }

        // flush requests to compositor
        _ = display.flush();

        const tnow = std.time.nanoTimestamp();
        const elapsedSec = @as(f32, @floatFromInt(tnow - startTime)) / 1_000_000_000.0;

        // Render a single frame per window
        var i: usize = 0;
        while (i < windowCount) : (i += 1) {
            const w = &windows[i];
            if (w.invalid()) continue;

            w.makeCurrent(egl);

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

            w.swapBuffers(egl);
        }

        std.Thread.sleep(sleepTime);
    }

    // Nuke 'em
    var i: usize = 0;
    while (i < windowCount) : (i += 1) {
        windows[i].deinit(egl);
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
                ctx.wm = registry.bind(g.name, xdg.WmBase, 1) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                ctx.layer = registry.bind(g.name, zwlr.LayerShellV1, 4) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(wl.Output.interface.name))) {
                if (ctx.outputCount < maxOutputs) {
                    const out = registry.bind(g.name, wl.Output, 3) catch return;

                    ctx.outputs[ctx.outputCount] = out;
                    ctx.outputCount += 1;
                }
            }
        },
        else => {},
    }
}

fn wmBaseListener(wmBase: *xdg.WmBase, event: xdg.WmBase.Event, context: *Context) void {
    _ = context;

    switch (event) {
        .ping => |p| {
            wmBase.pong(p.serial);
        },
    }
}

// Shell listener for zwlr and each monitor
fn zwlrLayerListenerPerOutput(
    layerSurface: *zwlr.LayerSurfaceV1,
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

            layerSurface.ackConfigure(cfg.serial);

            if (win.configured) {
                // if the eglwindow exists just resize
                win.eglWindow.resize(win.width, win.height);
            } else {
                win.configured = true;
            }
        },
        .closed => {
            std.debug.print("Layer closed for output {p}\n", .{win.output});
            win.closed = true;
        },
    }
}

const ShaderError = error{
    Compile,
    OutOfMemory,
};

// Shader loader
fn loadShader(allocator: std.mem.Allocator, shader_type: u32, src: []const u8) ShaderError!u32 {
    const shaderSourceC: [*c]const u8 = @as([*c]const u8, src.ptr);
    const shaderSources = [_][*c]const u8{shaderSourceC};

    const shader = gl.glCreateShader(shader_type);

    gl.glShaderSource(shader, 1, &shaderSources, null);
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
            std.debug.print("Shader compile log ({s}):\n{s}\n", .{ src, buf });
        } else {
            std.debug.print("Shader {s} failed to compile (no info log)\n", .{src});
        }

        return error.Compile;
    }

    return shader;
}

fn applyConfigShader(allocator: std.mem.Allocator) !u32 {
    const vertSrc = try config.readConfigString(allocator, "vert.glsl");
    defer allocator.free(vertSrc);

    const fragSrc = try config.readConfigString(allocator, "frag.glsl");
    defer allocator.free(fragSrc);

    return try loadProgram(allocator, vertSrc, fragSrc);
}

// merge the vertex and fragment shaders into a shaderprogram
fn loadProgram(allocator: std.mem.Allocator, vertSrc: []const u8, fragSrc: []const u8) ShaderError!u32 {
    const vert_shader = try loadShader(allocator, gl.GL_VERTEX_SHADER, vertSrc);
    const frag_shader = try loadShader(allocator, gl.GL_FRAGMENT_SHADER, fragSrc);

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
        return error.Compile;
    }

    // Delete those fuckers
    gl.glDeleteShader(vert_shader);
    gl.glDeleteShader(frag_shader);

    return program;
}
