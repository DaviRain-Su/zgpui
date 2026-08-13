//! Div: the styled container element with a fluent builder API, modeled on
//! gpui's `elements/div.rs`.
//!
//! Divs are allocated from the frame arena and rebuilt every frame:
//!
//! ```zig
//! const root = div(arena)
//!     .flexCol()
//!     .gapPx(8)
//!     .bg(Rgba.fromHex(0x1e1e2e))
//!     .childDiv(div(arena).wPx(100).hPx(40).bg(Rgba.fromHex(0x89b4fa)));
//! ```

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const style_mod = @import("../style.zig");
const layout = @import("../layout/layout.zig");
const element = @import("../element.zig");
const scene_mod = @import("../scene.zig");
const platform = @import("../platform.zig");
const a11y_mod = @import("../a11y.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Edges = geometry.Edges;
const Corners = geometry.Corners;
const Rgba = color.Rgba;
const Style = style_mod.Style;
const Element = element.Element;

pub fn div(arena: std.mem.Allocator) *Div {
    const d = arena.create(Div) catch @panic("frame arena OOM");
    d.* = .{ .arena = arena };
    return d;
}

pub const Div = struct {
    arena: std.mem.Allocator,
    style: Style = .{},
    children: std.ArrayList(Element) = .empty,

    // Interactivity
    id: ?element.ElementId = null,
    focus_id: ?element.FocusId = null,
    on_click: ?element.MouseHandler = null,
    on_mouse_down: ?element.MouseHandler = null,
    on_mouse_up: ?element.MouseHandler = null,
    on_hover: ?element.HoverHandler = null,
    on_scroll: ?element.ScrollHandler = null,
    on_key: ?element.KeyHandler = null,
    on_text_input: ?element.TextInputHandler = null,
    force_hitbox: bool = false,
    /// Optional link target for accessibility semantics (not used for navigation).
    href: ?[]const u8 = null,

    // Accessibility (registered during prepaint when role is set)
    a11y_role: ?a11y_mod.Role = null,
    a11y_name: a11y_mod.NameSource = .none,
    a11y_label_for: ?element.ElementId = null,
    a11y_value_text: ?[]const u8 = null,
    a11y_checked: ?bool = null,
    a11y_selected: ?bool = null,
    a11y_disabled: bool = false,
    a11y_expanded: ?bool = null,
    a11y_live: ?a11y_mod.LivePriority = null,
    a11y_rotor_group: ?[]const u8 = null,
    a11y_nav_order: ?i32 = null,
    a11y_numeric_value: ?f64 = null,
    a11y_min_value: ?f64 = null,
    a11y_max_value: ?f64 = null,

    // Frame state (set during layout/prepaint)
    node: ?*layout.Node = null,
    bounds: Bounds(Pixels) = .{},

    const vtable = Element.VTable{
        .request_layout = requestLayoutErased,
        .prepaint = prepaintErased,
        .paint = paintErased,
    };

    pub fn any(self: *Div) Element {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ------------------------------------------------------------------
    // Fluent style API
    // ------------------------------------------------------------------

    pub fn withStyle(self: *Div, s: Style) *Div {
        self.style = s;
        return self;
    }

    pub fn bg(self: *Div, background: Rgba) *Div {
        self.style.background = background;
        return self;
    }

    pub fn border(self: *Div, width: Pixels, border_color: Rgba) *Div {
        self.style.border_widths = Edges(Pixels).all(width);
        self.style.border_color = border_color;
        return self;
    }

    pub fn rounded(self: *Div, radius: Pixels) *Div {
        self.style.corner_radii = Corners(Pixels).all(radius);
        return self;
    }

    pub fn shadow(self: *Div, box_shadow: style_mod.BoxShadow) *Div {
        self.style.box_shadow = box_shadow;
        return self;
    }

    pub fn wPx(self: *Div, width: Pixels) *Div {
        self.style.width = .{ .px = width };
        return self;
    }

    pub fn hPx(self: *Div, height: Pixels) *Div {
        self.style.height = .{ .px = height };
        return self;
    }

    pub fn wFull(self: *Div) *Div {
        self.style.width = .{ .percent = 100 };
        return self;
    }

    pub fn hFull(self: *Div) *Div {
        self.style.height = .{ .percent = 100 };
        return self;
    }

    pub fn sizePx(self: *Div, width: Pixels, height: Pixels) *Div {
        return self.wPx(width).hPx(height);
    }

    pub fn flexRow(self: *Div) *Div {
        self.style.flex_direction = .row;
        return self;
    }

    pub fn flexCol(self: *Div) *Div {
        self.style.flex_direction = .column;
        return self;
    }

    pub fn grow(self: *Div) *Div {
        self.style.flex_grow = 1;
        return self;
    }

    pub fn gapPx(self: *Div, gap: Pixels) *Div {
        self.style.gap = gap;
        return self;
    }

    pub fn padPx(self: *Div, padding: Pixels) *Div {
        self.style.padding = .{
            .top = .{ .px = padding },
            .right = .{ .px = padding },
            .bottom = .{ .px = padding },
            .left = .{ .px = padding },
        };
        return self;
    }

    pub fn itemsCenter(self: *Div) *Div {
        self.style.align_items = .center;
        return self;
    }

    pub fn justifyCenter(self: *Div) *Div {
        self.style.justify_content = .center;
        return self;
    }

    pub fn justifyBetween(self: *Div) *Div {
        self.style.justify_content = .space_between;
        return self;
    }

    pub fn overflowHidden(self: *Div) *Div {
        self.style.overflow_x = .hidden;
        self.style.overflow_y = .hidden;
        return self;
    }

    pub fn absolute(self: *Div) *Div {
        self.style.position = .absolute;
        return self;
    }

    // ------------------------------------------------------------------
    // Children
    // ------------------------------------------------------------------

    pub fn child(self: *Div, el: Element) *Div {
        self.children.append(self.arena, el) catch @panic("frame arena OOM");
        return self;
    }

    pub fn childDiv(self: *Div, d: *Div) *Div {
        return self.child(d.any());
    }

    // ------------------------------------------------------------------
    // Interactivity
    // ------------------------------------------------------------------

    /// Stable identity, required for hover/click/focus behavior.
    pub fn withId(self: *Div, name: []const u8) *Div {
        self.id = element.elementId(name);
        return self;
    }

    pub fn onClick(self: *Div, ctx: ?*anyopaque, func: *const fn (?*anyopaque, *const platform.MouseButtonEvent) void) *Div {
        self.on_click = .{ .ctx = ctx, .func = func };
        return self;
    }

    pub fn onMouseDown(self: *Div, ctx: ?*anyopaque, func: *const fn (?*anyopaque, *const platform.MouseButtonEvent) void) *Div {
        self.on_mouse_down = .{ .ctx = ctx, .func = func };
        return self;
    }

    pub fn onMouseUp(self: *Div, ctx: ?*anyopaque, func: *const fn (?*anyopaque, *const platform.MouseButtonEvent) void) *Div {
        self.on_mouse_up = .{ .ctx = ctx, .func = func };
        return self;
    }

    pub fn onHover(self: *Div, ctx: ?*anyopaque, func: *const fn (?*anyopaque, bool) void) *Div {
        self.on_hover = .{ .ctx = ctx, .func = func };
        return self;
    }

    pub fn onScroll(self: *Div, ctx: ?*anyopaque, func: *const fn (?*anyopaque, *const platform.ScrollEvent) void) *Div {
        self.on_scroll = .{ .ctx = ctx, .func = func };
        return self;
    }

    /// Register in tab order with the given focus id; key events are
    /// delivered when focused.
    pub fn focusable(self: *Div, focus_id: element.FocusId, on_key: ?element.KeyHandler) *Div {
        self.focus_id = focus_id;
        self.on_key = on_key;
        return self;
    }

    pub fn onTextInput(self: *Div, ctx: ?*anyopaque, func: *const fn (?*anyopaque, *const platform.TextInputEvent) bool) *Div {
        self.on_text_input = .{ .ctx = ctx, .func = func };
        return self;
    }

    /// Register a hitbox even without handlers, so hover state is tracked
    /// (e.g. hover styling on disabled controls).
    pub fn interactive(self: *Div) *Div {
        self.force_hitbox = true;
        return self;
    }

    /// Store an href for accessibility semantics (no networking).
    pub fn withHref(self: *Div, href: ?[]const u8) *Div {
        self.href = href;
        return self;
    }

    // ------------------------------------------------------------------
    // Accessibility
    // ------------------------------------------------------------------

    pub fn role(self: *Div, r: a11y_mod.Role) *Div {
        self.a11y_role = r;
        return self;
    }

    pub fn a11yName(self: *Div, name: []const u8) *Div {
        self.a11y_name = .{ .label = name };
        return self;
    }

    pub fn a11yLabelledBy(self: *Div, id: element.ElementId) *Div {
        self.a11y_name = .{ .labelled_by = id };
        return self;
    }

    /// Associate this semantic label with a target in the same frame.
    pub fn a11yLabelFor(self: *Div, id: element.ElementId) *Div {
        self.a11y_label_for = id;
        return self;
    }

    pub fn a11yValueText(self: *Div, text: ?[]const u8) *Div {
        self.a11y_value_text = text;
        return self;
    }

    pub fn a11yChecked(self: *Div, checked: ?bool) *Div {
        self.a11y_checked = checked;
        return self;
    }

    pub fn a11ySelected(self: *Div, selected: ?bool) *Div {
        self.a11y_selected = selected;
        return self;
    }

    pub fn a11yDisabled(self: *Div, disabled: bool) *Div {
        self.a11y_disabled = disabled;
        return self;
    }

    pub fn a11yExpanded(self: *Div, expanded: ?bool) *Div {
        self.a11y_expanded = expanded;
        return self;
    }

    pub fn a11yLive(self: *Div, priority: a11y_mod.LivePriority) *Div {
        self.a11y_live = priority;
        return self;
    }

    /// Join an author-defined AppKit custom rotor labeled `group`.
    pub fn a11yRotorGroup(self: *Div, group: []const u8) *Div {
        self.a11y_rotor_group = group;
        return self;
    }

    /// Override sibling / tab navigation order (lower comes first).
    pub fn a11yNavOrder(self: *Div, order: i32) *Div {
        self.a11y_nav_order = order;
        return self;
    }

    pub fn a11yNumeric(self: *Div, value: f64, min_value: f64, max_value: f64) *Div {
        self.a11y_numeric_value = value;
        self.a11y_min_value = min_value;
        self.a11y_max_value = max_value;
        return self;
    }

    /// Apply multiple accessibility fields at once (unset fields keep prior values).
    pub fn a11y(self: *Div, partial: a11y_mod.Node) *Div {
        self.a11y_role = partial.role;
        self.a11y_name = partial.name;
        self.a11y_label_for = partial.label_for;
        self.a11y_value_text = partial.value_text;
        self.a11y_checked = partial.checked;
        self.a11y_selected = partial.selected;
        self.a11y_disabled = partial.disabled;
        self.a11y_expanded = partial.expanded;
        self.a11y_live = partial.live;
        self.a11y_rotor_group = partial.rotor_group;
        self.a11y_nav_order = partial.nav_order;
        self.a11y_numeric_value = partial.numeric_value;
        self.a11y_min_value = partial.min_value;
        self.a11y_max_value = partial.max_value;
        return self;
    }

    fn isInteractive(self: *const Div) bool {
        return self.force_hitbox or self.on_click != null or self.on_mouse_down != null or
            self.on_mouse_up != null or self.on_hover != null or self.on_scroll != null;
    }

    // ------------------------------------------------------------------
    // Element implementation
    // ------------------------------------------------------------------

    fn requestLayoutErased(ptr: *anyopaque, pass: *element.LayoutPass) anyerror!*layout.Node {
        const self: *Div = @ptrCast(@alignCast(ptr));
        return self.requestLayout(pass);
    }

    pub fn requestLayout(self: *Div, pass: *element.LayoutPass) anyerror!*layout.Node {
        const node = try pass.arena.create(layout.Node);
        node.* = pass.engine.newNode();
        self.node = node;
        applyStyle(node, &self.style);

        for (self.children.items) |child_el| {
            const child_node = try child_el.requestLayout(pass);
            node.addChild(child_node);
        }
        return node;
    }

    fn prepaintErased(ptr: *anyopaque, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
        const self: *Div = @ptrCast(@alignCast(ptr));
        return self.prepaint(pass, parent_origin);
    }

    pub fn prepaint(self: *Div, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
        const node = self.node orelse return error.LayoutNotRequested;
        const relative = node.layoutBounds();
        self.bounds = .{
            .origin = parent_origin.add(relative.origin),
            .size = relative.size,
        };

        if (self.isInteractive()) {
            try pass.frame.addHitbox(.{
                .id = self.id,
                .bounds = self.bounds,
                .on_mouse_down = self.on_mouse_down,
                .on_mouse_up = self.on_mouse_up,
                .on_click = self.on_click,
                .on_hover = self.on_hover,
                .on_scroll = self.on_scroll,
            });
        }
        if (self.focus_id) |focus_id| {
            try pass.frame.addFocusable(.{
                .id = focus_id,
                .on_key = self.on_key,
                .on_text_input = self.on_text_input,
                .nav_order = self.a11y_nav_order,
            });
        }

        if (self.a11y_role) |a11y_role| {
            // Any explicit role + id enters the tree (labels, headings, etc.),
            // not only interactive / focusable controls.
            if (a11y_role != .none) {
                if (self.id) |element_id| {
                    try pass.frame.registerA11y(.{
                        .id = element_id,
                        .role = a11y_role,
                        .name = self.a11y_name,
                        .label_for = self.a11y_label_for,
                        .value_text = self.a11y_value_text,
                        .checked = self.a11y_checked,
                        .selected = self.a11y_selected,
                        .disabled = self.a11y_disabled,
                        .expanded = self.a11y_expanded,
                        .live = self.a11y_live,
                        .rotor_group = self.a11y_rotor_group,
                        .nav_order = self.a11y_nav_order,
                        .pressable = self.on_click != null,
                        .adjustable = a11y_mod.roleSupportsAdjust(a11y_role) and self.on_key != null,
                        .numeric_value = self.a11y_numeric_value,
                        .min_value = self.a11y_min_value,
                        .max_value = self.a11y_max_value,
                        .parent_id = pass.a11y_parent,
                        .bounds = self.bounds,
                    });
                    const previous_parent = pass.a11y_parent;
                    pass.a11y_parent = element_id;
                    defer pass.a11y_parent = previous_parent;

                    for (self.children.items) |child_el| {
                        try child_el.prepaint(pass, self.bounds.origin);
                    }
                    return;
                }
            }
        }

        for (self.children.items) |child_el| {
            try child_el.prepaint(pass, self.bounds.origin);
        }
    }

    fn paintErased(ptr: *anyopaque, pass: *element.PaintPass) anyerror!void {
        const self: *Div = @ptrCast(@alignCast(ptr));
        return self.paint(pass);
    }

    pub fn paint(self: *Div, pass: *element.PaintPass) anyerror!void {
        if (self.style.display == .none) return;
        if (!pass.shouldPaint(self.bounds)) return;

        const bounds_f = scene_mod.BoundsF.from(self.bounds);
        const clip_f = pass.clipF();

        if (self.style.box_shadow) |box_shadow| {
            const shadow_bounds = Bounds(Pixels){
                .origin = self.bounds.origin.add(box_shadow.offset),
                .size = self.bounds.size,
            };
            try pass.scene.insertShadow(.{
                .blur_radius = box_shadow.blur_radius,
                .bounds = scene_mod.BoundsF.from(shadow_bounds),
                .clip_bounds = clip_f,
                .corner_radii = scene_mod.CornersF.from(self.style.corner_radii),
                .color = scene_mod.ColorF.from(box_shadow.color),
            });
        }

        if (self.style.hasBackground() or self.style.hasBorder()) {
            try pass.scene.insertQuad(.{
                .bounds = bounds_f,
                .clip_bounds = clip_f,
                .background = scene_mod.ColorF.from(self.style.background orelse Rgba.transparent),
                .border_color = scene_mod.ColorF.from(self.style.border_color orelse Rgba.transparent),
                .corner_radii = scene_mod.CornersF.from(self.style.corner_radii),
                .border_widths = scene_mod.EdgesF.from(self.style.border_widths),
            });
        }

        const clips_children = self.style.overflow_x == .hidden or self.style.overflow_y == .hidden;
        const previous_clip = if (clips_children) pass.pushClip(self.bounds) else undefined;
        defer if (clips_children) pass.popClip(previous_clip);

        for (self.children.items) |child_el| {
            try child_el.paint(pass);
        }
    }
};

fn toDimension(length: style_mod.Length) layout.Dimension {
    return switch (length) {
        .auto => .auto,
        .px => |v| .{ .points = v },
        .percent => |v| .{ .percent = v },
    };
}

fn applyStyle(node: *layout.Node, s: *const Style) void {
    node.setDisplay(switch (s.display) {
        .flex => .flex,
        .none => .none,
    });
    node.setPositionType(switch (s.position) {
        .relative => .relative,
        .absolute => .absolute,
    });
    if (s.position == .absolute) {
        node.setPosition(.top, toDimension(s.inset.top));
        node.setPosition(.right, toDimension(s.inset.right));
        node.setPosition(.bottom, toDimension(s.inset.bottom));
        node.setPosition(.left, toDimension(s.inset.left));
    }

    node.setWidth(toDimension(s.width));
    node.setHeight(toDimension(s.height));
    node.setMinWidth(toDimension(s.min_width));
    node.setMinHeight(toDimension(s.min_height));
    node.setMaxWidth(toDimension(s.max_width));
    node.setMaxHeight(toDimension(s.max_height));

    inline for (.{ .top, .right, .bottom, .left }) |edge| {
        const padding = @field(s.padding, @tagName(edge));
        switch (padding) {
            .px => |v| node.setPadding(edge, v),
            .percent => |v| node.setPaddingPercent(edge, v),
            else => {},
        }
        const margin = @field(s.margin, @tagName(edge));
        switch (margin) {
            .auto => node.setMargin(edge, .auto),
            .px => |v| node.setMargin(edge, .{ .points = v }),
            .percent => |v| node.setMargin(edge, .{ .percent = v }),
        }
    }
    node.setGapAll(s.gap);

    node.setFlexDirection(switch (s.flex_direction) {
        .row => .row,
        .column => .column,
        .row_reverse => .row_reverse,
        .column_reverse => .column_reverse,
    });
    node.setFlexGrow(s.flex_grow);
    node.setFlexShrink(s.flex_shrink);
    node.setFlexBasis(toDimension(s.flex_basis));

    if (s.justify_content) |justify| {
        node.setJustifyContent(switch (justify) {
            .flex_start => .flex_start,
            .flex_end => .flex_end,
            .center => .center,
            .space_between => .space_between,
            .space_around => .space_around,
            .space_evenly => .space_evenly,
        });
    }
    if (s.align_items) |items| {
        node.setAlignItems(alignToLayout(items));
    }
    if (s.align_self) |self_align| {
        node.setAlignSelf(alignToLayout(self_align));
    }

    if (s.overflow_x == .hidden or s.overflow_y == .hidden) {
        node.setOverflow(.hidden);
    } else if (s.overflow_x == .scroll or s.overflow_y == .scroll) {
        node.setOverflow(.scroll);
    }
}

fn alignToLayout(a: style_mod.AlignItems) layout.Align {
    return switch (a) {
        .flex_start => .flex_start,
        .flex_end => .flex_end,
        .center => .center,
        .stretch => .stretch,
        .baseline => .baseline,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestFrame = struct {
    arena_state: std.heap.ArenaAllocator,
    engine: layout.LayoutEngine,
    frame: element.FrameState,
    scene: scene_mod.Scene,
    root_node: ?*layout.Node = null,

    fn init() TestFrame {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .engine = layout.LayoutEngine.init(),
            .frame = element.FrameState.init(std.testing.allocator),
            .scene = scene_mod.Scene.init(std.testing.allocator),
        };
    }

    fn deinit(self: *TestFrame) void {
        if (self.root_node) |node| node.freeRecursive();
        self.scene.deinit();
        self.frame.deinit();
        self.engine.deinit();
        self.arena_state.deinit();
    }

    fn run(self: *TestFrame, root: Element, width: Pixels, height: Pixels) !void {
        var layout_pass = element.LayoutPass{
            .arena = self.arena_state.allocator(),
            .engine = &self.engine,
        };
        const root_node = try root.requestLayout(&layout_pass);
        self.root_node = root_node;
        self.engine.computeLayout(root_node, width, height);

        var prepaint_pass = element.PrepaintPass{ .arena = self.arena_state.allocator(), .scratch = self.arena_state.allocator(), .frame = &self.frame,
        };
        try root.prepaint(&prepaint_pass, .{});

        var paint_pass = element.PaintPass{ .scratch = self.arena_state.allocator(), .scene = &self.scene };
        try root.paint(&paint_pass);
    }
};

test "div tree layouts and paints quads" {
    var tf = TestFrame.init();
    defer tf.deinit();
    const arena = tf.arena_state.allocator();

    const root = div(arena)
        .flexRow()
        .sizePx(200, 100)
        .bg(Rgba.fromHex(0x111111))
        .childDiv(div(arena).grow().bg(Rgba.fromHex(0xff0000)))
        .childDiv(div(arena).grow().bg(Rgba.fromHex(0x00ff00)));

    try tf.run(root.any(), 200, 100);

    // Root + two children.
    try std.testing.expectEqual(@as(usize, 3), tf.scene.quads.items.len);

    const left = tf.scene.quads.items[1];
    try std.testing.expectEqual(@as(f32, 0), left.bounds.origin_x);
    try std.testing.expectEqual(@as(f32, 100), left.bounds.size_w);
    try std.testing.expectEqual(@as(f32, 100), left.bounds.size_h);

    const right = tf.scene.quads.items[2];
    try std.testing.expectEqual(@as(f32, 100), right.bounds.origin_x);
    try std.testing.expectEqual(@as(f32, 100), right.bounds.size_w);
}

test "absolute origins accumulate through nesting" {
    var tf = TestFrame.init();
    defer tf.deinit();
    const arena = tf.arena_state.allocator();

    const inner = div(arena).sizePx(20, 20).bg(Rgba.white);
    const middle = div(arena).padPx(10).bg(Rgba.black).childDiv(inner);
    const root = div(arena).padPx(5).sizePx(100, 100).childDiv(middle);

    try tf.run(root.any(), 100, 100);

    // inner is offset by root padding (5) + middle padding (10).
    try std.testing.expectEqual(@as(f32, 15), tf.scene.quads.items[1].bounds.origin_x);
    try std.testing.expectEqual(@as(f32, 15), tf.scene.quads.items[1].bounds.origin_y);
}

test "interactive div registers hitbox; click fires" {
    var tf = TestFrame.init();
    defer tf.deinit();
    const arena = tf.arena_state.allocator();

    var clicks: u32 = 0;
    const handler = struct {
        fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
            const count: *u32 = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    }.onClick;

    const button = div(arena)
        .withId("btn")
        .sizePx(80, 30)
        .bg(Rgba.fromHex(0x336699))
        .onClick(&clicks, handler);
    const root = div(arena).sizePx(200, 100).padPx(10).childDiv(button);

    try tf.run(root.any(), 200, 100);

    try std.testing.expectEqual(@as(usize, 1), tf.frame.hitboxes.items.len);
    const hitbox = tf.frame.hitboxes.items[0];
    try std.testing.expectEqual(@as(f32, 10), hitbox.bounds.origin.x);

    var input = element.InputState{};
    _ = input.dispatch(&tf.frame, .{ .mouse_down = .{ .button = .left, .position = .{ .x = 20, .y = 20 } } });
    _ = input.dispatch(&tf.frame, .{ .mouse_up = .{ .button = .left, .position = .{ .x = 20, .y = 20 } } });
    try std.testing.expectEqual(@as(u32, 1), clicks);
}

test "div registers live-region priority" {
    var tf = TestFrame.init();
    defer tf.deinit();
    const arena = tf.arena_state.allocator();

    const status = div(arena)
        .withId("save-status")
        .sizePx(120, 24)
        .role(.generic)
        .a11yName("Saved")
        .a11yLive(.polite);
    try tf.run(status.any(), 200, 100);

    const node = a11y_mod.findById(&tf.frame, element.elementId("save-status")).?;
    try std.testing.expectEqual(a11y_mod.LivePriority.polite, node.live.?);
}

test "div registers rotor group and nav order" {
    var tf = TestFrame.init();
    defer tf.deinit();
    const arena = tf.arena_state.allocator();

    const err = div(arena)
        .withId("form-error")
        .sizePx(120, 24)
        .role(.generic)
        .a11yName("Missing name")
        .a11yRotorGroup("Errors")
        .a11yNavOrder(2)
        .focusable(element.elementId("form-error"), null);
    try tf.run(err.any(), 200, 100);

    const node = a11y_mod.findById(&tf.frame, element.elementId("form-error")).?;
    try std.testing.expectEqualStrings("Errors", node.rotor_group.?);
    try std.testing.expectEqual(@as(i32, 2), node.nav_order.?);
    try std.testing.expectEqual(@as(?i32, 2), tf.frame.focusables.items[0].nav_order);
}

test "overflow hidden sets clip bounds on children" {
    var tf = TestFrame.init();
    defer tf.deinit();
    const arena = tf.arena_state.allocator();

    const tall_child = div(arena).wPx(50).hPx(500).bg(Rgba.red);
    const clipper = div(arena).sizePx(100, 100).overflowHidden().bg(Rgba.black).childDiv(tall_child);

    try tf.run(clipper.any(), 100, 100);

    const child_quad = tf.scene.quads.items[1];
    try std.testing.expectEqual(@as(f32, 100), child_quad.clip_bounds.size_w);
    try std.testing.expectEqual(@as(f32, 100), child_quad.clip_bounds.size_h);
    // Clipper itself is unclipped.
    try std.testing.expectEqual(@as(f32, 0), tf.scene.quads.items[0].clip_bounds.size_w);
}
