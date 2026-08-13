//! Minimal zgpui application template.
//!
//! Run: `zig build run-07_app_template`
//! Copy this file as a starting point for new apps, then replace the Demo
//! state / render body with your UI.

const std = @import("std");
const zgpui = @import("zgpui");

const Rgba = zgpui.Rgba;
const Style = zgpui.style.Style;
const button = zgpui.components.button;

const Counter = struct { count: i32 = 0 };

const AppState = struct {
    app: *zgpui.App,
    window: *zgpui.Window = undefined,
    counter: zgpui.Entity(Counter) = undefined,
    text_resources: zgpui.TextResources = undefined,

    fn label(self: *AppState, arena: std.mem.Allocator, content: []const u8, size: f32, text_color: Rgba) zgpui.Element {
        return zgpui.textEl(arena, &self.text_resources, content).size(size).withColor(text_color).any();
    }

    fn buttonStyle(state: button.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 140 };
        s.height = .{ .px = 40 };
        s.corner_radii = zgpui.Corners(f32).all(8);
        s.background = if (state.pressed)
            Rgba.fromHex(0x1d4ed8)
        else if (state.hovered)
            Rgba.fromHex(0x3b82f6)
        else
            Rgba.fromHex(0x2563eb);
        // Keyboard focus ring only (:focus-visible).
        if (state.focus_visible) {
            s.border_widths = zgpui.Edges(f32).all(2);
            s.border_color = Rgba.fromHex(0xfbbf24);
        }
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn onIncrement(ctx: ?*anyopaque) void {
        const self: *AppState = @ptrCast(@alignCast(ctx.?));
        self.app.read(Counter, self.counter).count += 1;
        self.app.notify(self.counter.id);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, win: *zgpui.Window) anyerror!zgpui.Element {
        const self: *AppState = @ptrCast(@alignCast(ctx.?));
        const count = self.app.read(Counter, self.counter).count;
        const count_text = try std.fmt.allocPrint(arena, "count = {d}", .{count});

        const row = zgpui.div(arena)
            .flexRow()
            .gapPx(16)
            .itemsCenter()
            .childDiv(button.button(arena, &win.input, .{
                .id = "increment",
                .label = "Increment",
                .on_press = .{ .ctx = self, .func = onIncrement },
                .style_fn = buttonStyle,
            }).child(self.label(arena, "Increment", 15, Rgba.white)))
            .child(self.label(arena, count_text, 15, Rgba.fromHex(0xe2e8f0)));

        return zgpui.div(arena)
            .flexCol()
            .wFull()
            .hFull()
            .padPx(32)
            .gapPx(16)
            .bg(Rgba.fromHex(0x0f172a))
            .child(self.label(arena, "zgpui app template", 22, Rgba.white))
            .child(self.label(arena, "Cmd/Ctrl+N increments · Tab for focus ring · F3 toggles HUD", 13, Rgba.fromHex(0x94a3b8)))
            .childDiv(row)
            .any();
    }

    fn bindHotkeys(self: *AppState) !void {
        const inc = zgpui.actionId("template.increment");
        const toggle_hud = zgpui.actionId("template.toggle_hud");

        try self.window.hotkeys.keymap.bind(.{ .key = .n, .modifiers = .{ .command = true } }, inc);
        try self.window.hotkeys.keymap.bind(.{ .key = .n, .modifiers = .{ .control = true } }, inc);
        try self.window.hotkeys.keymap.bind(.{ .key = .f3 }, toggle_hud);

        self.window.hotkeys.on(inc, self, onIncrement);
        self.window.hotkeys.on(toggle_hud, self, struct {
            fn toggle(ctx: ?*anyopaque) void {
                const state: *AppState = @ptrCast(@alignCast(ctx.?));
                state.window.debug_hud = !state.window.debug_hud;
                if (state.window.debug_hud) state.window.enableProfiler(true);
                state.window.markDirty();
            }
        }.toggle);
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = zgpui.App.init(gpa);
    defer app.deinit();

    const glfw_platform = try zgpui.glfw_platform.GlfwPlatform.init(gpa);
    const platform = glfw_platform.platform();
    defer platform.deinit();

    const gpu_ctx = try zgpui.renderer.GpuContext.init(gpa);
    defer gpu_ctx.deinit();

    const win = try zgpui.Window.init(gpa, &app, platform, gpu_ctx, .{
        .title = "zgpui template",
        .size = .{ .width = 640, .height = 400 },
    });
    defer win.deinit();
    win.partial_present = true;

    // Optional diagnostics (also toggled with F3 at runtime):
    // win.debug_hud = true;
    // win.enableProfiler(true);

    var state = AppState{ .app = &app };
    state.window = win;
    state.counter = try app.new(Counter, .{});
    try state.bindHotkeys();

    var font_system = try zgpui.text.FontSystem.init(gpa);
    defer font_system.deinit();
    const font = try font_system.loadFont(zgpui.text.defaultFontPath(), 0);
    var atlas = try zgpui.text.GlyphAtlas.init(gpa, zgpui.Size(i32).init(1024, 1024));
    defer atlas.deinit();
    state.text_resources = .{
        .font_system = &font_system,
        .atlas = &atlas,
        .default_font = font,
    };
    win.setTextResources(&state.text_resources);

    win.setRoot(&state, AppState.render);
    try win.renderFrame();

    while (!win.shouldClose()) {
        platform.waitEvents();
        app.flushEffects();
        try win.renderIfNeeded();
    }
}
