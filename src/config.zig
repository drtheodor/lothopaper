const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const zon = std.zon.parse;

const Self = @This();

fps: usize = 60,
maxOutputs: usize = 8,

// TODO: improve errors
pub fn readConfigString(allocator: mem.Allocator, name: []const u8, def: []const u8) ![]u8 {
    const path = try getConfigPath(allocator, name);
    defer allocator.free(path);

    return try readOrCreateFile(allocator, path, def, struct {
        fn default(writer: *std.Io.Writer, def2: []const u8) error{WriteFailed}!void {
            _ = try writer.write(def2);
        }
    }.default);
}

fn readOrCreateFile(allocator: mem.Allocator, path: []const u8, ctx: anytype, def: fn (*std.Io.Writer, @TypeOf(ctx)) error{WriteFailed}!void) ![]u8 {
    var file = std.fs.cwd().createFile(path, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // File already exists, open it instead.
            std.debug.print("File '{s}' already exists. Opening it.\n", .{path});
            return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        },
        else => return err, // Handle other potential errors
    };
    defer file.close();

    var buffer: [1024]u8 = undefined;
    var fileWriter = file.writer(&buffer);
    var writer = &fileWriter.interface;

    try def(writer, ctx);

    try writer.flush();

    return &buffer;
}

pub fn readConfig(allocator: std.mem.Allocator) !Self {
    try ensureConfigPath(allocator);

    const path = try getConfigPath(allocator, "config.zon");
    defer allocator.free(path);

    const src = try readOrCreateFile(allocator, path, {}, writeDefaultConfig);
    const terminated = try allocator.dupeZ(u8, src);
    defer allocator.free(terminated);

    var diag: zon.Diagnostics = .{};
    const res = zon.fromSlice(Self, allocator, terminated, &diag, .{
        .free_on_error = true,
        .ignore_unknown_fields = false,
    });

    const stdoutFile = std.fs.File.stdout();
    var buffer: [1024]u8 = undefined; // Define a buffer for the writer
    var stdout_writer = stdoutFile.writer(&buffer);
    var stdout = &stdout_writer.interface;

    try diag.format(stdout);
    try stdout.flush();

    return res;
}

fn ensureConfigPath(allocator: mem.Allocator) !void {
    const base = try getConfigBase(allocator);
    defer allocator.free(base);

    fs.cwd().makeDir(base) catch {};
}

fn writeDefaultConfig(writer: *std.Io.Writer, _: void) error{WriteFailed}!void {
    const val: Self = .{};

    std.zon.stringify.serialize(val, .{}, writer) catch {
        std.debug.print("Failed to serialize default config.\n", .{});
    };
}

fn getConfigBase(allocator: mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const parts = [_][]const u8{
        home,
        ".config",
        "lothopaper",
    };

    return try fs.path.join(allocator, &parts);
}

// Build ~/.config/lothopaper/config/<filename>
fn getConfigPath(allocator: mem.Allocator, filename: []const u8) ![]u8 {
    // Get the environment variable "$HOME"
    const base = try getConfigBase(allocator);
    defer allocator.free(base);

    const parts = [_][]const u8{
        base,
        filename,
    };

    return try fs.path.join(allocator, &parts);
}
