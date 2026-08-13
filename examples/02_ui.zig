//! End-to-end demo: a real window running the full zgpui stack — text,
//! headless components (button/checkbox/tabs) with hover/press/focus
//! styling, entity state and automatic re-render on notify.
//!
//! Run with: zig build run-02_ui

const std = @import("std");
const zgpui = @import("zgpui");

const Rgba = zgpui.Rgba;
const Style = zgpui.style.Style;
const button = zgpui.components.button;
const checkbox = zgpui.components.checkbox;
const tabs = zgpui.components.tabs;

const Counter = struct { count: i32 = 0 };

const Demo = struct {
    app: *zgpui.App,
    window: *zgpui.Window = undefined,
    counter: zgpui.Entity(Counter) = undefined,
    checkbox_state: zgpui.Entity(checkbox.CheckboxState) = undefined,
    tabs_state: zgpui.Entity(tabs.TabsState) = undefined,
    text_resources: zgpui.TextResources = undefined,

    fn onPress(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        self.app.read(Counter, self.counter).count += 1;
        self.app.notify(self.counter.id);
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
        if (state.focused) {
            s.border_widths = zgpui.Edges(f32).all(2);
            s.border_color = Rgba.fromHex(0x93c5fd);
        }
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn checkboxStyle(state: checkbox.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 22 };
        s.height = .{ .px = 22 };
        s.corner_radii = zgpui.Corners(f32).all(4);
        s.background = if (state.checked) Rgba.fromHex(0x22c55e) else Rgba.fromHex(0x334155);
        if (state.hovered or state.focused) {
            s.border_widths = zgpui.Edges(f32).all(2);
            s.border_color = Rgba.fromHex(0x94a3b8);
        }
        return s;
    }

    fn tabStyle(state: tabs.TabStyleState) Style {
        var s = Style{};
        s.width = .{ .px = 90 };
        s.height = .{ .px = 32 };
        s.corner_radii = .{ .top_left = 6, .top_right = 6, .bottom_right = 0, .bottom_left = 0 };
        s.background = if (state.selected)
            Rgba.fromHex(0x475569)
        else if (state.hovered)
            Rgba.fromHex(0x33415a)
        else
            Rgba.fromHex(0x1e293b);
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn label(self: *Demo, arena: std.mem.Allocator, content: []const u8, size: f32, text_color: Rgba) zgpui.Element {
        return zgpui.textEl(arena, &self.text_resources, content).size(size).withColor(text_color).any();
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *zgpui.Window) anyerror!zgpui.Element {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const app = self.app;
        const input = &self.window.input;

        const count = app.read(Counter, self.counter).count;
        const count_text = try std.fmt.allocPrint(arena, "count = {d}", .{count});
        const checked = checkbox.isChecked(app, .{ .uncontrolled = self.checkbox_state });

        // Counter row: button + live label.
        const counter_row = zgpui.div(arena)
            .flexRow()
            .gapPx(16)
            .itemsCenter()
            .childDiv(button.button(arena, input, .{
                .id = "increment",
                .on_press = .{ .ctx = self, .func = onPress },
                .style_fn = buttonStyle,
            }).child(self.label(arena, "Click me", 15, Rgba.white)))
            .child(self.label(arena, count_text, 15, Rgba.fromHex(0xe2e8f0)));

        // Checkbox row toggling a colored box.
        var checkbox_row = zgpui.div(arena)
            .flexRow()
            .gapPx(12)
            .itemsCenter()
            .childDiv(checkbox.checkbox(arena, app, input, .{
                .id = "show-box",
                .value = .{ .uncontrolled = self.checkbox_state },
                .style_fn = checkboxStyle,
            }))
            .child(self.label(arena, "show the orange box", 14, Rgba.fromHex(0xcbd5e1)));
        if (checked) {
            checkbox_row = checkbox_row.childDiv(
                zgpui.div(arena).sizePx(40, 24).rounded(6).bg(Rgba.fromHex(0xf97316)),
            );
        }

        // Tabs.
        const tab_names = [_][]const u8{ "First", "Second", "Third" };
        const tab_ids = [_][]const u8{ "tab-0", "tab-1", "tab-2" };
        var tab_list = tabs.list(arena, app, .{
            .id = "demo-tabs",
            .value = .{ .uncontrolled = self.tabs_state },
            .tab_count = tab_names.len,
        }).gapPx(4);
        for (tab_names, tab_ids, 0..) |name, id, i| {
            tab_list = tab_list.childDiv(tabs.tab(arena, app, input, .{
                .id = id,
                .value = .{ .uncontrolled = self.tabs_state },
                .index = i,
                .list_id = "demo-tabs",
                .style_fn = tabStyle,
            }).child(self.label(arena, name, 13, Rgba.white)));
        }
        const panel_colors = [_]Rgba{
            Rgba.fromHex(0x7c3aed),
            Rgba.fromHex(0x0891b2),
            Rgba.fromHex(0xbe185d),
        };
        const selected = tabs.selectedIndex(app, .{ .uncontrolled = self.tabs_state });
        const panel = zgpui.div(arena)
            .wFull()
            .hPx(120)
            .rounded(8)
            .padPx(16)
            .bg(panel_colors[selected])
            .child(self.label(arena, tab_names[selected], 18, Rgba.white));

        return zgpui.div(arena)
            .flexCol()
            .wFull()
            .hFull()
            .padPx(32)
            .gapPx(24)
            .bg(Rgba.fromHex(0x0f172a))
            .child(self.label(arena, "zgpui demo — try mouse, Tab, Enter/Space, arrows", 20, Rgba.white))
            .childDiv(counter_row)
            .childDiv(checkbox_row)
            .childDiv(zgpui.div(arena).flexCol().childDiv(tab_list).childDiv(panel))
            .any();
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
        .title = "zgpui demo",
        .size = .{ .width = 720, .height = 480 },
    });
    defer win.deinit();
    win.partial_present = true;

    var demo = Demo{ .app = &app };
    demo.window = win;
    demo.counter = try app.new(Counter, .{});
    demo.checkbox_state = try app.new(checkbox.CheckboxState, .{});
    demo.tabs_state = try app.new(tabs.TabsState, .{});

    // Text resources: FreeType + HarfBuzz + glyph atlas.
    var font_system = try zgpui.text.FontSystem.init(gpa);
    defer font_system.deinit();
    const font = try font_system.loadFont(zgpui.text.defaultFontPath(), 0);
    var atlas = try zgpui.text.GlyphAtlas.init(gpa, zgpui.Size(i32).init(1024, 1024));
    defer atlas.deinit();
    demo.text_resources = .{
        .font_system = &font_system,
        .atlas = &atlas,
        .default_font = font,
    };
    win.setTextResources(&demo.text_resources);

    win.setRoot(&demo, Demo.render);
    try win.renderFrame();

    var frames: u64 = 0;
    while (!win.shouldClose()) {
        platform.waitEvents();
        app.flushEffects();
        try win.renderIfNeeded();
        frames += 1;
        if (frames % 60 == 0) std.log.info("rendered {d} frames", .{frames});
    }
}
