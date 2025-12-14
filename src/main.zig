// ==================================================================================
//
// db       .d88b.  d888888b db   db  .d88b.  d8888b.  .d8b.  d8888b. d88888b d8888b.
// 88      .8P  Y8. `~~88~~' 88   88 .8P  Y8. 88  `8D d8' `8b 88  `8D 88'     88  `8D
// 88      88    88    88    88ooo88 88    88 88oodD' 88ooo88 88oodD' 88ooooo 88oobY'
// 88      88    88    88    88~~~88 88    88 88~~~   88~~~88 88~~~   88~~~~~ 88`8b
// 88booo. `8b  d8'    88    88   88 `8b  d8' 88      88   88 88      88.     88 `88.
// Y88888P  `Y88P'     YP    YP   YP  `Y88P'  88      YP   YP 88      Y88888P 88   YD
//
// ==================================================================================
//
// Authors:
// - Theo, Loqor
//
// Written in pure, unbridled, messy Zig!
// License: GPL-3.0

const std = @import("std");
const clap = @import("clap");
const zigimg = @import("zigimg");

const Config = @import("config.zig");
const gfx = @import("gfx.zig");
const gl = gfx.gl;
const EGL = gfx.EGL;

const ascii = @import("ascii.zig");

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    \\-c, --config <str>     Overrides the config folder path, relative to the default (~/.config/lothopaper).
    \\-i, --init             Creates the config folder if it's missing.
    \\
);

pub fn main() !void {
    std.debug.print(ascii.ASCII, .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        try diag.reportToFile(.stderr(), err);

        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    };

    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});

    const configSubpath, const initConfig = subpath: {
        if (res.args.config) |subpathOverride| {
            break :subpath .{ subpathOverride, res.args.init != 0 };
        } else break :subpath .{ ".", true };
    };

    const config = Config.readConfig(allocator, configSubpath, initConfig) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Pass --init if you want to create the default config in a subpath.\n", .{});
            return;
        },
        else => return err,
    } orelse {
        std.debug.print("Failed to create config.\n", .{});
        return;
    };

    defer config.deinit();

    try drawMain(allocator, config);
}

const vertices = [_]f32{
    -1.0, -1.0, 0.0,
    3.0,  -1.0, 0.0,
    -1.0, 3.0,  0.0,
};

