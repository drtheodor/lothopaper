pub const c = @cImport({
    @cDefine("EGL_EGLEXT_PROTOTYPES", "1");
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("wayland-egl.h");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
    @cInclude("GL/glcorearb.h");
});

const Self = @This();

display: ?*anyopaque,
config: c.EGLConfig,
context: c.EGLContext,

pub fn deinit(self: Self) void {
    defer _ = c.eglTerminate(self.display);
    defer _ = c.eglDestroyContext(self.display, self.context);
}

pub const InitError = error{
    EGLInitFailed,
    RoundtripFailed,
    OutOfMemory,
};

pub fn init(tempSurface: ?*c.struct_wl_surface, display: c.EGLNativeDisplayType) InitError!Self {
    // EGL init (shared for all outputs)
    const eglDisplay = c.eglGetDisplay(display);
    var major: c_int = 0;
    var minor: c_int = 0;

    if (c.eglInitialize(eglDisplay, &major, &minor) == 0)
        return error.EGLInitFailed;

    _ = c.eglBindAPI(c.EGL_OPENGL_API);

    const attribs = [_]c.EGLint{
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
        c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_DEPTH_SIZE,      24,
        c.EGL_STENCIL_SIZE,    8,
        c.EGL_NONE,
    };

    var config: c.EGLConfig = undefined;
    var num: c.EGLint = 0;
    _ = c.eglChooseConfig(eglDisplay, &attribs, &config, 1, &num);

    // Shared gl context for all displays
    const ctxAttribs = [_]c.EGLint{
        c.EGL_NONE,
    };
    const eglContext = c.eglCreateContext(
        eglDisplay,
        config,
        c.EGL_NO_CONTEXT,
        &ctxAttribs,
    );

    // Make context current once (on a temporary surface) so it can create the program/VBO
    {
        const tmp_egl_window = c.wl_egl_window_create(tempSurface, 1, 1);
        defer _ = c.wl_egl_window_destroy(tmp_egl_window);

        const tmp_egl_surface = c.eglCreateWindowSurface(
            eglDisplay,
            config,
            @intFromPtr(tmp_egl_window),
            null,
        );
        defer _ = c.eglDestroySurface(eglDisplay, tmp_egl_surface);

        _ = c.eglMakeCurrent(eglDisplay, tmp_egl_surface, tmp_egl_surface, eglContext);
    }

    return .{
        .display = eglDisplay,
        .config = config,
        .context = eglContext,
    };
}

pub const Window = struct {
    window: ?*c.wl_egl_window,
    surface: c.EGLSurface,

    pub inline fn init(egl: Self, surface: ?*c.struct_wl_surface, width: c_int, height: c_int) @This() {
        const eglWindow = c.wl_egl_window_create(surface, width, height);

        const eglSurface = c.eglCreateWindowSurface(
            egl.display,
            egl.config,
            @intFromPtr(eglWindow.?),
            null,
        );

        return .{
            .window = eglWindow,
            .surface = eglSurface,
        };
    }

    pub inline fn valid(self: @This()) bool {
        return self.window != null;
    }

    pub inline fn resize(self: @This(), width: c_int, height: c_int) void {
        if (self.window != null) {
            c.wl_egl_window_resize(self.window, width, height, 0, 0);
        }
    }

    pub inline fn makeCurrent(self: @This(), eglInit: Self) void {
        _ = c.eglMakeCurrent(eglInit.display, self.surface, self.surface, eglInit.context);
    }

    pub inline fn swapBuffers(self: @This(), eglInit: Self) void {
        _ = c.eglSwapBuffers(eglInit.display, self.surface);
    }

    pub inline fn deinit(self: @This(), eglInit: Self) void {
        if (self.surface != null) {
            _ = c.eglDestroySurface(eglInit.display, self.surface);
        }
        if (self.window) |ew| {
            _ = c.wl_egl_window_destroy(ew);
        }
    }
};
