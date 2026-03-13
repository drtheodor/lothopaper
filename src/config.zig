const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const zon = std.zon.parse;

const Self = @This();

pub const Resource = union(enum) {
    image: []const u8,
};

pub const ScaleMode = enum {
    LINEAR,
    NEAREST,
};

pub const RenderMode = enum {
    LIMIT,
    IGNORE,
    WAIT,
};

pub const Permissions = packed struct {
    mouse: bool = false,
    // TODO:
    // windows: bool = false,
    // keyboard: bool = false,
};

pub const Performance = struct {
    on_hover: RenderMode = .LIMIT,
    limited_fps: usize = 30,
};

pub const Data = struct {
    fps: usize = 60,
    max_outputs: usize = 8,
    resources: []const Resource = &.{},
    shadertoy: bool = false,
    time_factor: f32 = 1,
    scale: f32 = 1,
    scale_mode: ScaleMode = .LINEAR,
    permissions: Permissions = .{},
    performance: Performance = .{},
    background_color: [4]f32 = .{ 0, 0, 0, 1 },
};

pub const ValidationError = error{
    ScaleOutOfRange,
    ColorOutOfRange,
};

subpath: ?[]const u8,
data: Data,
allocator: mem.Allocator,

// TODO: improve errors
pub fn readConfigString(self: Self, name: []const u8, def: []const u8) ![]u8 {
    const allocator = self.allocator;
    const path = try self.getConfigPath(name);
    defer allocator.free(path);

    return try readOrCreateFile(self.allocator, path, def, struct {
        fn default(writer: *std.Io.Writer, def2: []const u8) error{WriteFailed}!void {
            _ = try writer.write(def2);
        }
    }.default);
}

fn readOrCreateFile(allocator: mem.Allocator, path: []const u8, ctx: anytype, def: fn (*std.Io.Writer, @TypeOf(ctx)) error{WriteFailed}!void) ![]u8 {
    var file = std.fs.cwd().createFile(path, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // File already exists, open it instead.
            return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        },
        else => return err, // Handle other potential errors
    };
    defer file.close();

    std.debug.print("File '{s}' does not exist. Creating default.\n", .{path});

    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(&buffer);
    var writer = &file_writer.interface;

    try def(writer, ctx);

    try writer.flush();

    return readOrCreateFile(allocator, path, ctx, def);
}

pub fn readConfig(allocator: std.mem.Allocator, subpath: ?[]const u8, init: bool) !?Self {
    var self: Self = .{
        .allocator = allocator,
        .subpath = subpath,
        .data = undefined,
    };
    if (init) try self.ensureConfigPath();

    const path = try self.getConfigPath("config.zon");
    defer allocator.free(path);

    const src = readOrCreateFile(allocator, path, {}, writeDefaultConfig) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("Unable to create '{s}'", .{path});
            return err;
        },
        else => return err,
    };
    defer allocator.free(src);

    const terminated = try allocator.dupeZ(u8, src);
    defer allocator.free(terminated);

    var diag: zon.Diagnostics = .{};
    defer diag.deinit(allocator);

    // Parse the config and check if it failed
    self.data = zon.fromSlice(Data, allocator, terminated, &diag, .{}) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.ParseZon => {
            var buffer: [1024]u8 = undefined;
            var writer = std.fs.File.stdout().writer(&buffer);
            var stdout = &writer.interface;
            try stdout.print("{f}\n", .{diag});
            try stdout.flush();
            return err;
        },
    };

    // Check config errors
    if (self.getError()) |err| {
        switch (err) {
            error.ScaleOutOfRange => std.log.err("scale out of range: [*; 1] expected, got: {d}", .{self.data.scale}),
            error.ColorOutOfRange => std.log.err("background color out of range: [0; 1] expected", .{}),
        }
        return err;
    }
    return self;
}

pub fn getError(self: *Self) ?ValidationError {
    if (self.data.scale > 1)
        return ValidationError.ScaleOutOfRange;
    for (self.data.background_color) |color| if (color < 0 or color > 1)
        return ValidationError.ColorOutOfRange;
    return null;
}

pub fn deinit(self: @This()) void {
    zon.free(self.allocator, self.data);
}

fn ensureConfigPath(self: Self) !void {
    const allocator = self.allocator;

    const base = try self.getConfigBase();
    defer allocator.free(base);

    fs.cwd().makeDir(base) catch {};
}

fn writeDefaultConfig(writer: *std.Io.Writer, _: void) error{WriteFailed}!void {
    const val: Data = .{};

    std.zon.stringify.serialize(val, .{}, writer) catch {
        std.log.err("Failed to serialize the default config", .{});
    };
}

fn getConfigBase(self: Self) ![]u8 {
    const allocator = self.allocator;
    const subpath = self.subpath orelse "";

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const parts = [_][]const u8{
        home,
        ".config",
        "lothopaper",
        subpath,
    };

    return try fs.path.join(allocator, &parts);
}

// Build ~/.config/lothopaper/config/<filename>
pub fn getConfigPath(self: Self, filename: []const u8) ![]u8 {
    const allocator = self.allocator;

    // Get the environment variable "$HOME"
    const base = try self.getConfigBase();
    defer allocator.free(base);

    const parts = [_][]const u8{
        base,
        filename,
    };

    return try fs.path.join(allocator, &parts);
}

pub fn free(self: Self, data: anytype) void {
    self.allocator.free(data);
}
