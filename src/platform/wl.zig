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

const Self = @This();

display: *wl.Display = undefined,
compositor: *wl.Compositor = undefined,
wm: *xdg.WmBase = undefined,
layer: *zwlr.LayerShellV1 = undefined,

outputCount: usize = 0,
outputs: []*Output,

const ContextBuilder = struct {
    compositor: ?*wl.Compositor = null,
    wm: ?*xdg.WmBase = null,
    layer: ?*zwlr.LayerShellV1 = null,
    outputCount: usize = 0,
    outputs: []*Output,
};

pub fn deinit(self: Self, allocator: mem.Allocator) void {
    allocator.free(self.outputs);
    self.display.disconnect();
}

pub const RoundtripError = error{RoundtripFailed};
pub const InitError = error{
    NoWlCompositor,
    NoXdgWmBase,
    NoZwlrLayer,
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

inline fn fromBuilder(display: *wl.Display, ctx: ContextBuilder) InitError!Self {
    if (ctx.outputCount == 0) {
        std.debug.print("No wl_output found; nothing to show.\n", .{});
        return error.NoOutputs;
    }

    return .{
        .display = display,
        .compositor = ctx.compositor orelse return error.NoWlCompositor,
        .wm = ctx.wm orelse return error.NoXdgWmBase,
        .layer = ctx.layer orelse return error.NoZwlrLayer,
        .outputCount = ctx.outputCount,
        .outputs = ctx.outputs,
    };
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, ctx: *ContextBuilder) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);

            if (mem.eql(u8, iface, std.mem.span(wl.Compositor.interface.name))) {
                ctx.compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(xdg.WmBase.interface.name))) {
                ctx.wm = registry.bind(g.name, xdg.WmBase, 1) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                ctx.layer = registry.bind(g.name, zwlr.LayerShellV1, 4) catch return;
            } else if (mem.eql(u8, iface, std.mem.span(wl.Output.interface.name))) {
                if (ctx.outputCount < ctx.outputs.len) {
                    const out = registry.bind(g.name, wl.Output, 3) catch return;

                    ctx.outputs[ctx.outputCount] = out;
                    ctx.outputCount += 1;
                }
            }
        },
        else => {},
    }
}

fn wmBaseListener(wmBase: *xdg.WmBase, event: xdg.WmBase.Event, context: *Self) void {
    _ = context;

    switch (event) {
        .ping => |p| wmBase.pong(p.serial),
    }
}
