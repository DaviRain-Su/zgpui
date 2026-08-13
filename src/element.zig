//! Element system, modeled on gpui's `element.rs`.
//!
//! Elements are built fresh each frame (from a frame arena) and go through
//! three phases:
//!
//! 1. `requestLayout` — build the flexbox node tree
//! 2. `prepaint`      — resolve absolute bounds, register hitboxes/focus
//! 3. `paint`         — emit scene primitives
//!
//! `FrameState` holds per-frame hitboxes and listeners; `InputState` holds
//! the persistent state (hover, mouse-down target, focus) that survives
//! across frames and dispatches platform input events to the current frame.

const std = @import("std");
const geometry = @import("geometry.zig");
const layout = @import("layout/layout.zig");
const scene_mod = @import("scene.zig");
const platform = @import("platform.zig");
const a11y_mod = @import("a11y.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Scene = scene_mod.Scene;

// ---------------------------------------------------------------------------
// Element interface
// ---------------------------------------------------------------------------

pub const Element = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request_layout: *const fn (ptr: *anyopaque, pass: *LayoutPass) anyerror!*layout.Node,
        prepaint: *const fn (ptr: *anyopaque, pass: *PrepaintPass, parent_origin: Point(Pixels)) anyerror!void,
        paint: *const fn (ptr: *anyopaque, pass: *PaintPass) anyerror!void,
    };

    pub fn requestLayout(self: Element, pass: *LayoutPass) !*layout.Node {
        return self.vtable.request_layout(self.ptr, pass);
    }

    pub fn prepaint(self: Element, pass: *PrepaintPass, parent_origin: Point(Pixels)) !void {
        return self.vtable.prepaint(self.ptr, pass, parent_origin);
    }

    pub fn paint(self: Element, pass: *PaintPass) !void {
        return self.vtable.paint(self.ptr, pass);
    }
};

/// Build an `Element` from any type that declares `requestLayout` / `prepaint` /
/// `paint` with the standard signatures. Uses comptime reflection (`@hasDecl`)
/// so each concrete element type gets a monomorphized vtable with zero runtime
/// type lookup.
pub fn asElement(comptime T: type, ptr: *T) Element {
    comptime {
        if (!@hasDecl(T, "requestLayout")) @compileError(@typeName(T) ++ " missing requestLayout");
        if (!@hasDecl(T, "prepaint")) @compileError(@typeName(T) ++ " missing prepaint");
        if (!@hasDecl(T, "paint")) @compileError(@typeName(T) ++ " missing paint");
    }
    const Erased = struct {
        fn requestLayout(p: *anyopaque, pass: *LayoutPass) anyerror!*layout.Node {
            const self: *T = @ptrCast(@alignCast(p));
            return self.requestLayout(pass);
        }
        fn prepaint(p: *anyopaque, pass: *PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
            const self: *T = @ptrCast(@alignCast(p));
            return self.prepaint(pass, parent_origin);
        }
        fn paint(p: *anyopaque, pass: *PaintPass) anyerror!void {
            const self: *T = @ptrCast(@alignCast(p));
            return self.paint(pass);
        }
        const vtable = Element.VTable{
            .request_layout = requestLayout,
            .prepaint = prepaint,
            .paint = paint,
        };
    };
    return .{ .ptr = ptr, .vtable = &Erased.vtable };
}

// ---------------------------------------------------------------------------
// Passes
// ---------------------------------------------------------------------------

pub const LayoutPass = struct {
    /// Frame arena; allocations live until the next frame is built.
    arena: std.mem.Allocator,
    engine: *layout.LayoutEngine,
};

pub const PrepaintPass = struct {
    arena: std.mem.Allocator,
    frame: *FrameState,
    /// Nearest ancestor that registered an a11y node (for hierarchy).
    a11y_parent: ?ElementId = null,
};

