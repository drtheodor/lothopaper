const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const zon = std.zon.parse;

const Self = @This();

// TODO: improve errors
pub fn readConfigString(allocator: mem.Allocator, name: []const u8) ![]u8 {
    const path = try getConfigPath(allocator, name);
    defer allocator.free(path);

    return try fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
}

pub fn readConfig(allocator: std.mem.Allocator) Self {
    const path = try getConfigPath(allocator, "config.zon");
    defer allocator.free(path);

    const diag: ?zon.Diagnostics = undefined;
    const res = zon.fromSlice(Self, allocator, path, &diag, .{
        .free_on_error = true,
        .ignore_unknown_fields = false,
    });

    if (diag) |d| {
        d.format(fs.File.stdout());
    }

    return res;
}

pub fn readConfigAndOpenFile(allocator: std.mem.Allocator, name: []const u8) !std.fs.File {
    const path = try getConfigPath(allocator, name);
    defer allocator.free(path);

    return try std.fs.cwd().openFile(path, .{});
}

// Build ~/.config/lothopaper/config/<filename>
pub fn getConfigPath(allocator: mem.Allocator, filename: []const u8) ![]u8 {
    // Get the environment variable "$HOME"
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const parts = [_][]const u8{
        home,
        ".config",
        "lothopaper",
        filename,
    };

    return try fs.path.join(allocator, &parts);
}
