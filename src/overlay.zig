//! Overlay stack: deferred UI layers (dialogs, popovers, menus) painted above
//! the main tree with independent focus trapping.
//!
//! Immediate-mode usage: each frame, open overlays re-register themselves via
//! `OverlayStack.beginFrame` + `push`. The window/harness lays out and paints
//! push'd layers after the main content, in ascending `z_index` order.

const std = @import("std");
const a11y_mod = @import("a11y.zig");
const geometry = @import("geometry.zig");
const layout = @import("layout/layout.zig");
const element = @import("element.zig");
const scene_mod = @import("scene.zig");
const platform = @import("platform.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;

pub const OverlayId = u64;

pub fn overlayId(name: []const u8) OverlayId {
    return std.hash.Wyhash.hash(0x0f07a11, name);
}

pub const OverlayRenderFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element;

pub const OverlayEntry = struct {
    id: OverlayId,
    z_index: i32 = 0,
    /// When true, Tab cycles only among this layer's focusables.
    trap_focus: bool = true,
    /// When true, clicks outside the first interactive child dismiss (caller
    /// handles via `on_dismiss`).
    modal: bool = true,
    ctx: ?*anyopaque = null,
    render: OverlayRenderFn,
    on_dismiss: ?*const fn (ctx: ?*anyopaque) void = null,
};

const LiveLayer = struct {
    entry: OverlayEntry,
    frame: element.FrameState,
    root: ?element.Element = null,
    root_node: ?*layout.Node = null,
};

pub const OverlayStack = struct {
    gpa: std.mem.Allocator,
    /// Registered for the current frame (cleared each beginFrame).
    pending: std.ArrayList(OverlayEntry),
    /// Built layers after `build`.
    layers: std.ArrayList(LiveLayer),
    /// Focus is trapped in this overlay id when set.
    active_trap: ?OverlayId = null,

    pub fn init(gpa: std.mem.Allocator) OverlayStack {
        return .{
            .gpa = gpa,
            .pending = .empty,
            .layers = .empty,
        };
    }

    pub fn deinit(self: *OverlayStack) void {
        self.clearLayers();
        self.pending.deinit(self.gpa);
        self.layers.deinit(self.gpa);
    }

    /// Call at the start of each frame before the main tree render fn runs.
    pub fn beginFrame(self: *OverlayStack) void {
        self.pending.clearRetainingCapacity();
    }

    /// Free built overlay layers from the previous frame. Call before freeing
    /// the main layout tree or resetting the frame arena.
    pub fn discardBuiltLayers(self: *OverlayStack) void {
        self.clearLayers();
    }

    /// Register an overlay for this frame. Safe to call from component render
    /// code (uses the host's overlay stack pointer).
    pub fn push(self: *OverlayStack, entry: OverlayEntry) !void {
        // Replace existing same-id registration this frame.
        for (self.pending.items, 0..) |existing, i| {
            if (existing.id == entry.id) {
                self.pending.items[i] = entry;
                return;
            }
        }
        try self.pending.append(self.gpa, entry);
    }

    pub fn isEmpty(self: *const OverlayStack) bool {
        return self.pending.items.len == 0 and self.layers.items.len == 0;
    }

    fn clearLayers(self: *OverlayStack) void {
        for (self.layers.items) |*layer| {
            if (layer.root_node) |node| {
                node.freeRecursive();
                layer.root_node = null;
            }
            layer.frame.deinit();
        }
        self.layers.clearRetainingCapacity();
    }

    /// Build, layout, and prepaint all pending overlays into `layers`.
    pub fn build(
        self: *OverlayStack,
        arena: std.mem.Allocator,
        engine: *layout.LayoutEngine,
        viewport: Size(Pixels),
    ) !void {
        self.clearLayers();

        // Sort pending by z_index ascending (paint back-to-front).
        const sorted = try self.gpa.dupe(OverlayEntry, self.pending.items);
        defer self.gpa.free(sorted);
        std.mem.sort(OverlayEntry, sorted, {}, struct {
            fn less(_: void, a: OverlayEntry, b: OverlayEntry) bool {
                if (a.z_index == b.z_index) return a.id < b.id;
                return a.z_index < b.z_index;
            }
        }.less);

        self.active_trap = null;
        for (sorted) |entry| {
            var live = LiveLayer{
                .entry = entry,
                .frame = element.FrameState.init(self.gpa),
            };
            errdefer live.frame.deinit();

            const root = try entry.render(entry.ctx, arena);
            live.root = root;

            var layout_pass = element.LayoutPass{ .arena = arena, .engine = engine };
            const root_node = try root.requestLayout(&layout_pass);
            live.root_node = root_node;
            engine.computeLayout(root_node, viewport.width, viewport.height);

            var prepaint_pass = element.PrepaintPass{ .arena = arena, .frame = &live.frame };
            try root.prepaint(&prepaint_pass, .{});

            if (entry.trap_focus) self.active_trap = entry.id;
            try self.layers.append(self.gpa, live);
        }
    }

    /// Paint overlays on top of the main scene.
    pub fn paint(self: *OverlayStack, scene: *scene_mod.Scene) !void {
        for (self.layers.items) |*layer| {
            const root = layer.root orelse continue;
            var paint_pass = element.PaintPass{ .scene = scene };
            try root.paint(&paint_pass);
        }
    }

    /// Dispatch input topmost-first through overlay layers, then return false
    /// if unhandled (caller should fall through to the main frame). Modal
    /// top layers swallow outside clicks via dismiss.
    pub fn dispatch(
        self: *OverlayStack,
        input: *element.InputState,
        event: platform.InputEvent,
    ) bool {
        if (self.layers.items.len == 0) return false;

        var i = self.layers.items.len;
        while (i > 0) {
            i -= 1;
            const layer = &self.layers.items[i];

            if (event == .key_down and event.key_down.key == .escape) {
                if (layer.entry.on_dismiss) |dismiss| {
                    dismiss(layer.entry.ctx);
                    return true;
                }
            }

            // Non-modal layers (tooltips) must not steal hover/move from the
            // main tree.
            if (!layer.entry.modal and (event == .mouse_moved or event == .mouse_exited)) {
                continue;
            }

            const handled = input.dispatch(&layer.frame, event);
            if (handled) return true;

            if (layer.entry.modal) {
                switch (event) {
                    .mouse_down => |down| {
                        if (layer.frame.hitTest(down.position) == null) {
                            if (layer.entry.on_dismiss) |dismiss| dismiss(layer.entry.ctx);
                            return true;
                        }
                    },
                    .mouse_moved, .mouse_up, .mouse_exited, .scroll => return true,
                    else => {},
                }
                // Modal layer blocks the main tree even if it didn't handle the key.
                if (event == .key_down or event == .key_up or event == .text_input or
                    event == .composition_start or event == .composition_update or event == .composition_end) return true;
            }
        }
        return false;
    }

    /// Focusables from the active trap layer (for tests).
    pub fn topFrame(self: *OverlayStack) ?*element.FrameState {
        if (self.layers.items.len == 0) return null;
        return &self.layers.items[self.layers.items.len - 1].frame;
    }

    /// Append the accessibility snapshot visible to the native platform.
    /// A topmost modal isolates everything below it; otherwise the main frame
    /// and all overlays remain visible in back-to-front order.
    pub fn appendAccessibilityNodes(
        self: *const OverlayStack,
        main_nodes: []const a11y_mod.Node,
        out: *std.ArrayList(a11y_mod.Node),
        allocator: std.mem.Allocator,
    ) !void {
        const modal_index = self.topmostModalIndex();
        const first_overlay = modal_index orelse 0;
        const include_main = modal_index == null;

        if (include_main) try out.appendSlice(allocator, main_nodes);
        for (self.layers.items[first_overlay..]) |layer| {
            try out.appendSlice(allocator, layer.frame.a11y.items);
        }
    }

    /// Route a native accessibility press through the same modal isolation as
    /// the composed accessibility snapshot, checking overlays topmost-first.
    pub fn performAccessibilityPress(
        self: *const OverlayStack,
        input: *element.InputState,
        main_frame: *const element.FrameState,
        id: element.ElementId,
    ) bool {
        const modal_index = self.topmostModalIndex();
        const first_overlay = modal_index orelse 0;

        var i = self.layers.items.len;
        while (i > first_overlay) {
            i -= 1;
            if (input.performAccessibilityPress(&self.layers.items[i].frame, id)) return true;
        }

        if (modal_index == null) {
            return input.performAccessibilityPress(main_frame, id);
        }
        return false;
    }

    fn topmostModalIndex(self: *const OverlayStack) ?usize {
        var result: ?usize = null;
        for (self.layers.items, 0..) |layer, i| {
            if (layer.entry.modal) result = i;
        }
        return result;
    }
};

test "overlay stack sorts by z_index" {
    var stack = OverlayStack.init(std.testing.allocator);

    const render = struct {
        fn empty(_: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
            const d = @import("elements/div.zig").div(arena).sizePx(10, 10);
            return d.any();
        }
    }.empty;

    stack.beginFrame();
    try stack.push(.{ .id = 1, .z_index = 10, .render = render });
    try stack.push(.{ .id = 2, .z_index = 0, .render = render });

    var engine = layout.LayoutEngine.init();
    defer engine.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try stack.build(arena_state.allocator(), &engine, .{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(usize, 2), stack.layers.items.len);
    try std.testing.expectEqual(@as(i32, 0), stack.layers.items[0].entry.z_index);
    try std.testing.expectEqual(@as(i32, 10), stack.layers.items[1].entry.z_index);
    stack.discardBuiltLayers();
    stack.pending.deinit(std.testing.allocator);
    stack.layers.deinit(std.testing.allocator);
}

const TestA11yRenderCtx = struct {
    id: []const u8,
    role: a11y_mod.Role = .button,
    press_count: ?*u32 = null,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.press_count.?.* += 1;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        var node = @import("elements/div.zig").div(arena)
            .withId(self.id)
            .sizePx(10, 10)
            .interactive()
            .role(self.role);
        if (self.press_count != null) node = node.onClick(self, onClick);
        return node.any();
    }
};

test "accessibility snapshot includes main and non-modal overlays" {
    var stack = OverlayStack.init(std.testing.allocator);

    var overlay_ctx = TestA11yRenderCtx{ .id = "tooltip", .role = .tooltip };
    try stack.push(.{
        .id = overlayId("tooltip"),
        .z_index = 10,
        .modal = false,
        .ctx = &overlay_ctx,
        .render = TestA11yRenderCtx.render,
    });

    var engine = layout.LayoutEngine.init();
    defer engine.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    defer stack.deinit();
    try stack.build(arena_state.allocator(), &engine, .{ .width = 100, .height = 100 });

    const main_id = element.elementId("main");
    const main_nodes = [_]a11y_mod.Node{.{ .id = main_id, .role = .button }};
    var snapshot: std.ArrayList(a11y_mod.Node) = .empty;
    defer snapshot.deinit(std.testing.allocator);
    try stack.appendAccessibilityNodes(&main_nodes, &snapshot, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(main_id, snapshot.items[0].id);
    try std.testing.expectEqual(element.elementId("tooltip"), snapshot.items[1].id);
}

test "accessibility snapshot handles empty input and preserves hierarchy" {
    var stack = OverlayStack.init(std.testing.allocator);
    defer stack.deinit();

    var snapshot: std.ArrayList(a11y_mod.Node) = .empty;
    defer snapshot.deinit(std.testing.allocator);
    try stack.appendAccessibilityNodes(&.{}, &snapshot, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.items.len);

    const parent_id = element.elementId("parent");
    const child_id = element.elementId("child");
    const main_nodes = [_]a11y_mod.Node{
        .{ .id = parent_id, .role = .dialog },
        .{ .id = child_id, .role = .button, .parent_id = parent_id },
    };
    try stack.appendAccessibilityNodes(&main_nodes, &snapshot, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(parent_id, snapshot.items[1].parent_id.?);
}

test "accessibility snapshot starts at the topmost modal" {
    var stack = OverlayStack.init(std.testing.allocator);

    var lower_ctx = TestA11yRenderCtx{ .id = "lower" };
    var modal_ctx = TestA11yRenderCtx{ .id = "modal", .role = .dialog };
    var upper_ctx = TestA11yRenderCtx{ .id = "upper", .role = .tooltip };
    try stack.push(.{
        .id = overlayId("lower"),
        .z_index = 0,
        .modal = false,
        .ctx = &lower_ctx,
        .render = TestA11yRenderCtx.render,
    });
    try stack.push(.{
        .id = overlayId("modal"),
        .z_index = 10,
        .modal = true,
        .ctx = &modal_ctx,
        .render = TestA11yRenderCtx.render,
    });
    try stack.push(.{
        .id = overlayId("upper"),
        .z_index = 20,
        .modal = false,
        .ctx = &upper_ctx,
        .render = TestA11yRenderCtx.render,
    });

    var engine = layout.LayoutEngine.init();
    defer engine.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    defer stack.deinit();
    try stack.build(arena_state.allocator(), &engine, .{ .width = 100, .height = 100 });

    const main_nodes = [_]a11y_mod.Node{.{
        .id = element.elementId("main"),
        .role = .button,
    }};
    var snapshot: std.ArrayList(a11y_mod.Node) = .empty;
    defer snapshot.deinit(std.testing.allocator);
    try stack.appendAccessibilityNodes(&main_nodes, &snapshot, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(element.elementId("modal"), snapshot.items[0].id);
    try std.testing.expectEqual(element.elementId("upper"), snapshot.items[1].id);
}

test "accessibility press routes to an overlay hitbox" {
    var stack = OverlayStack.init(std.testing.allocator);
    var press_count: u32 = 0;
    var overlay_ctx = TestA11yRenderCtx{
        .id = "overlay-action",
        .press_count = &press_count,
    };
    try stack.push(.{
        .id = overlayId("overlay-action"),
        .modal = true,
        .ctx = &overlay_ctx,
        .render = TestA11yRenderCtx.render,
    });

    var engine = layout.LayoutEngine.init();
    defer engine.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    defer stack.deinit();
    try stack.build(arena_state.allocator(), &engine, .{ .width = 100, .height = 100 });

    var input = element.InputState{};
    var main_frame = element.FrameState.init(std.testing.allocator);
    defer main_frame.deinit();
    var main_press_count: u32 = 0;
    var main_ctx = TestA11yRenderCtx{
        .id = "main-action",
        .press_count = &main_press_count,
    };
    try main_frame.addHitbox(.{
        .id = element.elementId("main-action"),
        .bounds = .{ .size = .{ .width = 10, .height = 10 } },
        .on_click = .{ .ctx = &main_ctx, .func = TestA11yRenderCtx.onClick },
    });

    try std.testing.expect(!stack.performAccessibilityPress(
        &input,
        &main_frame,
        element.elementId("main-action"),
    ));
    try std.testing.expectEqual(@as(u32, 0), main_press_count);
    try std.testing.expect(stack.performAccessibilityPress(
        &input,
        &main_frame,
        element.elementId("overlay-action"),
    ));
    try std.testing.expectEqual(@as(u32, 1), press_count);
}