pub const PaintPass = struct {
    scene: *Scene,
    /// When set, focused text elements write the caret anchor here for OS IME
    /// candidate positioning (logical px, top-left, window content coords).
    ime_position: ?*Point(Pixels) = null,
    /// Current clip rect (logical px). Zero size = unclipped.
    clip_bounds: Bounds(Pixels) = .{},

    pub fn pushClip(self: *PaintPass, bounds: Bounds(Pixels)) Bounds(Pixels) {
        const previous = self.clip_bounds;
        self.clip_bounds = if (previous.isEmpty()) bounds else previous.intersect(bounds);
        return previous;
    }

    pub fn popClip(self: *PaintPass, previous: Bounds(Pixels)) void {
        self.clip_bounds = previous;
    }

    pub fn clipF(self: *const PaintPass) scene_mod.BoundsF {
        return scene_mod.BoundsF.from(self.clip_bounds);
    }
};

// ---------------------------------------------------------------------------
// Frame state: hitboxes, listeners, focus registrations (rebuilt each frame)
// ---------------------------------------------------------------------------

/// Stable identity for interactive elements across frames. Elements that
/// want hover/click synthesis or focus must provide one.
pub const ElementId = u64;

pub fn elementId(name: []const u8) ElementId {
    return std.hash.Wyhash.hash(0x26701, name);
}

pub const FocusId = u64;

pub const MouseHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, event: *const platform.MouseButtonEvent) void,
};

pub const HoverHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, hovered: bool) void,
};

pub const KeyHandler = struct {
    ctx: ?*anyopaque = null,
    /// Return true if the event was handled (stops propagation).
    func: *const fn (ctx: ?*anyopaque, event: *const platform.KeyEvent) bool,
};

pub const TextInputHandler = struct {
    ctx: ?*anyopaque = null,
    /// Return true if the event was handled (stops propagation).
    func: *const fn (ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool,
};

pub const CompositionHandler = struct {
    ctx: ?*anyopaque = null,
    /// Return true if the event was handled (stops propagation).
    func: *const fn (ctx: ?*anyopaque, event: CompositionDispatchEvent) bool,

    pub const CompositionDispatchEvent = union(enum) {
        start: void,
        update: platform.CompositionEvent,
        end: void,
    };
};

pub const ScrollHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, event: *const platform.ScrollEvent) void,
};

pub const Hitbox = struct {
    id: ?ElementId,
    bounds: Bounds(Pixels),
    on_mouse_down: ?MouseHandler = null,
    on_mouse_up: ?MouseHandler = null,
    on_click: ?MouseHandler = null,
    on_hover: ?HoverHandler = null,
    on_scroll: ?ScrollHandler = null,
};

pub const FocusEntry = struct {
    id: FocusId,
    on_key: ?KeyHandler = null,
    on_text_input: ?TextInputHandler = null,
    on_composition: ?CompositionHandler = null,
    /// UTF-8 `[start, end)` selection for AX `setAccessibilitySelectedTextRange:`.
    on_a11y_set_selection: ?A11ySelectionHandler = null,
};

pub const A11ySelectionHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, start: usize, end: usize) bool,
};

pub const FrameState = struct {
    allocator: std.mem.Allocator,
    /// In paint order: later entries are on top.
    hitboxes: std.ArrayList(Hitbox),
    /// In registration (tab) order.
    focusables: std.ArrayList(FocusEntry),
    /// Accessibility nodes (document/prepaint order), rebuilt each frame.
    a11y: std.ArrayList(a11y_mod.Node),

    pub fn init(allocator: std.mem.Allocator) FrameState {
        return .{
            .allocator = allocator,
            .hitboxes = .empty,
            .focusables = .empty,
            .a11y = .empty,
        };
    }

    pub fn deinit(self: *FrameState) void {
        self.hitboxes.deinit(self.allocator);
        self.focusables.deinit(self.allocator);
        self.a11y.deinit(self.allocator);
    }

    pub fn clear(self: *FrameState) void {
        self.hitboxes.clearRetainingCapacity();
        self.focusables.clearRetainingCapacity();
        self.a11y.clearRetainingCapacity();
    }

    pub fn addHitbox(self: *FrameState, hitbox: Hitbox) !void {
        try self.hitboxes.append(self.allocator, hitbox);
    }

    pub fn addFocusable(self: *FrameState, entry: FocusEntry) !void {
        try self.focusables.append(self.allocator, entry);
    }

    pub fn registerA11y(self: *FrameState, node: a11y_mod.Node) !void {
        try self.a11y.append(self.allocator, node);
    }

    /// Topmost hitbox containing `point`.
    pub fn hitTest(self: *const FrameState, point: Point(Pixels)) ?*const Hitbox {
        var i = self.hitboxes.items.len;
        while (i > 0) {
            i -= 1;
            const hitbox = &self.hitboxes.items[i];
            if (hitbox.bounds.contains(point)) return hitbox;
        }
        return null;
    }

    /// Topmost hitbox containing `point` that has an `on_scroll` handler
    /// (scroll events bubble through non-scrollable children).
    pub fn hitTestScroll(self: *const FrameState, point: Point(Pixels)) ?*const Hitbox {
        var i = self.hitboxes.items.len;
        while (i > 0) {
            i -= 1;
            const hitbox = &self.hitboxes.items[i];
            if (hitbox.on_scroll != null and hitbox.bounds.contains(point)) return hitbox;
        }
        return null;
    }

    fn focusIndex(self: *const FrameState, id: FocusId) ?usize {
        for (self.focusables.items, 0..) |entry, i| {
            if (entry.id == id) return i;
        }
        return null;
    }

    /// True when `id` is registered in this frame's tab order.
    pub fn hasFocusable(self: *const FrameState, id: FocusId) bool {
        return self.focusIndex(id) != null;
    }
};