pub fn drawMain(allocator: std.mem.Allocator, config: Config) !void {
    var context = try gfx.GfxContext.init(allocator, config.data.maxOutputs);
    defer context.deinit(allocator);

    var mouseHandler: ?gfx.Pointer = mouse: {
        if (config.data.permissions.mouse) {
            break :mouse context.pointer() catch {
                std.debug.print("Failed to create a pointer.\n", .{});
                return;
            };
        }

        break :mouse null;
    };

    if (mouseHandler) |*mouse| mouse.subscribe();
    // defer if (mouseHandler) |mouse| mouse.deinit(allocator);

    const programID = applyConfigShader(config) catch |err| {
        std.debug.print("Failed to apply shaders: {}\n", .{err});
        return;
    };

    const timeLoc = gl.glGetUniformLocation(programID, "Time");
    const resLoc = gl.glGetUniformLocation(programID, "Resolution");
    const mousePosLoc = gl.glGetUniformLocation(programID, "MousePos");
    const mouseStateLoc = gl.glGetUniformLocation(programID, "MouseState");
    const texLoc = gl.glGetUniformLocation(programID, "uTexture");

    var textureId: ?u32 = null;

    for (config.data.resources) |resource| {
        switch (resource) {
            .image => |path| {
                const imgPath = try config.getConfigPath(path);
                defer allocator.free(imgPath);

                var testFile = std.fs.cwd().openFile(imgPath, .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        std.debug.print("Couldn't find file: {s}\n", .{imgPath});
                        return;
                    },
                    else => return err,
                };

                defer testFile.close();

                // Temporary read buffer for zigimg
                const read_buf = try allocator.alloc(u8, 64 * 1024); // 64 KiB is usually fine
                defer allocator.free(read_buf);

                var img = try zigimg.Image.fromFile(allocator, testFile, read_buf);
                defer img.deinit(allocator);

                textureId = gfx.createTextureFromImage(img);
            },
        }
    }

    // Bullshit geometry setup for the fullscreen quad - can be removed
    var vao: gl.GLuint = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glGenBuffers(1, &vao);
    gl.glBindVertexArray(vao);

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

    std.debug.print("Running.\n", .{});

    const running = true;
    const noScale = config.data.scale == 1;

    const filter: gl.GLenum = switch (config.data.scaleMode) {
        .LINEAR => gl.GL_LINEAR,
        .NEAREST => gl.GL_NEAREST,
    };
    const bgRed, const bgBlue, const bgGreen, const bgAlpha = config.data.backgroundColor;

    const sleepTime: u64 = std.time.ns_per_s / config.data.fps;
    const startTime = std.time.nanoTimestamp();

    gl.glDisable(gl.GL_DITHER);
    gl.glDisable(gl.GL_BLEND);
    gl.glDisable(gl.GL_DEPTH_TEST);

    if (bgAlpha >= 1) {
        gl.glDisable(gl.GL_ALPHA);
    }

    // Main rendering loop
    while (running) {
        _ = context.context.display.dispatch();
        const tnow = std.time.nanoTimestamp();

        // FIXME: this is horrid. Why would anyone want time in seconds? Shouldn't we use ns or ms?
        const elapsedSec = @as(f32, @floatFromInt(tnow - startTime)) / @as(f32, @floatFromInt(std.time.ns_per_s)) * config.data.timeFactor;

        // Render a single frame per window
        for (context.getWindows()) |window| {
            if (window.invalid()) continue;

            const width: i32 = if (noScale) window.width else @intFromFloat(@as(f32, @floatFromInt(window.width)) * config.data.scale);
            const height: i32 = if (noScale) window.height else @intFromFloat(@as(f32, @floatFromInt(window.height)) * config.data.scale);

            context.makeCurrent(window);

            gl.glUseProgram(programID);

            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
            gl.glEnableVertexAttribArray(0);
            gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, 0, null);

            gl.glViewport(0, 0, width, height);
            gl.glClearColor(bgRed, bgGreen, bgBlue, bgAlpha);
            gl.glClear(gl.GL_COLOR_BUFFER_BIT);

            gl.glUniform1f(timeLoc, elapsedSec);

            if (mouseHandler) |mouse| {
                if (mouse.isActiveIn(window)) {
                    const mouseX = mouse.x * config.data.scale;
                    const mouseY = @as(f32, @floatFromInt(height)) - (mouse.y * config.data.scale);

                    gl.glUniform2f(mousePosLoc, mouseX, mouseY);
                    gl.glUniform2i(mouseStateLoc, if (mouse.right) 1 else 0, if (mouse.left) 1 else 0);
                }
            }

            gl.glUniform4f(resLoc, @floatFromInt(width), @floatFromInt(height), 0, 0);

            if (textureId) |id| {
                gl.glActiveTexture(gl.GL_TEXTURE0);
                gl.glBindTexture(gl.GL_TEXTURE_2D, id);
                gl.glUniform1i(texLoc, @intCast(id - 1));
            }

            gl.glBindVertexArray(vao);
            gl.glDrawArrays(gl.GL_TRIANGLES, 0, 3);

            if (!noScale) {
                gl.glBlitFramebuffer(0, 0, width, height, 0, 0, window.width, window.height, gl.GL_COLOR_BUFFER_BIT, filter);
            }

            context.swapBuffers(window);
        }

        std.Thread.sleep(sleepTime);
    }

    std.debug.print("Exit.\n", .{});
}

fn applyConfigShader(config: Config) !u32 {
    const vertSrc = try config.readConfigString("vert.glsl", ascii.DEFAULT_VERT_SHADER);
    defer config.free(vertSrc);

    const fragSrc = try readFragShader(config);
    defer config.free(fragSrc);

    return gfx.loadProgram(config.allocator, vertSrc, fragSrc) catch |err| {
        std.debug.print("Failed to load shaders. If it's a shadertoy shader, try turning on shadertoy compat in the config.\n", .{});
        return err;
    };
}

fn readFragShader(config: Config) ![]u8 {
    const fragSrc = try config.readConfigString("frag.glsl", ascii.DEFAULT_FRAG_SHADER);

    if (config.data.shadertoy) {
        defer config.allocator.free(fragSrc);
        return std.mem.concat(config.allocator, u8, &.{
            ascii.SHADERTOY_FRAG_PREFIX,
            fragSrc,
            ascii.SHADERTOY_FRAG_SUFFIX,
        });
    }

    return fragSrc;
}
