//! Component gallery: wires a batch of newer headless components into a
//! real window (switch, number input, badge, progress, pagination, crumbs).
//!
//! Run with: zig build run-04_components

const std = @import("std");
const zgpui = @import("zgpui");

const Rgba = zgpui.Rgba;
const Style = zgpui.style.Style;
const switch_ = zgpui.components.switch_;
const number_input = zgpui.components.number_input;
const badge = zgpui.components.badge;
const progress = zgpui.components.progress;
const pagination = zgpui.components.pagination;
const breadcrumb = zgpui.components.breadcrumb;
const link = zgpui.components.link;
const spinner = zgpui.components.spinner;
const separator = zgpui.components.separator;

const Demo = struct {
    app: *zgpui.App,
    window: *zgpui.Window = undefined,
    switch_state: zgpui.Entity(switch_.SwitchState) = undefined,
    number_state: zgpui.Entity(number_input.Value.Store) = undefined,
    page_state: zgpui.Entity(pagination.Value.Store) = undefined,
    text_resources: zgpui.TextResources = undefined,

    fn label(self: *Demo, arena: std.mem.Allocator, content: []const u8, size: f32, text_color: Rgba) zgpui.Element {
        return zgpui.textEl(arena, &self.text_resources, content).size(size).withColor(text_color).any();
    }

    fn switchStyle(state: switch_.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 44 };
        s.height = .{ .px = 24 };
        s.corner_radii = zgpui.Corners(f32).all(12);
        s.background = if (state.on) Rgba.fromHex(0x22c55e) else Rgba.fromHex(0x475569);
        if (state.focused) {
            s.border_widths = zgpui.Edges(f32).all(2);
            s.border_color = Rgba.fromHex(0x93c5fd);
        }
        return s;
    }

    fn numberStyle(state: number_input.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 96 };
        s.height = .{ .px = 36 };
        s.corner_radii = zgpui.Corners(f32).all(8);
        s.background = if (state.focused) Rgba.fromHex(0x1e293b) else Rgba.fromHex(0x334155);
        s.border_widths = zgpui.Edges(f32).all(1);
        s.border_color = if (state.focused) Rgba.fromHex(0x60a5fa) else Rgba.fromHex(0x64748b);
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn badgeStyle(state: badge.StyleState) Style {
        var s = Style{};
        s.height = .{ .px = 22 };
        s.padding = .{ .top = .{ .px = 2 }, .bottom = .{ .px = 2 }, .left = .{ .px = 10 }, .right = .{ .px = 10 } };
        s.corner_radii = zgpui.Corners(f32).all(999);
        s.background = switch (state.variant) {
            .default => Rgba.fromHex(0x475569),
            .success => Rgba.fromHex(0x16a34a),
            .warning => Rgba.fromHex(0xd97706),
            .danger => Rgba.fromHex(0xdc2626),
        };
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn progressTrack(_: progress.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 220 };
        s.height = .{ .px = 10 };
        s.corner_radii = zgpui.Corners(f32).all(5);
        s.background = Rgba.fromHex(0x1e293b);
        return s;
    }

    fn progressFill(state: progress.StyleState) Style {
        var s = Style{};
        s.height = .{ .px = 10 };
        s.corner_radii = zgpui.Corners(f32).all(5);
        s.background = if (state.indeterminate) Rgba.fromHex(0x64748b) else Rgba.fromHex(0x38bdf8);
        return s;
    }

    fn pageBtn(state: pagination.ButtonStyleState) Style {
        var s = Style{};
        s.width = .{ .px = 36 };
        s.height = .{ .px = 32 };
        s.corner_radii = zgpui.Corners(f32).all(6);
        s.background = if (state.disabled)
            Rgba.fromHex(0x1e293b)
        else if (state.hovered)
            Rgba.fromHex(0x475569)
        else
            Rgba.fromHex(0x334155);
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn pageNum(state: pagination.PageStyleState) Style {
        var s = Style{};
        s.width = .{ .px = 32 };
        s.height = .{ .px = 32 };
        s.corner_radii = zgpui.Corners(f32).all(6);
        s.background = if (state.selected)
            Rgba.fromHex(0x2563eb)
        else if (state.hovered)
            Rgba.fromHex(0x475569)
        else
            Rgba.fromHex(0x334155);
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn crumbStyle(state: breadcrumb.ItemStyleState) Style {
        var s = Style{};
        s.height = .{ .px = 24 };
        s.padding = .{ .left = .{ .px = 6 }, .right = .{ .px = 6 }, .top = .{ .px = 2 }, .bottom = .{ .px = 2 } };
        s.background = if (state.current)
            Rgba.fromHex(0x0f172a)
        else if (state.hovered)
            Rgba.fromHex(0x334155)
        else
            Rgba.fromHex(0x1e293b);
        s.align_items = .center;
        return s;
    }

    fn linkStyle(state: link.StyleState) Style {
        var s = Style{};
        s.height = .{ .px = 24 };
        s.background = Rgba.init(0, 0, 0, 0);
        if (state.focused) {
            s.border_widths = zgpui.Edges(f32).all(1);
            s.border_color = Rgba.fromHex(0x93c5fd);
        }
        return s;
    }

    fn onCrumb(_: ?*anyopaque) void {}

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *zgpui.Window) anyerror!zgpui.Element {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const app = self.app;
        const input = &self.window.input;

        const on = switch_.isOn(app, .{ .uncontrolled = self.switch_state });
        const n = number_input.Value.get(.{ .uncontrolled = self.number_state }, app);
        const page = pagination.pageIndex(app, .{ .uncontrolled = self.page_state });
        const n_text = try std.fmt.allocPrint(arena, "{d}", .{n});
        const page_text = try std.fmt.allocPrint(arena, "page {d}/5", .{page + 1});

        const crumbs = breadcrumb.list(arena, .{ .id = "crumbs" })
            .gapPx(4)
            .childDiv(breadcrumb.item(arena, input, .{
                .id = "crumb-home",
                .on_press = .{ .ctx = self, .func = onCrumb },
                .style_fn = crumbStyle,
            }).child(self.label(arena, "Home", 13, Rgba.fromHex(0x93c5fd))))
            .childDiv(breadcrumb.separator(arena, .{ .id = "crumb-sep" })
                .child(self.label(arena, "/", 13, Rgba.fromHex(0x64748b))))
            .childDiv(breadcrumb.item(arena, input, .{
                .id = "crumb-here",
                .current = true,
                .style_fn = crumbStyle,
            }).child(self.label(arena, "Components", 13, Rgba.white)));

        const switch_row = zgpui.div(arena)
            .flexRow()
            .gapPx(12)
            .itemsCenter()
            .childDiv(switch_.switchEl(arena, app, input, .{
                .id = "demo-switch",
                .value = .{ .uncontrolled = self.switch_state },
                .style_fn = switchStyle,
            }))
            .child(self.label(arena, if (on) "notifications on" else "notifications off", 14, Rgba.fromHex(0xcbd5e1)))
            .childDiv(if (on)
                spinner.spinner(arena, .{
                    .id = "spin",
                    .width = .{ .px = 16 },
                    .height = .{ .px = 16 },
                    .active = true,
                    .style_fn = struct {
                        fn s(_: spinner.StyleState) Style {
                            var st = Style{};
                            st.background = Rgba.fromHex(0x38bdf8);
                            st.corner_radii = zgpui.Corners(f32).all(8);
                            return st;
                        }
                    }.s,
                })
            else
                zgpui.div(arena).sizePx(16, 16));

        const number_row = zgpui.div(arena)
            .flexRow()
            .gapPx(12)
            .itemsCenter()
            .child(self.label(arena, "quantity (↑↓ / +/-)", 14, Rgba.fromHex(0xcbd5e1)))
            .childDiv(number_input.numberInput(arena, app, input, .{
                .id = "qty",
                .value = .{ .uncontrolled = self.number_state },
                .min = 0,
                .max = 20,
                .step = 1,
                .style_fn = numberStyle,
            }).child(self.label(arena, n_text, 15, Rgba.white)))
            .childDiv(badge.badge(arena, .{
                .id = "qty-badge",
                .variant = if (n >= 15) .warning else .success,
                .style_fn = badgeStyle,
            }).child(self.label(arena, if (n >= 15) "high" else "ok", 12, Rgba.white)));

        const frac: f32 = @as(f32, @floatFromInt(n)) / 20.0;
        const progress_row = zgpui.div(arena)
            .flexCol()
            .gapPx(8)
            .child(self.label(arena, "progress mirrors quantity", 14, Rgba.fromHex(0xcbd5e1)))
            .childDiv(progress.progress(arena, .{
                .id = "qty-progress",
                .value = frac,
                .max = 1,
                .track_style_fn = progressTrack,
                .fill_style_fn = progressFill,
            }));

        const pager = pagination.pagination(arena, app, input, .{
            .id = "pager",
            .value = .{ .uncontrolled = self.page_state },
            .page_count = 5,
            .show_page_numbers = true,
            .keyboard = true,
            .prev_style_fn = pageBtn,
            .next_style_fn = pageBtn,
            .page_style_fn = pageNum,
        });

        const link_row = zgpui.div(arena)
            .flexRow()
            .gapPx(16)
            .itemsCenter()
            .childDiv(link.link(arena, input, .{
                .id = "docs-link",
                .href = "https://example.com",
                .style_fn = linkStyle,
            }).child(self.label(arena, "Docs link", 14, Rgba.fromHex(0x7dd3fc))))
            .childDiv(separator.separator(arena, .{
                .id = "sep-v",
                .orientation = .vertical,
                .style_fn = struct {
                    fn s(_: separator.StyleState) Style {
                        var st = Style{};
                        st.width = .{ .px = 1 };
                        st.height = .{ .px = 18 };
                        st.background = Rgba.fromHex(0x475569);
                        return st;
                    }
                }.s,
            }))
            .child(self.label(arena, page_text, 14, Rgba.fromHex(0x94a3b8)));

        return zgpui.div(arena)
            .flexCol()
            .wFull()
            .hFull()
            .padPx(28)
            .gapPx(20)
            .bg(Rgba.fromHex(0x0f172a))
            .child(self.label(arena, "zgpui — component gallery", 22, Rgba.white))
            .childDiv(crumbs)
            .childDiv(switch_row)
            .childDiv(number_row)
            .childDiv(progress_row)
            .childDiv(pager)
            .childDiv(link_row)
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
        .title = "zgpui components",
        .size = .{ .width = 720, .height = 520 },
    });
    defer win.deinit();

    var demo = Demo{ .app = &app };
    demo.window = win;
    demo.switch_state = try app.new(switch_.SwitchState, .{});
    demo.number_state = try app.new(number_input.Value.Store, .{ .value = 4 });
    demo.page_state = try app.new(pagination.Value.Store, .{ .value = 0 });

    var font_system = try zgpui.text.FontSystem.init(gpa);
    defer font_system.deinit();
    const font = try font_system.loadFont("/System/Library/Fonts/Helvetica.ttc", 0);
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

    while (!win.shouldClose()) {
        platform.waitEvents();
        app.flushEffects();
        try win.renderIfNeeded();
    }
}