// ---------------------------------------------------------------------------
// Input state: persists across frames, dispatches events into a FrameState
// ---------------------------------------------------------------------------

pub const InputState = struct {
    mouse_position: Point(Pixels) = .{},
    hovered: ?ElementId = null,
    mouse_down_on: ?ElementId = null,
    focused: ?FocusId = null,
    /// True after focus moved via Tab/keyboard; false after pointer-driven focus.
    /// Mirrors CSS `:focus-visible` — style rings when this is true and the
    /// element is focused.
    focus_visible: bool = false,

    /// Dispatch a platform input event against the current frame.
    /// Returns true if any listener consumed the event.
    pub fn dispatch(self: *InputState, frame: *const FrameState, event: platform.InputEvent) bool {
        switch (event) {
            .mouse_moved => |move| {
                self.mouse_position = move.position;
                return self.updateHover(frame);
            },
            .mouse_exited => {
                self.setHovered(frame, null);
                return false;
            },
            .mouse_down => |down| {
                self.mouse_position = down.position;
                const hitbox = frame.hitTest(down.position) orelse {
                    self.mouse_down_on = null;
                    return false;
                };
                self.mouse_down_on = hitbox.id;
                var handled = false;
                if (hitbox.on_mouse_down) |handler| {
                    handler.func(handler.ctx, &down);
                    handled = true;
                }
                if (hitbox.id) |element_id| {
                    if (frame.hasFocusable(element_id)) {
                        self.focusFromPointer(element_id);
                        handled = true;
                    }
                }
                if (handled) return true;
                return hitbox.on_click != null;
            },
            .mouse_up => |up| {
                self.mouse_position = up.position;
                const hitbox = frame.hitTest(up.position);
                var handled = false;
                if (hitbox) |hb| {
                    if (hb.on_mouse_up) |handler| {
                        handler.func(handler.ctx, &up);
                        handled = true;
                    }
                    // Click: released over the same stable element the press
                    // started on.
                    if (hb.on_click) |handler| {
                        if (hb.id != null and self.mouse_down_on != null and
                            hb.id.? == self.mouse_down_on.?)
                        {
                            handler.func(handler.ctx, &up);
                            handled = true;
                        }
                    }
                }
                self.mouse_down_on = null;
                return handled;
            },
            .scroll => |scroll| {
                const hitbox = frame.hitTestScroll(scroll.position) orelse return false;
                if (hitbox.on_scroll) |handler| {
                    handler.func(handler.ctx, &scroll);
                    return true;
                }
                return false;
            },
            .key_down => |key| {
                if (key.key == .tab and !key.modifiers.control and !key.modifiers.command) {
                    self.moveFocus(frame, if (key.modifiers.shift) .backward else .forward);
                    return true;
                }
                if (self.focused) |focus_id| {
                    if (frame.focusIndex(focus_id)) |i| {
                        if (frame.focusables.items[i].on_key) |handler| {
                            return handler.func(handler.ctx, &key);
                        }
                    }
                }
                return false;
            },
            .text_input => |text| {
                if (self.focused) |focus_id| {
                    if (frame.focusIndex(focus_id)) |i| {
                        if (frame.focusables.items[i].on_text_input) |handler| {
                            return handler.func(handler.ctx, &text);
                        }
                    }
                }
                return false;
            },
            .composition_start => {
                if (self.focused) |focus_id| {
                    if (frame.focusIndex(focus_id)) |i| {
                        if (frame.focusables.items[i].on_composition) |handler| {
                            return handler.func(handler.ctx, .{ .start = {} });
                        }
                    }
                }
                return false;
            },
            .composition_update => |update| {
                if (self.focused) |focus_id| {
                    if (frame.focusIndex(focus_id)) |i| {
                        if (frame.focusables.items[i].on_composition) |handler| {
                            return handler.func(handler.ctx, .{ .update = update });
                        }
                    }
                }
                return false;
            },
            .composition_end => {
                if (self.focused) |focus_id| {
                    if (frame.focusIndex(focus_id)) |i| {
                        if (frame.focusables.items[i].on_composition) |handler| {
                            return handler.func(handler.ctx, .{ .end = {} });
                        }
                    }
                }
                return false;
            },
            .key_up, .modifiers_changed => return false,
        }
    }

    /// Re-run hover detection (e.g. after a frame rebuild under a still
    /// mouse). Returns true if the hovered element changed.
    pub fn updateHover(self: *InputState, frame: *const FrameState) bool {
        const hitbox = frame.hitTest(self.mouse_position);
        const target: ?ElementId = if (hitbox) |hb| hb.id else null;
        if (!idEql(self.hovered, target)) {
            self.setHovered(frame, target);
            return true;
        }
        return false;
    }

    /// Set keyboard focus to `id`. Does not change [`focus_visible`](focus_visible);
    /// use [`focusFromPointer`](focusFromPointer) when focus comes from the
    /// pointing device.
    pub fn focus(self: *InputState, id: FocusId) void {
        self.focused = id;
    }

    /// Focus from a pointer interaction (mouse/touch). Sets `focus_visible` false.
    pub fn focusFromPointer(self: *InputState, id: FocusId) void {
        self.focused = id;
        self.focus_visible = false;
    }

    pub fn blur(self: *InputState) void {
        self.focused = null;
        self.focus_visible = false;
    }

    pub fn isFocused(self: *const InputState, id: FocusId) bool {
        return self.focused != null and self.focused.? == id;
    }

    pub fn isHovered(self: *const InputState, id: ElementId) bool {
        return self.hovered != null and self.hovered.? == id;
    }

    /// Invoke `on_click` for the hitbox with `id` (VoiceOver AXPress). Returns
    /// true when a click handler ran.
    pub fn performAccessibilityPress(self: *InputState, frame: *const FrameState, id: ElementId) bool {
        _ = self;
        const hitbox = findHitboxById(frame, id) orelse return false;
        if (hitbox.on_click) |handler| {
            const center = hitbox.bounds.center();
            var event = platform.MouseButtonEvent{
                .button = .left,
                .position = center,
                .click_count = 1,
            };
            handler.func(handler.ctx, &event);
            return true;
        }
        return false;
    }

    /// Focus `id` and synthesize Left/Right for AXIncrement/AXDecrement.
    pub fn performAccessibilityAdjust(
        self: *InputState,
        frame: *const FrameState,
        id: ElementId,
        increment: bool,
    ) bool {
        const index = frame.focusIndex(id) orelse return false;
        const handler = frame.focusables.items[index].on_key orelse return false;
        self.focused = id;
        self.focus_visible = true;
        var key = platform.KeyEvent{
            .key = if (increment) .right else .left,
        };
        return handler.func(handler.ctx, &key);
    }

    /// Focus `id` and replace its text via select-all + insert / delete.
    pub fn performAccessibilitySetValue(
        self: *InputState,
        frame: *const FrameState,
        id: ElementId,
        text: []const u8,
    ) bool {
        const node = a11y_mod.findById(frame, id) orelse return false;
        if (!node.editable or node.disabled or !a11y_mod.roleIsText(node.role)) return false;

        const index = frame.focusIndex(id) orelse return false;
        const entry = frame.focusables.items[index];
        const key_handler = entry.on_key orelse return false;
        const text_handler = entry.on_text_input orelse return false;

        self.focused = id;
        self.focus_visible = true;

        var select_all = platform.KeyEvent{
            .key = .a,
            .modifiers = .{ .command = true },
        };
        if (!key_handler.func(key_handler.ctx, &select_all)) return false;

        if (text.len == 0) {
            var backspace = platform.KeyEvent{ .key = .backspace };
            return key_handler.func(key_handler.ctx, &backspace);
        }

        var input_event = platform.TextInputEvent{ .text = text };
        return text_handler.func(text_handler.ctx, &input_event);
    }

    /// Focus `id` and replace the current selection (or insert at the caret).
    pub fn performAccessibilityReplaceSelectedText(
        self: *InputState,
        frame: *const FrameState,
        id: ElementId,
        text: []const u8,
    ) bool {
        const node = a11y_mod.findById(frame, id) orelse return false;
        if (!node.editable or node.disabled or !a11y_mod.roleIsText(node.role)) return false;

        const index = frame.focusIndex(id) orelse return false;
        const entry = frame.focusables.items[index];
        const key_handler = entry.on_key orelse return false;
        const text_handler = entry.on_text_input orelse return false;

        self.focused = id;
        self.focus_visible = true;

        if (text.len == 0) {
            const has_selection = if (node.selection_start) |start|
                if (node.selection_end) |end| end > start else false
            else
                false;
            if (!has_selection) return true;
            var backspace = platform.KeyEvent{ .key = .backspace };
            return key_handler.func(key_handler.ctx, &backspace);
        }

        var input_event = platform.TextInputEvent{ .text = text };
        return text_handler.func(text_handler.ctx, &input_event);
    }

    /// Focus `id` and set the UTF-8 selection range `[start, end)`.
    pub fn performAccessibilitySetSelectedRange(
        self: *InputState,
        frame: *const FrameState,
        id: ElementId,
        start: usize,
        end: usize,
    ) bool {
        const node = a11y_mod.findById(frame, id) orelse return false;
        if (!node.editable or node.disabled or !a11y_mod.roleIsText(node.role)) return false;
        const value = node.value_text orelse return false;
        if (start > end or end > value.len) return false;
        if (!isTextBoundary(value, start) or !isTextBoundary(value, end)) return false;

        const index = frame.focusIndex(id) orelse return false;
        const handler = frame.focusables.items[index].on_a11y_set_selection orelse return false;

        if (!handler.func(handler.ctx, start, end)) return false;
        self.focused = id;
        self.focus_visible = true;
        return true;
    }

    const FocusDirection = enum { forward, backward };

    fn moveFocus(self: *InputState, frame: *const FrameState, direction: FocusDirection) void {
        const items = frame.focusables.items;
        if (items.len == 0) {
            self.focused = null;
            self.focus_visible = false;
            return;
        }
        const current = if (self.focused) |focus_id| frame.focusIndex(focus_id) else null;
        const next_index: usize = switch (direction) {
            .forward => if (current) |i| (i + 1) % items.len else 0,
            .backward => if (current) |i| (i + items.len - 1) % items.len else items.len - 1,
        };
        self.focused = items[next_index].id;
        self.focus_visible = true;
    }

    fn setHovered(self: *InputState, frame: *const FrameState, target: ?ElementId) void {
        if (idEql(self.hovered, target)) return;

        if (self.hovered) |old| {
            if (findHitboxById(frame, old)) |hitbox| {
                if (hitbox.on_hover) |handler| handler.func(handler.ctx, false);
            }
        }
        self.hovered = target;
        if (target) |new| {
            if (findHitboxById(frame, new)) |hitbox| {
                if (hitbox.on_hover) |handler| handler.func(handler.ctx, true);
            }
        }
    }

    fn findHitboxById(frame: *const FrameState, id: ElementId) ?*const Hitbox {
        for (frame.hitboxes.items) |*hitbox| {
            if (hitbox.id != null and hitbox.id.? == id) return hitbox;
        }
        return null;
    }

    fn idEql(a: ?ElementId, b: ?ElementId) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.? == b.?;
    }
};

