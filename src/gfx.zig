const std = @import("std");
const zigimg = @import("zigimg");

pub const gl = egl.c;

pub const ShaderError = error{
    Compile,
    OutOfMemory,
};

// Shader loader
pub fn loadShader(allocator: std.mem.Allocator, s_type: gl.GLenum, src: []const u8) ShaderError!u32 {
    const shader_source_ptr: [*c]const u8 = @as([*c]const u8, src.ptr);
    const shader_sources = [_][*c]const u8{shader_source_ptr};

    const shader = gl.glCreateShader(s_type);

    gl.glShaderSource(shader, 1, &shader_sources, null);
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
            std.log.err("glsl: ({s}): {s}", .{ src, buf });
        } else {
            std.log.err("glsl: '{s}': compilation error (no info log)", .{src});
        }

        return error.Compile;
    }

    return shader;
}

pub fn createTextureFromImage(img: zigimg.Image) gl.GLuint {
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

// merge the vertex and fragment shaders into a shaderprogram
pub fn loadProgram(allocator: std.mem.Allocator, vert_src: []const u8, frag_src: []const u8) ShaderError!u32 {
    const vert_shader = try loadShader(allocator, gl.GL_VERTEX_SHADER, vert_src);
    const frag_shader = try loadShader(allocator, gl.GL_FRAGMENT_SHADER, frag_src);

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

pub const wl = @import("platform/wl.zig");
pub const egl = @import("platform/egl.zig");

pub const OutputWindow = struct {
    const Self = @This();

    surface: *wl.Surface,
    layer_surface: *wl.LayerSurface,
    ctx: *GfxContext,
    egl_window: egl.Window = undefined,
    width: i32 = 0,
    height: i32 = 0,

    configured: bool = false,
    closed: bool = false,

    inline fn createWindow(self: *Self) void {
        self.egl_window = egl.Window.init(self.ctx.egl, @ptrCast(self.surface), self.width, self.height);
    }

    inline fn valid(self: Self) bool {
        return self.configured and !self.closed and self.egl_window.valid();
    }

    pub inline fn invalid(self: Self) bool {
        return !self.valid();
    }

    pub inline fn deinit(self: Self, egl_ctx: egl) void {
        self.egl_window.deinit(egl_ctx);
        self.layer_surface.destroy();
        self.surface.destroy();
    }
};

pub const Pointer = struct {
    const Self = @This();

    surface: ?*wl.Surface = null,
    pointer: *wl.Pointer,
    x: f32 = 0,
    y: f32 = 0,
    left: bool = false,
    right: bool = false,

    fn init(p: *wl.Pointer) Self {
        return .{
            .pointer = p,
        };
    }

    pub fn subscribe(self: *Self) void {
        self.pointer.setListener(*Self, listener, self);
    }

    pub inline fn isActiveIn(self: Self, window: OutputWindow) bool {
        return self.surface == window.surface;
    }

    pub inline fn isActive(self: Self) bool {
        return self.surface != null;
    }

    fn listener(pointer: *wl.Pointer, event: wl.Pointer.Event, self: *Self) void {
        _ = pointer;
        switch (event) {
            .enter => |enter| {
                self.surface = enter.surface;
                self.x = @as(f32, @floatCast(enter.surface_x.toDouble()));
                self.y = @as(f32, @floatCast(enter.surface_y.toDouble()));
            },
            .motion => |motion| {
                self.x = @as(f32, @floatCast(motion.surface_x.toDouble()));
                self.y = @as(f32, @floatCast(motion.surface_y.toDouble()));
            },
            .button => |button| {
                const val = if (button.state == .pressed) true else false;

                switch (button.button) {
                    0x110 => self.left = val,
                    0x111 => self.right = val,
                    else => {},
                }
            },
            .leave => |leave| {
                if (self.surface == leave.surface) {
                    self.surface = null;
                }
            },
            else => {},
        }
    }
};

pub const GfxContext = struct {
    const Self = @This();

    context: wl,
    egl: egl,
    // Create a layer surface and egl window per output
    window_count: usize = 0,
    // Global output windows array
    windows: []OutputWindow,

    pub const InitError = error{
        NoOutputs,
        NoWindows,
    } || wl.InitError || egl.InitError;

    pub fn init(allocator: std.mem.Allocator, maxOutputs: usize) InitError!Self {
        var context = try wl.init(allocator, maxOutputs);
        context.postInit();

        var tmpSurface = try context.compositor.createSurface();
        defer tmpSurface.destroy();

        const tmpLayer = try context.layer.getLayerSurface(
            tmpSurface,
            null,
            wl.LayerShell.Layer.background,
            "lothopaper-init",
        );
        defer tmpLayer.destroy();

        tmpLayer.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        tmpLayer.setExclusiveZone(-1);
        tmpSurface.commit();

        if (context.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        var result: Self = .{
            .context = context,
            .egl = try egl.init(@ptrCast(tmpSurface), @ptrCast(context.display)),
            .windows = try allocator.alloc(OutputWindow, maxOutputs),
        };

        try result.postInit();
        return result;
    }

    fn postInit(self: *Self) InitError!void {
        for (self.outputs()) |out| {
            if (self.window_count >= self.context.outputs.len) break;

            var surface = try self.context.compositor.createSurface();

            const layer = try self.context.layer.getLayerSurface(
                surface,
                out,
                wl.LayerShell.Layer.background,
                "lothopaper",
            );

            layer.setKeyboardInteractivity(.none);
            layer.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });

            // This is legit z offset idk why they have to be fancy and call it exclusive zone
            layer.setExclusiveZone(-1);

            // Initialize window slots
            const window = self.addWindow(.{
                .surface = surface,
                .layer_surface = layer,
                .ctx = self,
            });

            // Per-output listener
            layer.setListener(*OutputWindow, zwlrLayerListenerPerOutput, window);

            // First commit triggers configuration
            surface.commit();
        }

        if (self.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        if (self.window_count == 0) {
            std.log.err("No output windows created.", .{});
            return error.NoWindows;
        }
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.getWindows()) |window| {
            window.deinit(self.egl);
        }

        allocator.free(self.windows);

        self.egl.deinit();
        self.context.deinit(allocator);
    }

    pub inline fn pointer(self: Self) error{NoPointer}!Pointer {
        if (self.context.pointer) |ptr| {
            return Pointer.init(ptr);
        }

        return error.NoPointer;
    }

    pub inline fn swapBuffers(self: Self, window: OutputWindow) void {
        window.egl_window.swapBuffers(self.egl);
    }

    pub inline fn makeCurrent(self: Self, window: OutputWindow) void {
        window.egl_window.makeCurrent(self.egl);
    }

    pub inline fn outputs(self: Self) []*wl.Output {
        return self.context.outputs[0..self.context.output_count];
    }

    pub inline fn poll(self: Self) wl.RoundtripError!void {
        // pending wayland events
        const disp = self.context.display.dispatchPending();

        if (disp != .SUCCESS) {
            std.log.err("dispatchPending error: {}", .{disp});
            return error.RoundtripFailed;
        }

        // flush requests to compositor
        _ = self.context.display.flush();
    }

    pub inline fn roundtrip(self: Self) std.c.E {
        return self.context.display.roundtrip();
    }

    pub inline fn getWindows(self: *Self) []OutputWindow {
        return self.windows[0..self.window_count];
    }

    inline fn addWindow(self: *Self, window: OutputWindow) *OutputWindow {
        self.windows[self.window_count] = window;
        defer self.window_count += 1;

        return &self.windows[self.window_count];
    }

    // Shell listener for zwlr and each monitor
    fn zwlrLayerListenerPerOutput(
        layer_surface: *wl.LayerSurface,
        event: wl.LayerSurface.Event,
        win: *OutputWindow,
    ) void {
        switch (event) {
            .configure => |ev| {
                win.width = @intCast(ev.width);
                win.height = @intCast(ev.height);

                std.log.debug("{X}: configure for output: {}x{}", .{ ev.serial, win.width, win.height });

                layer_surface.ackConfigure(ev.serial);

                if (win.configured) {
                    // if the eglwindow exists just resize
                    win.egl_window.resize(win.width, win.height);
                } else {
                    win.configured = true;
                    win.createWindow();
                }
            },
            .closed => {
                std.log.debug("layer closed for output", .{});
                win.closed = true;
            },
        }
    }
};
