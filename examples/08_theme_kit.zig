//! Theme kit demo: appearance toggle, token swatches, Geist type, and SVG icons.
//!
//! Run with: zig build run-08_theme_kit

const std = @import("std");
const zgpui = @import("zgpui");

const Rgba = zgpui.Rgba;
const Style = zgpui.style.Style;
const Theme = zgpui.theme.Theme;
const Appearance = zgpui.theme.Appearance;
const button = zgpui.components.button;

const UiState = struct {
    appearance: Appearance = .dark,
};

const Demo = struct {
    app: *zgpui.App,
    window: *zgpui.Window = undefined,
    ui: zgpui.Entity(UiState) = undefined,
    text_resources: zgpui.TextResources = undefined,
    geist: zgpui.fonts.Registered = undefined,

    fn theme(self: *Demo) Theme {
        return Theme.forAppearance(self.app.read(UiState, self.ui).appearance);
    }

    fn toggleAppearance(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const state = self.app.read(UiState, self.ui);
        state.appearance = if (state.appearance == .dark) .light else .dark;
        self.app.notify(self.ui.id);
    }

    fn makePrimaryStyle(t: Theme) *const fn (button.StyleState) Style {
        const Ctx = struct {
            var cached: Theme = undefined;
            fn style(state: button.StyleState) Style {
                var s = Style{};
                s.height = .{ .px = 36 };
                s.padding = .{
                    .left = .{ .px = 14 },
                    .right = .{ .px = 14 },
                    .top = .{ .px = 0 },
                    .bottom = .{ .px = 0 },
                };
                s.corner_radii = zgpui.Corners(f32).all(Theme.control_radius);
                s.background = if (state.pressed)
                    cached.accent_strong
                else if (state.hovered)
                    cached.accent
                else
                    cached.solid;
                s.align_items = .center;
                s.justify_content = .center;
                if (state.focused) {
                    s.border_widths = zgpui.Edges(f32).all(2);
                    s.border_color = cached.accent;
                }
                return s;
            }
        };
        Ctx.cached = t;
        return Ctx.style;
    }

    fn label(
        self: *Demo,
        arena: std.mem.Allocator,
        content: []const u8,
        size: f32,
        text_color: Rgba,
        font: zgpui.text.FontId,
    ) zgpui.Element {
        return zgpui.textEl(arena, &self.text_resources, content)
            .size(size)
            .withColor(text_color)
            .withFont(font)
            .any();
    }

    fn swatch(arena: std.mem.Allocator, fill: Rgba, label_el: zgpui.Element) zgpui.Element {
        return zgpui.div(arena)
            .flexCol()
            .gapPx(6)
            .itemsCenter()
            .childDiv(zgpui.div(arena).sizePx(48, 32).rounded(Theme.control_radius).bg(fill))
            .child(label_el)
            .any();
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *zgpui.Window) anyerror!zgpui.Element {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const t = self.theme();
        const input = &self.window.input;
        const mode_label: []const u8 = if (t.appearance == .dark) "Dark" else "Light";
        const toggle_caption = try std.fmt.allocPrint(arena, "Switch to {s}", .{
            if (t.appearance == .dark) "Light" else "Dark",
        });

        const title = self.label(arena, "zgpui theme kit", 22, t.text, self.geist.semibold);
        const subtitle = self.label(
            arena,
            "Tokens · Geist · Solar icons · selection recipes",
            14,
            t.text_muted,
            self.geist.sans,
        );

        const toggle = button.button(arena, input, .{
            .id = "toggle-appearance",
            .on_press = .{ .ctx = self, .func = toggleAppearance },
            .style_fn = makePrimaryStyle(t),
        }).child(self.label(
            arena,
            toggle_caption,
            14,
            if (t.appearance == .dark) t.on_solid else t.on_accent,
            self.geist.medium,
        ));

        const icon_row = zgpui.div(arena)
            .flexRow()
            .gapPx(Theme.space_md)
            .itemsCenter()
            .child(zgpui.iconEl(arena, &self.text_resources, zgpui.icons.check).size(22).withColor(t.success).withName("check").any())
            .child(zgpui.iconEl(arena, &self.text_resources, zgpui.icons.paperclip).size(22).withColor(t.text).withName("paperclip").any())
            .child(zgpui.iconEl(arena, &self.text_resources, zgpui.icons.settings_minimalistic).size(22).withColor(t.text_muted).withName("settings").any())
            .child(zgpui.iconEl(arena, &self.text_resources, zgpui.icons.danger_triangle).size(22).withColor(t.danger).withName("danger").any())
            .child(zgpui.iconEl(arena, &self.text_resources, zgpui.icons.terminal).size(22).withColor(t.accent).withName("terminal").any());

        const selected_ring = zgpui.theme.cardSelectedShadows(t.appearance)[0];
        const selected_chip = zgpui.div(arena)
            .flexRow()
            .gapPx(8)
            .itemsCenter()
            .padPx(10)
            .rounded(Theme.control_radius)
            .bg(zgpui.theme.glassSelectedBg(t.appearance))
            .child(zgpui.iconEl(arena, &self.text_resources, zgpui.icons.folder).size(18).withColor(t.text).any())
            .child(self.label(arena, "Selected row (wash + inset ring color)", 13, t.text, self.geist.sans));
        // Approximate inset ring with a 1px border (GPU inset shadows not wired).
        selected_chip.style.border_widths = zgpui.Edges(f32).all(selected_ring.spread_radius);
        selected_chip.style.border_color = selected_ring.color;

        const swatches = zgpui.div(arena)
            .flexRow()
            .gapPx(Theme.space_lg)
            .child(swatch(arena, t.accent, self.label(arena, "accent", 11, t.text_faint, self.geist.sans)))
            .child(swatch(arena, t.danger, self.label(arena, "danger", 11, t.text_faint, self.geist.sans)))
            .child(swatch(arena, t.success, self.label(arena, "success", 11, t.text_faint, self.geist.sans)))
            .child(swatch(arena, t.warning, self.label(arena, "warning", 11, t.text_faint, self.geist.sans)))
            .child(swatch(arena, t.busy, self.label(arena, "busy", 11, t.text_faint, self.geist.sans)));

        const sidebar = zgpui.div(arena)
            .flexCol()
            .wPx(200)
            .hFull()
            .padPx(Theme.space_lg)
            .gapPx(Theme.space_md)
            .bg(t.surface)
            .child(self.label(arena, "Shell", 12, t.text_faint, self.geist.medium))
            .child(self.label(arena, mode_label, 18, t.text, self.geist.bold))
            .child(self.label(arena, "surface / bg / raised", 12, t.text_muted, self.geist.sans))
            .childDiv(zgpui.div(arena).hPx(1).wFull().bg(t.border))
            .childDiv(toggle);

        const main_pane = zgpui.div(arena)
            .flexCol()
            .grow()
            .hFull()
            .padPx(Theme.space_lg)
            .gapPx(Theme.space_lg)
            .bg(t.bg)
            .child(title)
            .child(subtitle)
            .childDiv(zgpui.div(arena).hPx(1).wFull().bg(t.border))
            .child(self.label(arena, "Icons", 13, t.text_muted, self.geist.medium))
            .childDiv(icon_row)
            .child(self.label(arena, "Tokens", 13, t.text_muted, self.geist.medium))
            .childDiv(swatches)
            .child(self.label(arena, "Selection", 13, t.text_muted, self.geist.medium))
            .childDiv(selected_chip);

        return zgpui.div(arena)
            .flexRow()
            .wFull()
            .hFull()
            .bg(t.bg)
            .childDiv(sidebar)
            .childDiv(main_pane)
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
        .title = "zgpui theme kit",
        .size = .{ .width = 880, .height = 520 },
    });
    defer win.deinit();

    var demo = Demo{ .app = &app };
    demo.window = win;
    demo.ui = try app.new(UiState, .{});

    var font_system = try zgpui.text.FontSystem.init(gpa);
    defer font_system.deinit();
    demo.geist = try zgpui.fonts.register(&font_system);

    var atlas = try zgpui.text.GlyphAtlas.init(gpa, zgpui.Size(i32).init(1024, 1024));
    defer atlas.deinit();
    demo.text_resources = .{
        .font_system = &font_system,
        .atlas = &atlas,
        .default_font = demo.geist.sans,
    };
    win.setTextResources(&demo.text_resources);

    win.setRoot(&demo, Demo.render);
    try win.renderFrame();

    while (!win.shouldClose()) {
        platform.waitEvents();
        app.flushEffects();
        try win.renderIfNeeded();
    }
}
