const std = @import("std");
const mem = std.mem;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

// Application context
const Context = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
};

pub fn main() !void {
    // 1. Connect to Wayland display
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    // 2. Get registry
    const registry = try display.getRegistry();

    // 3. Initialize context for storing globals
    var context = Context{};

    // 4. Set up registry listener with new API
    registry.setListener(*Context, registryListener, &context);

    // 5. Roundtrip to receive globals
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // 6. Check we got required interfaces
    const shm = context.shm orelse return error.NoWlShm;
    const compositor = context.compositor orelse return error.NoWlCompositor;
    const wm_base = context.wm_base orelse return error.NoXdgWmBase;

    // 7. Set up wm_base listener
    wm_base.setListener(*Context, wmBaseListener, &context);

    // 8. Create window surface
    const surface = try compositor.createSurface();
    defer surface.destroy();

    const xdg_surface = try wm_base.getXdgSurface(surface);
    defer xdg_surface.destroy();

    const xdg_toplevel = try xdg_surface.getToplevel();
    defer xdg_toplevel.destroy();

    var running = true;

    // 9. Set up surface and toplevel listeners
    xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, surface);
    xdg_toplevel.setListener(*bool, xdgToplevelListener, &running);

    // 10. Configure window
    xdg_toplevel.setTitle("Zig Wayland Window");
    xdg_toplevel.setAppId("com.example.zig-wayland");

    // 11. Make window visible
    const fd = try std.posix.memfd_create("zig-wayland-buffer", 0);
    defer _ = std.posix.close(fd);

    const color = 0xFF336699;
    const width = 400;
    const height = 300;

    const stride = width * 4; // 4 bytes per pixel (ARGB)
    const size = @as(usize, @intCast(stride * height));

    try std.posix.ftruncate(fd, size);

    const data = try std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        std.posix.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer _ = std.posix.munmap(data);

    // Fill with color (ARGB format)
    const pixels = @as([*]u32, @ptrCast(@alignCast(data.ptr)));
    for (0..@as(usize, @intCast(width * height))) |i| {
        pixels[i] = color;
    }

    const pool = try shm.createPool(fd, size);
    defer pool.destroy();

    const buffer = try pool.createBuffer(0, width, height, stride, wl.Shm.Format.argb8888);
    defer buffer.destroy();

    surface.commit();
    // 12. Roundtrip to ensure configuration
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    surface.attach(buffer, 0, 0);
    surface.commit();

    std.debug.print("Window opened. Close the window to exit.\n", .{});

    // 13. Event loop
    while (running) {
        if (display.dispatch() != .SUCCESS) {
            std.debug.print("Dispatch error\n", .{});
            break;
        }
    }

    std.debug.print("Window closed. Goodbye!\n", .{});
}

// Registry listener - receives available globals
fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            std.debug.print("Found global: {s} (version {})\n", .{ global.interface, global.version });

            // Compare interface names using the generated interface.name field
            if (mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch {
                    std.debug.print("Failed to bind wl_compositor\n", .{});
                    return;
                };
                std.debug.print("✓ Bound to wl_compositor\n", .{});
            } else if (mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch {
                    std.debug.print("Failed to bind xdg_wm_base\n", .{});
                    return;
                };
                std.debug.print("✓ Bound to xdg_wm_base\n", .{});
            } else if (mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch {
                    std.debug.print("Failed to bind wl_shm\n", .{});
                    return;
                };
                std.debug.print("✓ Bound to wl_shm\n", .{});
            }
        },
        .global_remove => |global_remove| {
            std.debug.print("Global removed: {}\n", .{global_remove.name});
        },
    }
}

// XDG WM Base listener - handles ping/pong
fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, context: *Context) void {
    _ = context;
    switch (event) {
        .ping => |ping| {
            wm_base.pong(ping.serial);
            std.debug.print("Handled ping (serial: {})\n", .{ping.serial});
        },
    }
}

// XDG Surface listener - handles surface configuration
fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, surface: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            // Acknowledge the configuration
            xdg_surface.ackConfigure(configure.serial);
            surface.commit();
            std.debug.print("Surface configured (serial: {})\n", .{configure.serial});
        },
    }
}

// XDG Toplevel listener - handles window events
fn xdgToplevelListener(xdg_toplevel: *xdg.Toplevel, event: xdg.Toplevel.Event, running: *bool) void {
    switch (event) {
        .configure => |configure| {
            std.debug.print("Toplevel configured - width: {}, height: {}\n", .{ configure.width, configure.height });
            // Here you would resize your drawing buffer if needed
            _ = xdg_toplevel;
        },
        .close => {
            std.debug.print("Close event received\n", .{});
            running.* = false;
        },
    }
}
