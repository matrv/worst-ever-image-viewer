const std = @import("std");

const wayland = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-unstable-v1-client-protocol.h");
});

const webp = @cImport({
    @cInclude("decode.h");
});

const allocator = std.heap.c_allocator;

const Globals = struct { compositor: ?*wayland.wl_compositor = null, xdg_wm_base: ?*wayland.xdg_wm_base = null, shared_memory: ?*wayland.wl_shm = null, decoration_manager: ?*wayland.zxdg_decoration_manager_v1 = null };

fn global(data: ?*anyopaque, registry: ?*wayland.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const interface_zigged = std.mem.span(interface);
    const globals: *Globals = @ptrCast(@alignCast(data));
    if (std.mem.eql(u8, interface_zigged, "wl_compositor")) {
        globals.compositor = @ptrCast(wayland.wl_registry_bind(registry, name, &wayland.wl_compositor_interface, version));
    } else if (std.mem.eql(u8, interface_zigged, "xdg_wm_base")) {
        globals.xdg_wm_base = @ptrCast(wayland.wl_registry_bind(registry, name, &wayland.xdg_wm_base_interface, version));
    } else if (std.mem.eql(u8, interface_zigged, "wl_shm")) {
        globals.shared_memory = @ptrCast(wayland.wl_registry_bind(registry, name, &wayland.wl_shm_interface, version));
    } else if (std.mem.eql(u8, interface_zigged, "zxdg_decoration_manager_v1")) {
        globals.decoration_manager = @ptrCast(wayland.wl_registry_bind(registry, name, &wayland.zxdg_decoration_manager_v1_interface, version));
    }
}

fn global_remove(data: ?*anyopaque, registry: ?*wayland.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
    std.debug.print("Global remove\n", .{});
}

fn xdg_wm_base_ping(data: ?*anyopaque, xdg_wm_base: ?*wayland.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    wayland.xdg_wm_base_pong(xdg_wm_base, serial);
}

const XdgSurfaceConfigureContext = struct {
    surface: *wayland.wl_surface,
    shared_memory: *wayland.wl_shm,
    is_configured: bool = false,
    width: i32,
    height: i32,
    webp_buffer: [*c]u8,
    webp_buffer_len: usize,
};

fn xdg_surface_configure(data: ?*anyopaque, xdg_surface: ?*wayland.xdg_surface, serial: u32) callconv(.c) void {
    const ctx: *XdgSurfaceConfigureContext = @ptrCast(@alignCast(data));
    wayland.xdg_surface_ack_configure(xdg_surface, serial);

    if (!ctx.is_configured) {
        ctx.is_configured = true;

        const stride = ctx.width * 4;
        const size: usize = @intCast(stride * ctx.height);

        const fd = std.posix.memfd_create("wayland-shm", 0) catch |err| {
            std.debug.print("Failed to create memfd: {}\n", .{err});
            return;
        };

        _ = std.posix.ftruncate(fd, size) catch |err| {
            std.debug.print("Failed to truncate memfd: {}\n", .{err});
            return;
        };

        const pixel_data = std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0) catch |err| {
            std.debug.print("Failed to mmap: {}\n", .{err});
            return;
        };

        _ = webp.WebPDecodeBGRAInto(ctx.webp_buffer, ctx.webp_buffer_len, @ptrCast(pixel_data.ptr), size, stride);

        const pool = wayland.wl_shm_create_pool(ctx.shared_memory, fd, @intCast(size));
        const buffer = wayland.wl_shm_pool_create_buffer(pool, 0, ctx.width, ctx.height, stride, wayland.WL_SHM_FORMAT_ARGB8888);
        wayland.wl_shm_pool_destroy(pool);

        wayland.wl_surface_attach(ctx.surface, buffer, 0, 0);
        wayland.wl_surface_commit(ctx.surface);
    }
}

const XdgToplevelContext = struct {
    running: bool = true,
};

fn xdg_toplevel_close(data: ?*anyopaque, xdg_toplevel: ?*wayland.xdg_toplevel) callconv(.c) void {
    _ = xdg_toplevel;
    const ctx: *XdgToplevelContext = @ptrCast(@alignCast(data));
    ctx.running = false;
}

