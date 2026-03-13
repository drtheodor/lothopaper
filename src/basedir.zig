//! The XDG Base Directory Specification utility code.

const std = @import("std");

pub const BaseDir = enum {
    data,
    config,
    state,
    cache,

    /// Returns the environment variable name of the base directory.
    pub fn name(self: BaseDir) []const u8 {
        return switch (self) {
            .data => "XDG_DATA_HOME",
            .config => "XDG_CONFIG_HOME",
            .state => "XDG_STATE_HOME",
            .cache => "XDG_CACHE_HOME",
        };
    }

    /// Returns default value for the base directory (relative to `$HOME`)
    pub fn default(self: BaseDir) []const u8 {
        return switch (self) {
            .data => ".local/share",
            .config => ".config",
            .state => ".local/state",
            .cache => ".cache",
        };
    }

    /// Returns the configured base directory or a default if not present.
    /// Caller owns the memory.
    pub fn get(self: BaseDir, allocator: std.mem.Allocator) [:0]const u8 {
        if (std.posix.getenv(self.name())) |path| {
            return try allocator.dupeZ(u8, path);
        }
        return try std.fs.path.joinZ(allocator, &.{
            std.posix.getenv("HOME") orelse unreachable,
            self.default(),
        });
    }

    pub fn dirs(self: BaseDir) ?[:0]const u8 {
        return std.posix.getenv(switch (self) {
            .data => "XDG_DATA_DIRS",
            .config => "XDG_CONFIG_DIRS",
            else => return null,
        });
    }

    pub fn relative(self: BaseDir, allocator: std.mem.Allocator, sub_path: [:0]const u8) [:0]const u8 {
        const dest_path = self.get(allocator);
        errdefer allocator.free(dest_path);
        return try std.fs.path.joinZ(allocator, &.{
            dest_path,
            sub_path,
        });
    }
};

pub fn getRuntimeDir(allocator: std.mem.Allocator) [:0]const u8 {
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |rtd| {
        return try allocator.dupeZ(u8, rtd);
    }
    return try std.fmt.allocPrint(allocator, "/run/user/{d}", .{std.posix.geteuid()});
}
