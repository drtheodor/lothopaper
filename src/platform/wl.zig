const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

pub const Surface = wl.Surface;
pub const LayerShell = zwlr.LayerShellV1;
pub const LayerSurface = zwlr.LayerSurfaceV1;
pub const Output = wl.Output;
pub const Pointer = wl.Pointer;

const Self = @This();

display: *wl.Display,
compositor: *wl.Compositor,
layer: *zwlr.LayerShellV1,
seat: *wl.Seat,
pointer: ?*Pointer,

outputCount: usize = 0,
outputs: []*Output,

const ContextBuilder = struct {
    compositor: ?*wl.Compositor = null,
    layer: ?*zwlr.LayerShellV1 = null,
    seat: ?*wl.Seat = null,
    outputCount: usize = 0,
    outputs: []*Output,
};

pub fn deinit(self: Self, allocator: mem.Allocator) void {
    for (0..self.outputCount) |outputIdx| {
        self.outputs[outputIdx].destroy();
    }

    allocator.free(self.outputs);

    if (self.pointer) |pointer| {
        pointer.release();
    }
    self.seat.destroy();
    self.compositor.destroy();
    self.layer.destroy();
    self.display.disconnect();
}

pub const RoundtripError = error{RoundtripFailed};
pub const InitError = error{
    NoWlCompositor,
    NoXdgWmBase,
    NoZwlrLayer,
    NoSeat,
    NoOutputs,
    ConnectFailed,
    OutOfMemory,
} || RoundtripError;

pub fn init(allocator: mem.Allocator, maxOutputs: usize) InitError!Self {
    const display = try wl.Display.connect(null);

    const registry = try display.getRegistry();

    var context: ContextBuilder = .{
        .outputs = try allocator.alloc(*Output, maxOutputs),
    };

    registry.setListener(*ContextBuilder, registryListener, &context);

    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    return fromBuilder(display, context);
}

pub fn postInit(self: *Self) void {
    self.seat.setListener(*Self, seatListener, self);
}

inline fn fromBuilder(display: *wl.Display, ctx: ContextBuilder) InitError!Self {
    if (ctx.outputCount == 0) {
        std.debug.print("No outputs found.\n", .{});
        return error.NoOutputs;
    }

    return .{
        .display = display,
        .compositor = ctx.compositor orelse return error.NoWlCompositor,
        .layer = ctx.layer orelse return error.NoZwlrLayer,
        .seat = ctx.seat orelse return error.NoSeat,
        .pointer = null,
        .outputCount = ctx.outputCount,
        .outputs = ctx.outputs,
    };
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, ctx: *ContextBuilder) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);

            if (mem.eql(u8, iface, std.mem.span(wl.Compositor.interface.name))) {
                ctx.compositor = registry.bind(g.name, wl.Compositor, 4) catch |err| {
                    std.debug.print("Failed to get compositor: {}\n", .{err});
                    return;
                };
            } else if (mem.eql(u8, iface, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                ctx.layer = registry.bind(g.name, zwlr.LayerShellV1, 4) catch |err| {
                    std.debug.print("Failed to get layer shell: {}\n", .{err});
                    return;
                };
            } else if (mem.eql(u8, iface, std.mem.span(wl.Output.interface.name))) {
                if (ctx.outputCount < ctx.outputs.len) {
                    const out = registry.bind(g.name, wl.Output, 3) catch |err| {
                        std.debug.print("Failed to get output: {}\n", .{err});
                        return;
                    };

                    ctx.outputs[ctx.outputCount] = out;
                    ctx.outputCount += 1;
                } else {
                    ctx.outputCount += 1;
                    std.debug.print("Too many outputs: {}!\n", .{ctx.outputCount});
                }
            } else if (mem.eql(u8, iface, std.mem.span(wl.Seat.interface.name))) {
                const seat = registry.bind(g.name, wl.Seat, 3) catch |err| {
                    std.debug.print("Failed to get seat: {}.\n", .{err});
                    return;
                };

                ctx.seat = seat;
            }
        },
        else => {},
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, ctx: *Self) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.pointer) {
                const ptr = seat.getPointer() catch |err| {
                    std.debug.print("Failed to get pointer: {}.\n", .{err});
                    return;
                };

                ctx.pointer = ptr;
                std.debug.print("Pointer: {any} for {*}; thread: {}.\n", .{ ctx.pointer, ctx, std.Thread.getCurrentId() });
            }
        },
        else => {},
    }
}