fn xdg_toplevel_configure(data: ?*anyopaque, xdg_toplevel: ?*wayland.xdg_toplevel, width: i32, height: i32, state: ?*wayland.wl_array) callconv(.c) void {
    _ = data;
    _ = xdg_toplevel;
    _ = width;
    _ = height;
    _ = state;
}

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: weiv <image-path>\n", .{});
        return;
    }
    const image_path = args[1];
    const file = std.fs.cwd().openFile(image_path, .{}) catch |e| {
        switch (e) {
            error.FileNotFound => std.debug.print("File not found: {s}\n", .{image_path}),
            else => std.debug.print("Failed to open file\n", .{}),
        }
        std.process.exit(1);
        return;
    };
    defer file.close();
    const file_size = try file.getEndPos();
    var internal_buffer: [4096]u8 = undefined;
    var reader = file.reader(&internal_buffer);
    const buffer = try reader.interface.readAlloc(allocator, file_size);
    defer allocator.free(buffer);
    var height: i32 = undefined;
    var width: i32 = undefined;
    const res = webp.WebPGetInfo(@ptrCast(buffer.ptr), buffer.len, &width, &height);
    if (res == 0) {
        std.debug.print("Failed to decode image\n", .{});
        std.process.exit(1);
        return;
    }

    var globals = Globals{};

    const display = wayland.wl_display_connect(null);
    if (display == null) @panic("Failed to connect to Wayland display");
    defer wayland.wl_display_disconnect(display);

    const registry = wayland.wl_display_get_registry(display);
    if (registry == null) @panic("Failed to get Wayland registry");
    defer wayland.wl_registry_destroy(registry);

    const wl_registry_listener = wayland.wl_registry_listener{
        .global = global,
        .global_remove = global_remove,
    };

    _ = wayland.wl_registry_add_listener(registry, &wl_registry_listener, @ptrCast(&globals));
    _ = wayland.wl_display_roundtrip(display);

    if (globals.compositor == null) @panic("Failed to bind compositor");
    if (globals.xdg_wm_base == null) @panic("Failed to bind xdg_wm_base");
    if (globals.shared_memory == null) @panic("Failed to bind wl_shm");
    if (globals.decoration_manager == null) @panic("Failed to bind zxdg_decoration_manager_v1");
    defer wayland.wl_compositor_destroy(globals.compositor);
    defer wayland.xdg_wm_base_destroy(globals.xdg_wm_base);
    defer wayland.wl_shm_destroy(globals.shared_memory);
    defer wayland.zxdg_decoration_manager_v1_destroy(globals.decoration_manager);

    const surface = wayland.wl_compositor_create_surface(globals.compositor);
    if (surface == null) @panic("Failed to create Wayland surface");
    defer wayland.wl_surface_destroy(surface);

    const xdg_wm_base_listener = wayland.xdg_wm_base_listener{ .ping = xdg_wm_base_ping };
    _ = wayland.xdg_wm_base_add_listener(globals.xdg_wm_base, &xdg_wm_base_listener, null);

    const xdg_surface = wayland.xdg_wm_base_get_xdg_surface(globals.xdg_wm_base, surface);
    if (xdg_surface == null) @panic("Failed to create xdg_surface");
    defer wayland.xdg_surface_destroy(xdg_surface);

    const xdg_surface_listener = wayland.xdg_surface_listener{ .configure = xdg_surface_configure };

    const xdg_toplevel = wayland.xdg_surface_get_toplevel(xdg_surface);
    if (xdg_toplevel == null) @panic("Failed to create xdg_toplevel");
    defer wayland.xdg_toplevel_destroy(xdg_toplevel);

    const basename = std.fs.path.basename(image_path);
    const title = try std.fmt.allocPrint(allocator, "WEIV - {s}\x00", .{basename});
    defer allocator.free(title);
    wayland.xdg_toplevel_set_title(xdg_toplevel, @ptrCast(title));
    wayland.xdg_toplevel_set_min_size(xdg_toplevel, width, height);
    wayland.xdg_toplevel_set_max_size(xdg_toplevel, width, height);
    const decoration = wayland.zxdg_decoration_manager_v1_get_toplevel_decoration(
        globals.decoration_manager.?,
        xdg_toplevel,
    );
    defer wayland.zxdg_toplevel_decoration_v1_destroy(decoration);
    wayland.zxdg_toplevel_decoration_v1_set_mode(
        decoration,
        wayland.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
    );

    var ctx = XdgSurfaceConfigureContext{
        .surface = surface.?,
        .shared_memory = globals.shared_memory.?,
        .width = width,
        .height = height,
        .webp_buffer = @ptrCast(buffer.ptr),
        .webp_buffer_len = buffer.len,
    };

    _ = wayland.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, &ctx);

    wayland.wl_surface_commit(surface);
    _ = wayland.wl_display_roundtrip(display);

    var toplevel_ctx = XdgToplevelContext{};
    const xdg_toplevel_listener = wayland.xdg_toplevel_listener{
        .configure = xdg_toplevel_configure,
        .close = xdg_toplevel_close,
    };
    _ = wayland.xdg_toplevel_add_listener(xdg_toplevel, &xdg_toplevel_listener, &toplevel_ctx);

    while (wayland.wl_display_dispatch(display) != -1 and toplevel_ctx.running) {}
}
