//! Advanced gallery: resizable split, tree navigation, and HSV color picker.
//!
//! Run with: zig build run-05_advanced

const std = @import("std");
const zgpui = @import("zgpui");

const Rgba = zgpui.Rgba;
const Style = zgpui.style.Style;
const resizable = zgpui.components.resizable;
const tree = zgpui.components.tree;
const color_picker = zgpui.components.color_picker;

const Demo = struct {
    app: *zgpui.App,
    window: *zgpui.Window = undefined,
    split_state: zgpui.Entity(resizable.ResizableState) = undefined,
    drag_bounds: zgpui.Bounds(f32) = .{},
    tree_state: zgpui.Entity(tree.StateValue.Store) = undefined,
    color_state: zgpui.Entity(color_picker.Value.Store) = undefined,
    text_resources: zgpui.TextResources = undefined,

    const nodes = [_]tree.Node{
        .{ .id = "src" },
        .{ .id = "components", .parent = 0 },
        .{ .id = "tree.zig", .parent = 1 },
        .{ .id = "color_picker.zig", .parent = 1 },
        .{ .id = "platform", .parent = 0 },
        .{ .id = "glfw.zig", .parent = 4 },
    };

    fn label(self: *Demo, arena: std.mem.Allocator, content: []const u8, size: f32, text_color: Rgba) zgpui.Element {
        return zgpui.textEl(arena, &self.text_resources, content).size(size).withColor(text_color).any();
    }

    fn handleStyle(state: resizable.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 6 };
        s.background = if (state.dragging)
            Rgba.fromHex(0x38bdf8)
        else if (state.hovered)
            Rgba.fromHex(0x64748b)
        else
            Rgba.fromHex(0x334155);
        return s;
    }

    fn treeItemStyle(state: tree.StyleState) Style {
        var s = tree.indentStyle(state.depth, 14);
        s.height = .{ .px = 26 };
        s.corner_radii = zgpui.Corners(f32).all(4);
        s.background = if (state.selected)
            Rgba.fromHex(0x1d4ed8)
        else if (state.hovered)
            Rgba.fromHex(0x334155)
        else
            Rgba.fromHex(0x1e293b);
        s.align_items = .center;
        return s;
    }

    fn channelStyle(state: zgpui.components.slider.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 180 };
        s.height = .{ .px = 14 };
        s.corner_radii = zgpui.Corners(f32).all(7);
        s.background = if (state.focused) Rgba.fromHex(0x475569) else Rgba.fromHex(0x334155);
        return s;
    }

    fn swatchStyle(state: color_picker.SwatchStyleState) Style {
        var s = Style{};
        s.width = .{ .px = 40 };
        s.height = .{ .px = 40 };
        s.corner_radii = zgpui.Corners(f32).all(8);
        s.background = state.color;
        if (state.hovered) {
            s.border_widths = zgpui.Edges(f32).all(2);
            s.border_color = Rgba.white;
        }
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, win: *zgpui.Window) anyerror!zgpui.Element {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const app = self.app;
        const input = &win.input;

        const tree_value: tree.StateValue = .{ .uncontrolled = self.tree_state };
        const color_value: color_picker.Value = .{ .uncontrolled = self.color_state };
        const split_value: resizable.Value = .{ .uncontrolled = self.split_state };
        const accent = color_picker.readColor(app, color_value);
        const ratio = resizable.readRatio(app, split_value, 0.2, 0.8);
        const ratio_text = try std.fmt.allocPrint(arena, "split {d:.0}%", .{ratio * 100.0});

        var visible: [16]usize = undefined;
        const tree_snap = tree_value.get(app);
        const visible_n = tree.collectVisible(&nodes, &tree_snap, &visible);

        var tree_root = tree.tree(arena, app, .{
            .id = "file-tree",
            .nodes = &nodes,
            .state = tree_value,
        }).gapPx(2);

        for (visible[0..visible_n]) |idx| {
            const node = nodes[idx];
            tree_root = tree_root.childDiv(tree.treeItem(arena, app, input, .{
                .id = node.id,
                .node_index = idx,
                .nodes = &nodes,
                .state = tree_value,
                .tree_id = "file-tree",
                .style_fn = treeItemStyle,
            }).child(self.label(arena, node.id, 13, Rgba.white)));
        }

        const left = zgpui.div(arena)
            .withId("left-pane")
            .flexCol()
            .padPx(12)
            .gapPx(8)
            .bg(Rgba.fromHex(0x0f172a))
            .overflowHidden()
            .child(self.label(arena, "Files", 14, Rgba.fromHex(0x94a3b8)))
            .childDiv(tree_root);

        const picker = color_picker.colorPicker(arena, app, input, .{
            .id = "accent",
            .value = color_value,
            .hue_style_fn = channelStyle,
            .saturation_style_fn = channelStyle,
            .value_style_fn = channelStyle,
        });

        const right = zgpui.div(arena)
            .withId("right-pane")
            .flexCol()
            .padPx(16)
            .gapPx(12)
            .bg(Rgba.fromHex(0x111827))
            .overflowHidden()
            .child(self.label(arena, "Accent color", 14, Rgba.fromHex(0x94a3b8)))
            .childDiv(zgpui.div(arena)
                .flexRow()
                .gapPx(12)
                .itemsCenter()
                .childDiv(color_picker.colorSwatch(arena, app, input, .{
                    .id = "accent-swatch",
                    .value = color_value,
                    .style_fn = swatchStyle,
                }))
                .child(self.label(arena, "HSV sliders →", 13, Rgba.fromHex(0xcbd5e1))))
            .childDiv(picker)
            .childDiv(zgpui.div(arena)
                .wFull()
                .hPx(48)
                .rounded(8)
                .bg(accent)
                .child(self.label(arena, "preview", 13, Rgba.white)));

        const split_root = resizable.split(arena, app, input, .{
            .id = "main-split",
            .ratio = split_value,
            .orientation = .horizontal,
            .min_ratio = 0.2,
            .max_ratio = 0.8,
            .handle_style_fn = handleStyle,
            .drag_bounds = &self.drag_bounds,
        }, left, right);

        return zgpui.div(arena)
            .flexCol()
            .wFull()
            .hFull()
            .padPx(20)
            .gapPx(12)
            .bg(Rgba.fromHex(0x020617))
            .child(self.label(arena, "zgpui — advanced gallery", 20, Rgba.white))
            .child(self.label(arena, ratio_text, 13, Rgba.fromHex(0x94a3b8)))
            .childDiv(split_root.grow().overflowHidden())
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
        .title = "zgpui advanced",
        .size = .{ .width = 860, .height = 560 },
    });
    defer win.deinit();

    var demo = Demo{ .app = &app };
    demo.window = win;
    demo.split_state = try app.new(resizable.ResizableState, .{ .ratio = 0.38 });
    demo.tree_state = try app.new(tree.StateValue.Store, .{ .value = .{} });
    demo.color_state = try app.new(color_picker.Value.Store, .{ .value = Rgba.fromHex(0x38bdf8) });

    // Expand "src" by default.
    {
        const st = &demo.tree_state;
        _ = st;
        app.read(tree.StateValue.Store, demo.tree_state).value.setExpanded(tree.nodeHash("src"), true);
    }

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

    while (!win.shouldClose()) {
        platform.waitEvents();
        app.flushEffects();
        try win.renderIfNeeded();
    }
}
