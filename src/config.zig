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
    onHover: RenderMode = .LIMIT,
    limitedFps: usize = 30,
};

pub const Data = struct {
    fps: usize = 60,
    maxOutputs: usize = 8,
    resources: []const Resource = &.{},
    shadertoy: bool = false,
    timeFactor: f32 = 1,
    scale: f32 = 1,
    scaleMode: ScaleMode = .LINEAR,
    permissions: Permissions = .{},
    performance: Performance = .{},
    backgroundColor: [4]f32 = .{ 0, 0, 0, 1 },
};

subpath: []const u8,
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
    var fileWriter = file.writer(&buffer);
    var writer = &fileWriter.interface;

    try def(writer, ctx);

    try writer.flush();

    return readOrCreateFile(allocator, path, ctx, def);
}

pub fn readConfig(allocator: std.mem.Allocator, subpath: []const u8, init: bool) !?Self {
    var self: Self = .{
        .allocator = allocator,
        .subpath = subpath,
        .data = undefined,
    };

    if (init) {
        try self.ensureConfigPath();
    }

    const path = try self.getConfigPath("config.zon");
    defer allocator.free(path);

    const src = readOrCreateFile(allocator, path, {}, writeDefaultConfig) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Couldn't create file {s}\n", .{path});
            return err;
        },
        else => return err,
    };

    std.debug.print("Config: {s}\n", .{src});
    defer allocator.free(src);

    const terminated = try allocator.dupeZ(u8, src);
    defer allocator.free(terminated);

    var diag: zon.Diagnostics = .{};
    defer diag.deinit(allocator);

    const data = zon.fromSlice(Data, allocator, terminated, &diag, .{
        .free_on_error = true,
        .ignore_unknown_fields = false,
    });

    const stdoutFile = std.fs.File.stdout();
    var buffer: [1024]u8 = undefined; // Define a buffer for the writer
    var writer = stdoutFile.writer(&buffer);
    var stdout = &writer.interface;

    try diag.format(stdout);
    try stdout.flush();

    self.data = try data;

    if (self.data.scale > 1) {
        std.debug.print("Scale can't be bigger than 1.\n", .{});
        return error.ConfigValidation;
    }

    for (self.data.backgroundColor) |c| {
        if (c < 0 or c > 1) {
            std.debug.print("Background color must be in [0; 1] range.", .{});
            return error.ConfigValidation;
        }
    }

    return self;
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
        std.debug.print("Failed to serialize default config.\n", .{});
    };
}

fn getConfigBase(self: Self) ![]u8 {
    const allocator = self.allocator;
    const subpath = self.subpath;

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
