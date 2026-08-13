//! Headless test harness: runs the full frame pipeline (build → layout →
//! prepaint → paint) without a window or GPU, and dispatches synthetic
//! input. Used by component behavior tests (and usable by downstream
//! applications for their own UI tests).

const std = @import("std");
const geometry = @import("geometry.zig");
const layout = @import("layout/layout.zig");
const element = @import("element.zig");
const scene_mod = @import("scene.zig");
const platform = @import("platform.zig");
const app_mod = @import("app.zig");
const overlay_mod = @import("overlay.zig");
const hotkey_mod = @import("hotkey.zig");
const a11y_mod = @import("a11y.zig");

const Pixels = geometry.Pixels;
const Size = geometry.Size;
const Point = geometry.Point;

/// Builds the frame's root element. `ctx` is the harness user's state;
/// element allocations must come from `arena`. Handler `ctx` pointers must
/// NOT point into the arena (it resets every frame) — point at app entities
/// or other stable state instead.
pub const RenderFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *Harness) anyerror!element.Element;

pub const Harness = struct {
    gpa: std.mem.Allocator,
    app: app_mod.App,
    engine: layout.LayoutEngine,
    arena_state: std.heap.ArenaAllocator,
    frame: element.FrameState,
    input: element.InputState,
    scene: scene_mod.Scene,
    overlays: overlay_mod.OverlayStack,
    hotkeys: hotkey_mod.HotkeyRouter = .{},
    root_node: ?*layout.Node = null,
    viewport: Size(Pixels),
    render_ctx: ?*anyopaque = null,
    render_fn: ?RenderFn = null,
    frame_count: u64 = 0,
    /// Whether the most recent `dispatch` triggered a re-render.
    last_dispatch_redraw: bool = false,

    pub fn init(gpa: std.mem.Allocator, viewport: Size(Pixels)) Harness {
        return .{
            .gpa = gpa,
            .app = app_mod.App.init(gpa),
            .engine = layout.LayoutEngine.init(),
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .frame = element.FrameState.init(gpa),
            .input = .{},
            .scene = scene_mod.Scene.init(gpa),
            .overlays = overlay_mod.OverlayStack.init(gpa),
            .viewport = viewport,
        };
    }

    pub fn deinit(self: *Harness) void {
        if (self.root_node) |node| node.freeRecursive();
        self.overlays.deinit();
        self.scene.deinit();
        self.frame.deinit();
        self.engine.deinit();
        self.arena_state.deinit();
        self.app.deinit();
    }

    pub fn setRoot(self: *Harness, ctx: ?*anyopaque, render_fn: RenderFn) !void {
        self.render_ctx = ctx;
        self.render_fn = render_fn;
        try self.renderFrame();
    }

    /// Run one full frame: rebuild elements, layout, prepaint, paint.
    pub fn renderFrame(self: *Harness) !void {
        const render_fn = self.render_fn orelse return error.NoRootSet;

        if (self.root_node) |node| {
            node.freeRecursive();
            self.root_node = null;
        }
        self.overlays.discardBuiltLayers();
        _ = self.arena_state.reset(.retain_capacity);
        self.frame.clear();
        self.scene.clear();
        self.overlays.beginFrame();

        const arena = self.arena_state.allocator();
        const root = try render_fn(self.render_ctx, arena, self);

        var layout_pass = element.LayoutPass{ .arena = arena, .engine = &self.engine };
        const root_node = try root.requestLayout(&layout_pass);
        self.root_node = root_node;
        self.engine.computeLayout(root_node, self.viewport.width, self.viewport.height);

        var prepaint_pass = element.PrepaintPass{ .arena = arena, .frame = &self.frame };
        try root.prepaint(&prepaint_pass, .{});

        var paint_pass = element.PaintPass{ .scene = &self.scene };
        try root.paint(&paint_pass);

        try self.overlays.build(arena, &self.engine, self.viewport);
        try self.overlays.paint(&self.scene);

        self.frame_count += 1;
    }

    /// Dispatch one input event, flush entity effects, and re-render if any
    /// entity notified.
    pub fn dispatch(self: *Harness, event: platform.InputEvent) !void {
        self.last_dispatch_redraw = false;
        const overlay_handled = self.overlays.dispatch(&self.input, event);
        var consumed = overlay_handled;
        if (!consumed and event == .key_down) {
            consumed = self.hotkeys.dispatch(event.key_down);
        }
        if (!consumed) {
            _ = self.input.dispatch(&self.frame, event);
        }
        self.app.flushEffects();
        if (self.app.needs_redraw) {
            self.app.needs_redraw = false;
            self.last_dispatch_redraw = true;
            try self.renderFrame();
            _ = self.input.updateHover(&self.frame);
        }
    }

    // ------------------------------------------------------------------
    // Convenience input synthesis
    // ------------------------------------------------------------------

    pub fn moveMouse(self: *Harness, x: Pixels, y: Pixels) !void {
        try self.dispatch(.{ .mouse_moved = .{ .position = .{ .x = x, .y = y } } });
    }

    pub fn click(self: *Harness, x: Pixels, y: Pixels) !void {
        try self.dispatch(.{ .mouse_down = .{ .button = .left, .position = .{ .x = x, .y = y } } });
        try self.dispatch(.{ .mouse_up = .{ .button = .left, .position = .{ .x = x, .y = y } } });
    }

    pub fn rightClick(self: *Harness, x: Pixels, y: Pixels) !void {
        try self.dispatch(.{ .mouse_down = .{ .button = .right, .position = .{ .x = x, .y = y } } });
        try self.dispatch(.{ .mouse_up = .{ .button = .right, .position = .{ .x = x, .y = y } } });
    }

    pub fn keyDown(self: *Harness, key: platform.Key) !void {
        try self.dispatch(.{ .key_down = .{ .key = key } });
    }

    pub fn keyDownWith(self: *Harness, key: platform.Key, modifiers: platform.Modifiers) !void {
        try self.dispatch(.{ .key_down = .{ .key = key, .modifiers = modifiers } });
    }

    pub fn textInput(self: *Harness, text: []const u8) !void {
        try self.dispatch(.{ .text_input = .{ .text = text } });
    }

    pub fn compositionStart(self: *Harness) !void {
        try self.dispatch(.composition_start);
    }

    pub fn compositionUpdate(self: *Harness, text: []const u8) !void {
        try self.compositionUpdateWithCursor(text, -1);
    }

    pub fn compositionUpdateWithCursor(self: *Harness, text: []const u8, cursor: i32) !void {
        try self.dispatch(.{ .composition_update = .{ .text = text, .cursor = cursor } });
    }

    pub fn compositionEnd(self: *Harness) !void {
        try self.dispatch(.composition_end);
    }

    /// Set the app in-memory clipboard (for copy/paste tests).
    pub fn setClipboard(self: *Harness, text: []const u8) !void {
        try self.app.clipboard.setText(text);
    }

    pub fn clipboardText(self: *const Harness) []const u8 {
        return self.app.clipboard.getText();
    }

    /// Press Tab until the given focus id is focused (or fail after one
    /// full cycle).
    pub fn focusById(self: *Harness, focus_id: element.FocusId) !void {
        const max_presses = self.frame.focusables.items.len + 1;
        var presses: usize = 0;
        while (presses < max_presses) : (presses += 1) {
            if (self.input.isFocused(focus_id)) return;
            try self.keyDown(.tab);
        }
        return error.FocusTargetNotFound;
    }

    // ------------------------------------------------------------------
    // Assertion helpers
    // ------------------------------------------------------------------

    /// Bounds of the hitbox registered with the given element id
    /// (main frame first, then overlay layers topmost-first).
    pub fn hitboxBounds(self: *const Harness, id: element.ElementId) ?geometry.Bounds(Pixels) {
        for (self.frame.hitboxes.items) |hitbox| {
            if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
        }
        var i = self.overlays.layers.items.len;
        while (i > 0) {
            i -= 1;
            for (self.overlays.layers.items[i].frame.hitboxes.items) |hitbox| {
                if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
            }
        }
        return null;
    }

    pub fn centerOf(self: *const Harness, id: element.ElementId) ?Point(Pixels) {
        const bounds = self.hitboxBounds(id) orelse return null;
        return .{
            .x = bounds.origin.x + bounds.size.width / 2,
            .y = bounds.origin.y + bounds.size.height / 2,
        };
    }

    pub fn clickOn(self: *Harness, id_name: []const u8) !void {
        const center = self.centerOf(element.elementId(id_name)) orelse return error.ElementNotFound;
        try self.click(center.x, center.y);
    }

    /// Simulate VoiceOver / AXPress for a registered hitbox id.
    pub fn a11yPressOn(self: *Harness, id_name: []const u8) !void {
        const id = element.elementId(id_name);
        const pressed = self.overlays.performAccessibilityPress(&self.input, &self.frame, id);
        if (!pressed) return error.ElementNotFound;

        self.app.flushEffects();
        if (self.app.needs_redraw) {
            self.app.needs_redraw = false;
            try self.renderFrame();
            _ = self.input.updateHover(&self.frame);
        }
    }

    /// Simulate AXIncrement / AXDecrement for a focusable control (e.g. slider).
    pub fn a11yAdjustOn(self: *Harness, id_name: []const u8, increment: bool) !void {
        const id = element.elementId(id_name);
        const adjusted = self.overlays.performAccessibilityAdjust(&self.input, &self.frame, id, increment);
        if (!adjusted) return error.ElementNotFound;

        self.app.flushEffects();
        if (self.app.needs_redraw) {
            self.app.needs_redraw = false;
            try self.renderFrame();
            _ = self.input.updateHover(&self.frame);
        }
    }

    pub fn a11yIncrementOn(self: *Harness, id_name: []const u8) !void {
        try self.a11yAdjustOn(id_name, true);
    }

    pub fn a11yDecrementOn(self: *Harness, id_name: []const u8) !void {
        try self.a11yAdjustOn(id_name, false);
    }

    /// Simulate AX `setAccessibilityValue:` for an editable text control.
    pub fn a11ySetValueOn(self: *Harness, id_name: []const u8, text: []const u8) !void {
        const id = element.elementId(id_name);
        const set = self.overlays.performAccessibilitySetValue(&self.input, &self.frame, id, text);
        if (!set) return error.ElementNotFound;

        self.app.flushEffects();
        if (self.app.needs_redraw) {
            self.app.needs_redraw = false;
            try self.renderFrame();
            _ = self.input.updateHover(&self.frame);
        }
    }

    pub fn hoverOver(self: *Harness, id_name: []const u8) !void {
        const center = self.centerOf(element.elementId(id_name)) orelse return error.ElementNotFound;
        try self.moveMouse(center.x, center.y);
    }

    // ------------------------------------------------------------------
    // Accessibility helpers
    // ------------------------------------------------------------------

    pub fn a11yNode(self: *const Harness, id_name: []const u8) ?*const a11y_mod.Node {
        const id = element.elementId(id_name);
        if (a11y_mod.findById(&self.frame, id)) |node| return node;
        var i = self.overlays.layers.items.len;
        while (i > 0) {
            i -= 1;
            if (a11y_mod.findById(&self.overlays.layers.items[i].frame, id)) |node| return node;
        }
        return null;
    }

    pub fn a11yRole(self: *const Harness, id_name: []const u8) ?a11y_mod.Role {
        const node = self.a11yNode(id_name) orelse return null;
        return node.role;
    }

    pub fn a11yName(self: *const Harness, id_name: []const u8) ?[]const u8 {
        const node = self.a11yNode(id_name) orelse return null;
        if (a11y_mod.findById(&self.frame, node.id) != null) {
            return a11y_mod.resolveNameInFrame(&self.frame, node);
        }
        var i = self.overlays.layers.items.len;
        while (i > 0) {
            i -= 1;
            const layer = &self.overlays.layers.items[i];
            if (a11y_mod.findById(&layer.frame, node.id) != null) {
                return a11y_mod.resolveNameInFrame(&layer.frame, node);
            }
        }
        return a11y_mod.resolveName(node);
    }

    /// Tab-order element ids that also have a11y nodes in the main frame.
    pub fn a11yFocusOrder(self: *const Harness, allocator: std.mem.Allocator) ![]element.ElementId {
        var list: std.ArrayList(element.ElementId) = .empty;
        errdefer list.deinit(allocator);
        try a11y_mod.collectFocusOrder(&self.frame, &list, allocator);
        return try list.toOwnedSlice(allocator);
    }

    pub fn a11yChecked(self: *const Harness, id_name: []const u8) ?bool {
        const node = self.a11yNode(id_name) orelse return null;
        return node.checked;
    }

    pub fn a11ySelected(self: *const Harness, id_name: []const u8) ?bool {
        const node = self.a11yNode(id_name) orelse return null;
        return node.selected;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const color = @import("color.zig");
const div_mod = @import("elements/div.zig");

const CounterApp = struct {
    counter: app_mod.Entity(Counter),
    harness: *Harness = undefined,

    const Counter = struct { count: i32 = 0 };

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *Harness) anyerror!element.Element {
        const self: *CounterApp = @ptrCast(@alignCast(ctx.?));
        const count = harness.app.read(Counter, self.counter).count;

        const label_height: Pixels = if (count > 0) 40 else 20;
        const root = div_mod.div(arena)
            .flexCol()
            .sizePx(200, 200)
            .childDiv(div_mod.div(arena)
            .withId("increment")
            .sizePx(100, label_height)
            .bg(color.Rgba.red)
            .onClick(self, incrementHandler));
        return root.any();
    }

    fn incrementHandler(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *CounterApp = @ptrCast(@alignCast(ctx.?));
        self.harness.app.read(Counter, self.counter).count += 1;
        self.harness.app.notify(self.counter.id);
    }
};

test "harness renders, dispatches clicks, and re-renders on notify" {
    var harness = Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var counter_app = CounterApp{
        .counter = try harness.app.new(CounterApp.Counter, .{}),
    };
    counter_app.harness = &harness;

    try harness.setRoot(&counter_app, CounterApp.render);
    try std.testing.expectEqual(@as(u64, 1), harness.frame_count);

    // Initial height is 20.
    const bounds_before = harness.hitboxBounds(element.elementId("increment")).?;
    try std.testing.expectEqual(@as(Pixels, 20), bounds_before.size.height);

    try harness.clickOn("increment");
    try std.testing.expectEqual(@as(i32, 1), harness.app.read(CounterApp.Counter, counter_app.counter).count);
    try std.testing.expect(harness.last_dispatch_redraw);

    // State change triggered a re-render with the new layout.
    try std.testing.expect(harness.frame_count > 1);
    const bounds_after = harness.hitboxBounds(element.elementId("increment")).?;
    try std.testing.expectEqual(@as(Pixels, 40), bounds_after.size.height);
}