fn isTextBoundary(text: []const u8, offset: usize) bool {
    return offset <= text.len and
        (offset == 0 or offset == text.len or (text[offset] & 0xc0) != 0x80);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hit test returns topmost hitbox" {
    var frame = FrameState.init(std.testing.allocator);
    defer frame.deinit();

    try frame.addHitbox(.{
        .id = 1,
        .bounds = Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 100, .height = 100 }),
    });
    try frame.addHitbox(.{
        .id = 2,
        .bounds = Bounds(Pixels).init(.{ .x = 25, .y = 25 }, .{ .width = 50, .height = 50 }),
    });

    try std.testing.expectEqual(@as(?ElementId, 2), frame.hitTest(.{ .x = 50, .y = 50 }).?.id);
    try std.testing.expectEqual(@as(?ElementId, 1), frame.hitTest(.{ .x = 10, .y = 10 }).?.id);
    try std.testing.expect(frame.hitTest(.{ .x = 150, .y = 150 }) == null);
}

test "click synthesis requires press and release on same element" {
    var frame = FrameState.init(std.testing.allocator);
    defer frame.deinit();

    var clicks: u32 = 0;
    const on_click = MouseHandler{
        .ctx = &clicks,
        .func = struct {
            fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
                const count: *u32 = @ptrCast(@alignCast(ctx.?));
                count.* += 1;
            }
        }.onClick,
    };

    try frame.addHitbox(.{
        .id = elementId("button-a"),
        .bounds = Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 100, .height = 40 }),
        .on_click = on_click,
    });

    var input = InputState{};

    // Press and release inside: click.
    _ = input.dispatch(&frame, .{ .mouse_down = .{ .button = .left, .position = .{ .x = 10, .y = 10 } } });
    _ = input.dispatch(&frame, .{ .mouse_up = .{ .button = .left, .position = .{ .x = 20, .y = 20 } } });
    try std.testing.expectEqual(@as(u32, 1), clicks);

    // Press inside, release outside: no click.
    _ = input.dispatch(&frame, .{ .mouse_down = .{ .button = .left, .position = .{ .x = 10, .y = 10 } } });
    _ = input.dispatch(&frame, .{ .mouse_up = .{ .button = .left, .position = .{ .x = 300, .y = 300 } } });
    try std.testing.expectEqual(@as(u32, 1), clicks);
}

