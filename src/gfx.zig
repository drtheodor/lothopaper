const std = @import("std");
const zigimg = @import("zigimg");

pub const gl = @cImport({
    @cInclude("GLES2/gl2.h");
});

pub const ShaderError = error{
    Compile,
    OutOfMemory,
};

// Shader loader
pub fn loadShader(allocator: std.mem.Allocator, shaderType: gl.GLenum, src: []const u8) ShaderError!u32 {
    const shaderSourceC: [*c]const u8 = @as([*c]const u8, src.ptr);
    const shaderSources = [_][*c]const u8{shaderSourceC};

    const shader = gl.glCreateShader(shaderType);

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
pub fn loadProgram(allocator: std.mem.Allocator, vertSrc: []const u8, fragSrc: []const u8) ShaderError!u32 {
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

pub const Wayland = @import("platform/wl.zig");
pub const EGL = @import("platform/egl.zig");

pub const OutputWindow = struct {
    surface: *Wayland.Surface,
    layerSurface: *Wayland.LayerSurface,
    eglWindow: EGL.Window = undefined,
    width: i32 = 0,
    height: i32 = 0,

    configured: bool = false,
    closed: bool = false,

    inline fn createWindow(self: *@This(), egl: EGL) void {
        self.eglWindow = EGL.Window.init(egl, @ptrCast(self.surface), self.width, self.height);
    }

    inline fn valid(self: @This()) bool {
        return self.configured and !self.closed and self.eglWindow.valid();
    }

    pub inline fn invalid(self: @This()) bool {
        return !self.valid();
    }

    pub inline fn deinit(self: @This(), egl: EGL) void {
        self.eglWindow.deinit(egl);
        self.layerSurface.destroy();
        self.surface.destroy();
    }
};

pub const GfxContext = struct {
    context: Wayland,
    egl: EGL,
    // Create a layer surface and EGL window per output
    windowCount: usize = 0,
    // Global output windows array
    windows: []OutputWindow,

    pub const InitError = error{
        NoOutputs,
        NoWindows,
    } || Wayland.InitError || EGL.InitError;

    pub fn init(allocator: std.mem.Allocator, maxOutputs: usize) InitError!@This() {
        const context = try Wayland.init(allocator, maxOutputs);

        var tmpSurface = try context.compositor.createSurface();
        defer tmpSurface.destroy();

        const tmpLayer = try context.layer.getLayerSurface(
            tmpSurface,
            null,
            Wayland.LayerShell.Layer.background,
            "zig-layer-demo-init",
        );

        defer tmpLayer.destroy();
        tmpLayer.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });
        tmpLayer.setExclusiveZone(-1);
        tmpSurface.commit();

        if (context.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        var result: @This() = .{
            .context = context,
            .egl = try EGL.init(@ptrCast(tmpSurface), @ptrCast(context.display)),
            .windows = try allocator.alloc(OutputWindow, maxOutputs),
        };
        try result.postInit();

        return result;
    }

    fn postInit(self: *@This()) InitError!void {
        for (self.outputs()) |out| {
            if (self.windowCount >= self.context.outputs.len) break;

            var surface = try self.context.compositor.createSurface();

            const layer = try self.context.layer.getLayerSurface(
                surface,
                out,
                Wayland.LayerShell.Layer.background,
                "lothopaper",
            );

            layer.setAnchor(.{ .top = true, .bottom = true, .left = true, .right = true });

            // This is legit z offset idk why they have to be fancy and call it exclusive zone
            layer.setExclusiveZone(-1);

            // Initialize window slots
            const window = self.addWindow(.{
                .surface = surface,
                .layerSurface = layer,
            });

            // Per-output listener
            layer.setListener(*OutputWindow, zwlrLayerListenerPerOutput, window);

            // First commit triggers configuration
            surface.commit();
        }

        if (self.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        if (self.windowCount == 0) {
            std.debug.print("No output windows created.\n", .{});
            return error.NoWindows;
        }

        for (self.getWindows()) |*window| {
            window.createWindow(self.egl);
        }
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.getWindows()) |window| {
            window.deinit(self.egl);
        }

        allocator.free(self.windows);

        self.egl.deinit();
        self.context.deinit(allocator);
    }

    pub inline fn swapBuffers(self: @This(), window: OutputWindow) void {
        window.eglWindow.swapBuffers(self.egl);
    }

    pub inline fn makeCurrent(self: @This(), window: OutputWindow) void {
        window.eglWindow.makeCurrent(self.egl);
    }

    pub inline fn outputs(self: @This()) []*Wayland.Output {
        return self.context.outputs[0..self.context.outputCount];
    }

    pub inline fn poll(self: @This()) Wayland.RoundtripError!void {
        // pending wayland events
        const disp = self.display.dispatchPending();

        if (disp != .SUCCESS) {
            std.debug.print("dispatchPending error: {}\n", .{disp});
            return error.RoundtripFailed;
        }

        // flush requests to compositor
        _ = self.display.flush();
    }

    pub inline fn roundtrip(self: @This()) std.c.E {
        return self.context.display.roundtrip();
    }

    pub inline fn getWindows(self: *@This()) []OutputWindow {
        return self.windows[0..self.windowCount];
    }

    inline fn addWindow(self: *@This(), window: OutputWindow) *OutputWindow {
        self.windows[self.windowCount] = window;
        defer self.windowCount += 1;

        return &self.windows[self.windowCount];
    }

    // Shell listener for zwlr and each monitor
    fn zwlrLayerListenerPerOutput(
        layerSurface: *Wayland.LayerSurface,
        event: Wayland.LayerSurface.Event,
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
};
