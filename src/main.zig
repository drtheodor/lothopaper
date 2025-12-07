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

const clap = @import("clap");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const Config = @import("config.zig");

const zigimg = @import("zigimg");

const gl = @cImport({
    @cInclude("GLES2/gl2.h");
});

const EGL = @import("egl.zig");

const vertices = [_]f32{
    -1.0, -1.0, 0.0,
    3.0,  -1.0, 0.0,
    -1.0, 3.0,  0.0,
};

// Per-output window state
const OutputWindow = struct {
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

    outputs: []?*wl.Output,
    outputCount: usize = 0,

    fn init(allocator: mem.Allocator, maxOutputs: usize) error{OutOfMemory}!@This() {
        return .{
            .outputs = try allocator.alloc(?*wl.Output, maxOutputs),
        };
    }

    fn deinit(self: @This(), allocator: mem.Allocator) void {
        allocator.free(self.outputs);
    }
};

pub fn main() !void {
    // Allocator for shader loading
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const config = try Config.readConfig(allocator);
    defer config.deinit(allocator);

    // Connect to wayland
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();

    var context = try Context.init(allocator, config.maxOutputs);
    defer context.deinit(allocator);

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

    const programID = applyConfigShader(allocator) catch |err| {
        std.debug.print("Failed to apply shaders: {}\n", .{err});
        return;
    };

    const timeLoc = gl.glGetUniformLocation(programID, "Time");
    const resLoc = gl.glGetUniformLocation(programID, "Resolution");
    const texLoc = gl.glGetUniformLocation(programID, "uTexture");

    // LOQORS FUCKY SHIT HERE v

    // We HAVE to use getConfigPath for non-String files - like images.
    const imgPath = try Config.getConfigPath(allocator, "image.png");
    var testFile = std.fs.openFileAbsolute(imgPath, .{}) catch |err| blk: {
        std.debug.print("openFileAbsolute('{s}') failed: {s}, falling back to ./test.png\n", .{ imgPath, @errorName(err) });
        break :blk try std.fs.cwd().openFile("test.png", .{});
    };
    defer testFile.close();
    allocator.free(imgPath);

    // Temporary read buffer for zigimg
    const read_buf = try allocator.alloc(u8, 64 * 1024); // 64 KiB is usually fine
    defer allocator.free(read_buf);

    var img = try zigimg.Image.fromFile(allocator, testFile, read_buf);
    defer img.deinit(allocator);

    const textureId = createTextureFromImage(img);
    // LOQORS FUCKY SHIT HERE ^

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
    var windows: []OutputWindow = try allocator.alloc(OutputWindow, config.maxOutputs);

    for (context.outputs[0..context.outputCount]) |maybeOut| {
        if (maybeOut) |out| {
            if (windowCount >= config.maxOutputs) break;

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
    const sleepTime: u64 = std.time.ns_per_s / config.fps;
    const startTime = std.time.nanoTimestamp();

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

            gl.glActiveTexture(gl.GL_TEXTURE0);
            gl.glBindTexture(gl.GL_TEXTURE_2D, textureId);
            gl.glUniform1i(texLoc, @intCast(textureId - 1));

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
                if (ctx.outputCount < ctx.outputs.len) {
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
                "Configure for output: {} x {}\n",
                .{ win.width, win.height },
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
            std.debug.print("Layer closed for output\n", .{});
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

const DEFAULT_VERT_SHADER =
    \\#version 320 es
    \\precision highp float;
    \\
    \\in vec2 a_Position;
    \\in vec2 a_TexCoord;
    \\
    \\out vec2 v_TexCoord;
    \\
    \\void main() {
    \\    // Pass texture coordinates directly
    \\    v_TexCoord = a_TexCoord;
    \\
    \\    // Set the final position directly, no matrix math needed
    \\    gl_Position = vec4(a_Position, 0.0, 1.0);
    \\}
;

const DEFAULT_FRAG_SHADER =
    \\#version 320 es
    \\precision mediump float;
    \\
    \\uniform float Time;
    \\uniform vec4 Resolution;
    \\uniform sampler2D uTexture;
    \\
    \\out vec4 FragColor;
    \\
    \\vec4 background(vec2 fragCoord, vec2 screenDims) {
    \\    // Normalized coordinates [0,1]
    \\    vec2 uv = fragCoord / screenDims;
    \\
    \\    // Simple vertical gradient: dark at bottom, slightly lighter at top
    \\    vec3 topColor = vec3(0.05, 0.10, 0.25); // dark bluish
    \\    vec3 bottomColor = vec3(0.00, 0.02, 0.10); // almost black-blue
    \\
    \\    float t = uv.y;
    \\    vec3 col = mix(bottomColor, topColor, t);
    \\
    \\    // optional subtle vignette
    \\    vec2 c = uv - 0.5;
    \\    float vignette = 1.0 - dot(c, c) * 0.8;
    \\    vignette = clamp(vignette, 0.0, 1.0);
    \\
    \\    col *= vignette;
    \\
    \\    return vec4(col, 1.0);
    \\}
    \\
    \\void main(void) {
    \\    vec2 screenDims = Resolution.xy;
    \\
    \\    ivec2 textureDims_i = textureSize(uTexture, 0);
    \\    vec2 textureDims = vec2(textureDims_i) * 2.0;
    \\
    \\    vec2 maxPos = screenDims - textureDims;
    \\
    \\    // If the texture is larger than the screen, just fullscreen it
    \\    if (maxPos.x < 0.0 || maxPos.y < 0.0) {
    \\        vec2 uv = gl_FragCoord.xy / screenDims;
    \\        vec4 tex = texture(uTexture, uv);
    \\        FragColor = tex;
    \\        return;
    \\    }
    \\
    \\    float speedX = 0.04;
    \\    float speedY = 0.02;
    \\
    \\    float timeX = Time * speedX;
    \\    float timeY = Time * speedY;
    \\
    \\    float normalizedPosX = abs(fract(timeX) * 2.0 - 1.0);
    \\    float normalizedPosY = abs(fract(timeY) * 2.0 - 1.0);
    \\
    \\    vec2 ImagePosition = vec2(
    \\            normalizedPosX * maxPos.x,
    \\            normalizedPosY * maxPos.y
    \\        );
    \\
    \\    vec2 fragCoord = gl_FragCoord.xy;
    \\    vec2 relativeCoord = fragCoord - ImagePosition;
    \\
    \\    // Outside the image rect → gradient background
    \\    if (relativeCoord.x < 0.0 || relativeCoord.y < 0.0 ||
    \\            relativeCoord.x > textureDims.x || relativeCoord.y > textureDims.y) {
    \\        FragColor = background(fragCoord, screenDims);
    \\        return;
    \\    }
    \\
    \\    vec2 uv = relativeCoord / textureDims;
    \\    uv.y = 1.0 - uv.y;
    \\
    \\    vec4 tex = texture(uTexture, uv);
    \\    FragColor = tex;
    \\}
;

fn applyConfigShader(allocator: std.mem.Allocator) !u32 {
    const vertSrc = try Config.readConfigString(allocator, "vert.glsl", DEFAULT_VERT_SHADER);
    defer allocator.free(vertSrc);

    const fragSrc = try Config.readConfigString(allocator, "frag.glsl", DEFAULT_FRAG_SHADER);
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

fn createTextureFromImage(img: zigimg.Image) gl.GLuint {
    var tex: gl.GLuint = 0;

    gl.glGenTextures(1, &tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);

    const img_format = img.pixelFormat();
    const width = img.width;
    const height = img.height;

    var internal_format: gl.GLenum = gl.GL_RGBA;
    var data_format: gl.GLenum = gl.GL_RGBA;

    switch (img_format) {
        .rgba32 => {
            internal_format = gl.GL_RGBA;
            data_format = gl.GL_RGBA;
        },
        .rgb24 => {
            internal_format = gl.GL_RGB;
            data_format = gl.GL_RGB;
        },
        else => {
            // Fallback: convert to RGBA8
            // zigimg CAN do conversion, but yk we should assume RGBA/RGB input
            internal_format = gl.GL_RGBA;
            data_format = gl.GL_RGBA;
        },
    }

    const pixels = img.rawBytes();

    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        @as(c_int, @intCast(internal_format)),
        @as(gl.GLsizei, @intCast(width)),
        @as(gl.GLsizei, @intCast(height)),
        0,
        data_format,
        gl.GL_UNSIGNED_BYTE,
        pixels.ptr,
    );

    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    return tex;
}