test "accessibility adjust dispatches directional keys to the target" {
    var frame = FrameState.init(std.testing.allocator);
    defer frame.deinit();

    var total: i32 = 0;
    const id = elementId("adjustable");
    try frame.addFocusable(.{
        .id = id,
        .on_key = .{
            .ctx = &total,
            .func = struct {
                fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
                    const value: *i32 = @ptrCast(@alignCast(ctx.?));
                    switch (event.key) {
                        .right => value.* += 1,
                        .left => value.* -= 1,
                        else => return false,
                    }
                    return true;
                }
            }.onKey,
        },
    });

    var input = InputState{};
    try std.testing.expect(input.performAccessibilityAdjust(&frame, id, true));
    try std.testing.expectEqual(@as(i32, 1), total);
    try std.testing.expect(input.performAccessibilityAdjust(&frame, id, false));
    try std.testing.expectEqual(@as(i32, 0), total);
    try std.testing.expect(!input.performAccessibilityAdjust(&frame, elementId("missing"), true));

    const passive_id = elementId("passive");
    try frame.addFocusable(.{ .id = passive_id });
    try std.testing.expect(!input.performAccessibilityAdjust(&frame, passive_id, true));
    try std.testing.expectEqual(id, input.focused.?);
}

test "accessibility set value replaces text through select-all insert" {
    var frame = FrameState.init(std.testing.allocator);
    defer frame.deinit();

    var buffer: [32]u8 = undefined;
    var len: usize = 0;
    const Ctx = struct {
        buffer: []u8,
        len: *usize,
        fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (event.key == .a and event.modifiers.command) return true;
            if (event.key == .backspace) {
                self.len.* = 0;
                return true;
            }
            return false;
        }
        fn onText(ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (event.text.len > self.buffer.len) return false;
            @memcpy(self.buffer[0..event.text.len], event.text);
            self.len.* = event.text.len;
            return true;
        }
    };
    var ctx = Ctx{ .buffer = &buffer, .len = &len };
    const id = elementId("field");
    try frame.registerA11y(.{
        .id = id,
        .role = .textbox,
        .editable = true,
        .value_text = "old",
    });
    try frame.addFocusable(.{
        .id = id,
        .on_key = .{ .ctx = &ctx, .func = Ctx.onKey },
        .on_text_input = .{ .ctx = &ctx, .func = Ctx.onText },
    });

    var input = InputState{};
    try std.testing.expect(input.performAccessibilitySetValue(&frame, id, "new"));
    try std.testing.expectEqualStrings("new", buffer[0..len]);
    try std.testing.expect(input.performAccessibilitySetValue(&frame, id, ""));
    try std.testing.expectEqual(@as(usize, 0), len);
    try std.testing.expect(!input.performAccessibilitySetValue(&frame, elementId("missing"), "x"));
}

