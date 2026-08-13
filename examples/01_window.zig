//! Phase 1 smoke test: opens a window and clears it with an animated color.
//!
//! Run with `zig build run-01_window`. Press Escape or close the window to
//! exit. Input events are logged.

const std = @import("std");
const zgpui = @import("zgpui");

pub const std_options: std.Options = .{ .log_level = .info };

const AppState = struct {
    should_exit: bool = false,
};

fn onWindowEvent(ctx: ?*anyopaque, event: zgpui.platform.WindowEvent) void {
    const state: *AppState = @ptrCast(@alignCast(ctx.?));
    switch (event) {
        .input => |input| switch (input) {
            // Mouse motion is too chatty for info level.
            .mouse_moved => |e| std.log.debug("mouse moved to ({d:.1}, {d:.1})", .{ e.position.x, e.position.y }),
            .mouse_down => |e| std.log.info("mouse down: {s} at ({d:.1}, {d:.1})", .{ @tagName(e.button), e.position.x, e.position.y }),
            .mouse_up => |e| std.log.info("mouse up: {s} at ({d:.1}, {d:.1})", .{ @tagName(e.button), e.position.x, e.position.y }),
            .mouse_exited => std.log.info("mouse exited window", .{}),
            .scroll => |e| std.log.info("scroll delta ({d:.2}, {d:.2})", .{ e.delta.x, e.delta.y }),
            .key_down => |e| {
                std.log.info("key down: {s}{s}", .{ @tagName(e.key), if (e.is_repeat) " (repeat)" else "" });
                if (e.key == .escape) state.should_exit = true;
            },
            .key_up => |e| std.log.info("key up: {s}", .{@tagName(e.key)}),
            .modifiers_changed => |m| std.log.info(
                "modifiers: shift={} control={} alt={} command={}",
                .{ m.shift, m.control, m.alt, m.command },
            ),
            .text_input => |e| std.log.info("text input: \"{s}\"", .{e.text}),
            .composition_start => std.log.debug("composition start", .{}),
            .composition_update => |e| std.log.debug("composition update: \"{s}\" cursor={d}", .{ e.text, e.cursor }),
            .composition_end => std.log.debug("composition end", .{}),
        },
        .resized => |size| std.log.info("resized to {d:.0}x{d:.0}", .{ size.width, size.height }),
        .framebuffer_resized => |size| std.log.info("framebuffer resized to {d}x{d}", .{ size.width, size.height }),
        .scale_factor_changed => |scale| std.log.info("scale factor changed to {d}", .{scale}),
        .focus_changed => |focused| std.log.info("focus: {}", .{focused}),
        .close_requested => {
            std.log.info("close requested", .{});
            state.should_exit = true;
        },
        .a11y_press => {},
        .a11y_adjust => {},
        .a11y_set_value => {},
        .a11y_replace_selected_text => {},
        .a11y_set_selected_range => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const glfw_platform = try zgpui.glfw_platform.GlfwPlatform.init(gpa);
    const plat = glfw_platform.platform();
    defer plat.deinit();

    const window = try plat.openWindow(.{
        .title = "zgpui",
        .size = .{ .width = 800, .height = 600 },
    });
    defer window.deinit();

    var state = AppState{};
    window.setEventHandler(.{ .ctx = &state, .func = onWindowEvent });

    std.log.info("window opened: logical {d:.0}x{d:.0}, framebuffer {d}x{d}, scale {d}", .{
        window.logicalSize().width,
        window.logicalSize().height,
        window.framebufferSize().width,
        window.framebufferSize().height,
        window.scaleFactor(),
    });

    const ctx = try zgpui.renderer.GpuContext.init(gpa);
    defer ctx.deinit();
    std.log.info("gpu device created", .{});

    var surface = try zgpui.renderer.WindowSurface.init(
        ctx,
        window.nativeSurface(),
        window.framebufferSize(),
    );
    defer surface.deinit();

    const io = init.io;
    const start_time = std.Io.Clock.now(.awake, io);
    var frame_count: u64 = 0;

    while (!window.shouldClose() and !state.should_exit) {
        plat.pollEvents();

        // Reconfigure the surface whenever the framebuffer size changes
        // (resize, or a move between monitors with different scale factors).
        surface.resize(window.framebufferSize());

        // Animate the clear color so success is visually obvious.
        const elapsed = start_time.durationTo(std.Io.Clock.now(.awake, io));
        const t: f32 = @as(f32, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_s;
        const clear_color = zgpui.Rgba.init(
            0.5 + 0.5 * @sin(t),
            0.5 + 0.5 * @sin(t + 2.0 * std.math.pi / 3.0),
            0.5 + 0.5 * @sin(t + 4.0 * std.math.pi / 3.0),
            1.0,
        );

        var frame = surface.beginFrame() catch |err| switch (err) {
            error.SurfaceUnavailable => continue,
            else => return err,
        };
        ctx.encodeClearPass(&frame, clear_color);
        surface.endFrame(&frame);

        frame_count += 1;
        if (frame_count % 60 == 0) {
            std.log.info("rendered {d} frames ({d:.1}s)", .{ frame_count, t });
        }
    }

    std.log.info("exiting after {d} frames", .{frame_count});
}
