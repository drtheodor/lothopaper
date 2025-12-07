const std = @import("std");

// TODO: improve errors
pub fn readConfigString(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try getConfigPath(allocator, name);
    defer allocator.free(path);

    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

// Build ~/.config/lothopaper/config/<filename>
fn getConfigPath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    // Get the environment variable "$HOME"
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const parts = [_][]const u8{
        home,
        ".config",
        "lothopaper",
        filename,
    };

    return try std.fs.path.join(allocator, &parts);
}
