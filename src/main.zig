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
const clap = @import("clap");
const zigimg = @import("zigimg");

const Config = @import("config.zig");
const gfx = @import("gfx.zig");
const gl = gfx.gl;
const EGL = gfx.EGL;

const vertices = [_]f32{
    -1.0, -1.0, 0.0,
    3.0,  -1.0, 0.0,
    -1.0, 3.0,  0.0,
};

const params = clap.parseParamsComptime(
    \\-h, --help             Display this help and exit.
    //\\-c, --config <usize>   Path to the config directory (default: "~/.config/lothopaper/").
    \\
);

pub fn main() !void {
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

    try drawMain(allocator);
}

pub fn drawMain(allocator: std.mem.Allocator) !void {
    const config = try Config.readConfig(allocator);
    defer config.deinit(allocator);

    var context = try gfx.GfxContext.init(allocator, config.maxOutputs);
    defer context.deinit(allocator);

    const programID = applyConfigShader(allocator) catch |err| {
        std.debug.print("Failed to apply shaders: {}\n", .{err});
        return;
    };

    const timeLoc = gl.glGetUniformLocation(programID, "Time");
    const resLoc = gl.glGetUniformLocation(programID, "Resolution");
    const texLoc = gl.glGetUniformLocation(programID, "uTexture");

    var textureId: ?u32 = null;

    for (config.resources) |resource| {
        switch (resource) {
            .image => |path| {
                const imgPath = try Config.getConfigPath(allocator, path);
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
    const sleepTime: u64 = std.time.ns_per_s / config.fps;
    const startTime = std.time.nanoTimestamp();

    // Main rendering loop
    while (running) {
        const tnow = std.time.nanoTimestamp();

        // FIXME: this is horrid. Why would anyone want time in seconds? Shouldn't we use ns or ms?
        const elapsedSec = @as(f32, @floatFromInt(tnow - startTime)) / @as(f32, @floatFromInt(std.time.ns_per_s));

        // Render a single frame per window
        for (context.getWindows()) |window| {
            if (window.invalid()) continue;

            context.makeCurrent(window);

            gl.glUseProgram(programID);

            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
            gl.glEnableVertexAttribArray(0);
            gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, 0, null);

            gl.glViewport(0, 0, window.width, window.height);
            gl.glClearColor(1.0, 1.0, 1.0, 1.0);
            gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

            gl.glUniform1f(timeLoc, elapsedSec);
            gl.glUniform4f(resLoc, @floatFromInt(window.width), @floatFromInt(window.height), 0, 0);

            if (textureId) |id| {
                gl.glActiveTexture(gl.GL_TEXTURE0);
                gl.glBindTexture(gl.GL_TEXTURE_2D, id);
                gl.glUniform1i(texLoc, @intCast(id - 1));
            }

            gl.glDrawArrays(gl.GL_TRIANGLES, 0, 3);

            context.swapBuffers(window);
        }

        std.Thread.sleep(sleepTime);
    }

    std.debug.print("Exit.\n", .{});
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

    return try gfx.loadProgram(allocator, vertSrc, fragSrc);
}