test "accessibility replace selected text and set selected range" {
    var frame = FrameState.init(std.testing.allocator);
    defer frame.deinit();

    var buffer: [32]u8 = undefined;
    @memcpy(buffer[0..4], "abcd");
    var len: usize = 4;
    var sel_start: usize = 0;
    var sel_end: usize = 0;
    const Ctx = struct {
        buffer: []u8,
        len: *usize,
        sel_start: *usize,
        sel_end: *usize,
        fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (event.key == .backspace) {
                if (self.sel_end.* > self.sel_start.*) {
                    const after = self.buffer[self.sel_end.*..self.len.*];
                    std.mem.copyForwards(u8, self.buffer[self.sel_start.* .. self.sel_start.* + after.len], after);
                    self.len.* -= self.sel_end.* - self.sel_start.*;
                    self.sel_end.* = self.sel_start.*;
                }
                return true;
            }
            return false;
        }
        fn onText(ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.sel_end.* > self.sel_start.*) {
                const after = self.buffer[self.sel_end.*..self.len.*];
                std.mem.copyForwards(u8, self.buffer[self.sel_start.* .. self.sel_start.* + after.len], after);
                self.len.* -= self.sel_end.* - self.sel_start.*;
                self.sel_end.* = self.sel_start.*;
            }
            if (self.len.* + event.text.len > self.buffer.len) return false;
            const after = self.buffer[self.sel_start.*..self.len.*];
            var tmp: [32]u8 = undefined;
            @memcpy(tmp[0..after.len], after);
            @memcpy(self.buffer[self.sel_start.* .. self.sel_start.* + event.text.len], event.text);
            @memcpy(self.buffer[self.sel_start.* + event.text.len .. self.sel_start.* + event.text.len + after.len], tmp[0..after.len]);
            self.len.* += event.text.len;
            self.sel_start.* += event.text.len;
            self.sel_end.* = self.sel_start.*;
            return true;
        }
        fn onSel(ctx: ?*anyopaque, start: usize, end: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.sel_start.* = start;
            self.sel_end.* = end;
            return true;
        }
    };
    var ctx = Ctx{ .buffer = &buffer, .len = &len, .sel_start = &sel_start, .sel_end = &sel_end };
    const id = elementId("field");
    try frame.registerA11y(.{
        .id = id,
        .role = .textbox,
        .editable = true,
        .value_text = "abcd",
        .selection_start = 1,
        .selection_end = 3,
    });
    try frame.addFocusable(.{
        .id = id,
        .on_key = .{ .ctx = &ctx, .func = Ctx.onKey },
        .on_text_input = .{ .ctx = &ctx, .func = Ctx.onText },
        .on_a11y_set_selection = .{ .ctx = &ctx, .func = Ctx.onSel },
    });

    var input = InputState{};
    try std.testing.expect(input.performAccessibilitySetSelectedRange(&frame, id, 1, 3));
    try std.testing.expectEqual(@as(usize, 1), sel_start);
    try std.testing.expectEqual(@as(usize, 3), sel_end);
    try std.testing.expect(input.performAccessibilityReplaceSelectedText(&frame, id, "Z"));
    try std.testing.expectEqualStrings("aZd", buffer[0..len]);

    input.focused = elementId("previous-focus");
    try std.testing.expect(!input.performAccessibilitySetSelectedRange(&frame, id, 3, 1));
    try std.testing.expect(!input.performAccessibilitySetSelectedRange(&frame, id, 0, 5));
    try std.testing.expectEqual(elementId("previous-focus"), input.focused.?);
}

test "hover enter and exit" {
    var frame = FrameState.init(std.testing.allocator);
    defer frame.deinit();

    var hover_state: i32 = -1;
    try frame.addHitbox(.{
        .id = elementId("hoverable"),
        .bounds = Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 50, .height = 50 }),
        .on_hover = .{
            .ctx = &hover_state,
            .func = struct {
                fn onHover(ctx: ?*anyopaque, hovered: bool) void {
                    const state: *i32 = @ptrCast(@alignCast(ctx.?));
                    state.* = if (hovered) 1 else 0;
                }
            }.onHover,
        },
    });

    var input = InputState{};

    _ = input.dispatch(&frame, .{ .mouse_moved = .{ .position = .{ .x = 25, .y = 25 } } });
    try std.testing.expectEqual(@as(i32, 1), hover_state);
    try std.testing.expect(input.isHovered(elementId("hoverable")));

    _ = input.dispatch(&frame, .{ .mouse_moved = .{ .position = .{ .x = 200, .y = 200 } } });
    try std.testing.expectEqual(@as(i32, 0), hover_state);
}

test "tab moves focus and key events reach focused element" {
    var frame = FrameState.init(std.testing.allocator);
    defer frame.deinit();

    var received_key: ?platform.Key = null;
    const key_handler = KeyHandler{
        .ctx = &received_key,
        .func = struct {
            fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
                const slot: *?platform.Key = @ptrCast(@alignCast(ctx.?));
                slot.* = event.key;
                return true;
            }
        }.onKey,
    };

    try frame.addFocusable(.{ .id = 100, .on_key = key_handler });
    try frame.addFocusable(.{ .id = 200 });

    var input = InputState{};

    // Tab focuses the first element.
    _ = input.dispatch(&frame, .{ .key_down = .{ .key = .tab } });
    try std.testing.expect(input.isFocused(100));

    // Key event is delivered to the focused element.
    _ = input.dispatch(&frame, .{ .key_down = .{ .key = .enter } });
    try std.testing.expectEqual(@as(?platform.Key, .enter), received_key);

    // Tab again: second element; shift-tab: back to first.
    _ = input.dispatch(&frame, .{ .key_down = .{ .key = .tab } });
    try std.testing.expect(input.isFocused(200));
    _ = input.dispatch(&frame, .{ .key_down = .{ .key = .tab, .modifiers = .{ .shift = true } } });
    try std.testing.expect(input.isFocused(100));
}

test "tab sets focus_visible; pointer focus clears it" {
    var frame = FrameState.init(std.testing.allocator);
    defer frame.deinit();

    const button_id = elementId("focus-visible-btn");
    try frame.addHitbox(.{
        .id = button_id,
        .bounds = Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 100, .height = 40 }),
        .on_click = .{
            .ctx = null,
            .func = struct {
                fn noop(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
            }.noop,
        },
    });
    try frame.addFocusable(.{ .id = button_id });

    var input = InputState{};

    _ = input.dispatch(&frame, .{ .key_down = .{ .key = .tab } });
    try std.testing.expect(input.isFocused(button_id));
    try std.testing.expect(input.focus_visible);

    _ = input.dispatch(&frame, .{ .mouse_down = .{ .button = .left, .position = .{ .x = 10, .y = 10 } } });
    try std.testing.expect(input.isFocused(button_id));
    try std.testing.expect(!input.focus_visible);
}

test "programmatic focus leaves focus_visible unchanged" {
    var input = InputState{ .focus_visible = true };
    input.focus(42);
    try std.testing.expect(input.focus_visible);
    input.focusFromPointer(42);
    try std.testing.expect(!input.focus_visible);
    input.focus(99);
    try std.testing.expect(!input.focus_visible);
}
