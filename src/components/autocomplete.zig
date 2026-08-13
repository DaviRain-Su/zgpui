//! Headless autocomplete: free-text input with a filtered suggestion overlay
//! (subsequence match). Unlike combobox, the value is typed text, not a
//! selected index.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const combobox_mod = @import("combobox.zig");
const text_input_mod = @import("../elements/text_input.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const animation_mod = @import("../animation.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;
const TextInputState = text_input_mod.TextInputState;

pub const labelMatchesFilter = combobox_mod.labelMatchesFilter;

pub const text_capacity = 128;

pub const TextStore = struct {
    buf: [text_capacity]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const TextStore) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn setText(self: *TextStore, value: []const u8) void {
        const len = @min(value.len, text_capacity);
        @memcpy(self.buf[0..len], value[0..len]);
        self.len = len;
    }
};

pub const AutocompleteState = struct {
    open: bool = false,
    highlighted_index: i32 = -1,

    pub fn openList(self: *AutocompleteState, highlight: i32) void {
        self.open = true;
        self.highlighted_index = highlight;
    }

    pub fn close(self: *AutocompleteState) void {
        self.open = false;
        self.highlighted_index = -1;
    }
};

pub const Value = union(enum) {
    controlled: []const u8,
    uncontrolled: app_mod.Entity(TextStore),
    text_input: app_mod.Entity(TextInputState),

    pub fn read(self: Value, app: *App) []const u8 {
        return switch (self) {
            .controlled => |t| t,
            .uncontrolled => |entity| app.read(TextStore, entity).text(),
            .text_input => |entity| app.read(TextInputState, entity).text(),
        };
    }

    pub fn setText(self: Value, app: *App, text: []const u8) void {
        switch (self) {
            .controlled => {},
            .uncontrolled => |entity| {
                app.read(TextStore, entity).setText(text);
                app.notify(entity.id);
            },
            .text_input => |entity| {
                const state = app.read(TextInputState, entity);
                state.buffer.clearRetainingCapacity();
                state.buffer.appendSlice(state.gpa, text) catch @panic("OOM");
                state.caret = text.len;
                state.selection_anchor = null;
                app.notify(entity.id);
            },
        }
    }
};

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

pub const SelectHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, text: []const u8, index: usize) void,
};

pub const ItemStyleState = struct {
    highlighted: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;
pub const StyleFn = *const fn (open: bool) style_mod.Style;
pub const LabelFn = *const fn (ctx: ?*anyopaque, index: usize) []const u8;

pub const AutocompleteRegistry = struct {
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        index: usize,
        disabled: bool,
    };

    pub fn init() AutocompleteRegistry {
        return .{ .entries = .empty };
    }

    pub fn register(self: *AutocompleteRegistry, arena: std.mem.Allocator, entry: Entry) !void {
        try self.entries.append(arena, entry);
    }

    pub fn isDisabled(self: *const AutocompleteRegistry, index: usize) bool {
        for (self.entries.items) |entry| {
            if (entry.index == index) return entry.disabled;
        }
        return false;
    }
};

pub const ContentFn = *const fn (
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    registry: *AutocompleteRegistry,
    visible_indices: []const usize,
) anyerror!*Div;

pub fn readText(app: *App, value: Value) []const u8 {
    return value.read(app);
}

pub fn setText(app: *App, value: Value, text: []const u8, on_change: ?ChangeHandler) void {
    value.setText(app, text);
    if (on_change) |handler| handler.func(handler.ctx, text);
}

pub fn highlightedIndex(app: *App, state: app_mod.Entity(AutocompleteState)) i32 {
    return app.read(AutocompleteState, state).highlighted_index;
}

pub fn close(app: *App, state: app_mod.Entity(AutocompleteState)) void {
    app.read(AutocompleteState, state).close();
    app.notify(state.id);
}

pub fn open(app: *App, state: app_mod.Entity(AutocompleteState)) void {
    app.read(AutocompleteState, state).openList(0);
    app.notify(state.id);
}

pub fn isHighlighted(app: *App, state: app_mod.Entity(AutocompleteState), visible_index: usize) bool {
    return highlightedIndex(app, state) == @as(i32, @intCast(visible_index));
}

fn visibleIndices(
    arena: std.mem.Allocator,
    app: *App,
    value: Value,
    option_count: usize,
    label_ctx: ?*anyopaque,
    label_fn: ?LabelFn,
    static_labels: []const []const u8,
) ![]usize {
    const filter_text = value.read(app);
    var out = std.ArrayList(usize).empty;
    var i: usize = 0;
    while (i < option_count) : (i += 1) {
        const label = if (label_fn) |lf|
            lf(label_ctx, i)
        else if (static_labels.len > i)
            static_labels[i]
        else
            "";
        if (labelMatchesFilter(label, filter_text)) {
            try out.append(arena, i);
        }
    }
    return out.items;
}

fn remapHighlight(app: *App, state: app_mod.Entity(AutocompleteState), visible: []const usize) void {
    const ac = app.read(AutocompleteState, state);
    if (visible.len == 0) {
        ac.highlighted_index = -1;
        return;
    }
    const current = ac.highlighted_index;
    if (current >= 0 and @as(usize, @intCast(current)) < visible.len) return;
    ac.highlighted_index = 0;
}

pub const Props = struct {
    id: []const u8,
    input_id: []const u8,
    state: app_mod.Entity(AutocompleteState),
    value: Value,
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    list_id: []const u8,
    option_count: usize,
    /// Static labels when `label_fn` is null.
    items: []const []const u8 = &.{},
    label_ctx: ?*anyopaque = null,
    label_fn: ?LabelFn = null,
    z_index: i32 = 66,
    trap_focus: bool = false,
    modal: bool = false,
    on_change: ?ChangeHandler = null,
    on_select: ?SelectHandler = null,
    panel_style: ?StyleFn = null,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
    timeline: ?*animation_mod.Timeline = null,
};

const Host = struct {
    app: *App,
    state: app_mod.Entity(AutocompleteState),
    value: Value,
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    input_id: []const u8,
    panel_style: ?StyleFn,
    panel_id: []const u8,
    list_id: []const u8,
    option_count: usize,
    items: []const []const u8,
    label_ctx: ?*anyopaque,
    label_fn: ?LabelFn,
    on_change: ?ChangeHandler,
    on_select: ?SelectHandler,
    content_ctx: ?*anyopaque,
    content_fn: ?ContentFn,

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        close(self.app, self.state);
    }

    fn dismissMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        dismiss(ctx);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const ac = self.app.read(AutocompleteState, self.state);
        if (!ac.open) return div_mod.div(arena).sizePx(0, 0).any();

        const visible = try visibleIndices(
            arena,
            self.app,
            self.value,
            self.option_count,
            self.label_ctx,
            self.label_fn,
            self.items,
        );
        remapHighlight(self.app, self.state, visible);

        var backdrop = div_mod.div(arena)
            .withId("autocomplete-backdrop")
            .absolute()
            .wFull()
            .hFull()
            .interactive()
            .onMouseDown(self, dismissMouseDown);

        var panel = div_mod.div(arena)
            .withId(self.panel_id)
            .absolute()
            .interactive();
        if (self.panel_style) |style_fn| {
            panel = panel.withStyle(style_fn(true));
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 180 };
            s.min_height = .{ .px = 40 };
            s.background = Rgba.fromHex(0xffffff);
            s.corner_radii = geometry.Corners(Pixels).all(6);
            s.padding = .{
                .top = .{ .px = 4 },
                .right = .{ .px = 4 },
                .bottom = .{ .px = 4 },
                .left = .{ .px = 4 },
            };
            panel = panel.withStyle(s);
        }
        panel = panel.onClick(null, struct {
            fn swallow(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
        }.swallow);

        if (self.content_fn) |content_fn| {
            const registry = arena.create(AutocompleteRegistry) catch @panic("frame arena OOM");
            registry.* = AutocompleteRegistry.init();
            const body = try content_fn(self.content_ctx, arena, registry, visible);
            panel = panel.childDiv(body);
        }

        if (inputBounds(self.frame, self.input_id)) |bounds| {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = bounds.origin.y + bounds.size.height + 4 };
            s.inset.left = .{ .px = bounds.origin.x };
            panel.style = s;
        } else {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = self.viewport.height / 2 - 40 };
            s.inset.left = .{ .px = self.viewport.width / 2 - 90 };
            panel.style = s;
        }

        return backdrop.childDiv(panel).any();
    }
};

const InputHost = struct {
    app: *App,
    state: app_mod.Entity(AutocompleteState),
    value: Value,
    input: *element.InputState,
    list_id: []const u8,
    on_change: ?ChangeHandler,

    fn openIfNeeded(self: *InputHost) void {
        const ac = self.app.read(AutocompleteState, self.state);
        if (!ac.open) ac.openList(0);
    }

    fn notifyTextChanged(self: *InputHost) void {
        self.openIfNeeded();
        self.app.read(AutocompleteState, self.state).highlighted_index = 0;
        self.app.notify(self.state.id);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *InputHost = @ptrCast(@alignCast(ctx.?));
        const ac = self.app.read(AutocompleteState, self.state);

        switch (event.key) {
            .down => {
                if (!ac.open) self.openIfNeeded();
                self.input.focus(element.elementId(self.list_id));
                self.app.notify(self.state.id);
                return true;
            },
            .escape => {
                if (ac.open) {
                    ac.close();
                    self.app.notify(self.state.id);
                    return true;
                }
                return false;
            },
            .backspace => {
                const text = switch (self.value) {
                    .uncontrolled => |entity| blk: {
                        const s = self.app.read(TextStore, entity);
                        if (s.len == 0) return false;
                        s.len -= 1;
                        self.app.notify(entity.id);
                        break :blk s.text();
                    },
                    .text_input => |entity| blk: {
                        const s = self.app.read(TextInputState, entity);
                        if (s.buffer.items.len == 0) return false;
                        _ = s.buffer.pop();
                        s.caret = s.buffer.items.len;
                        s.selection_anchor = null;
                        self.app.notify(entity.id);
                        break :blk s.text();
                    },
                    .controlled => return false,
                };
                if (self.on_change) |handler| handler.func(handler.ctx, text);
                self.notifyTextChanged();
                return true;
            },
            else => return false,
        }
    }

    fn onTextInput(ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool {
        const self: *InputHost = @ptrCast(@alignCast(ctx.?));
        switch (self.value) {
            .uncontrolled => |entity| {
                const store = self.app.read(TextStore, entity);
                for (event.text) |ch| {
                    if (store.len >= text_capacity) break;
                    store.buf[store.len] = ch;
                    store.len += 1;
                }
                self.app.notify(entity.id);
            },
            .text_input => |entity| {
                const state = self.app.read(TextInputState, entity);
                for (event.text) |ch| {
                    state.buffer.append(state.gpa, ch) catch @panic("OOM");
                }
                state.caret = state.buffer.items.len;
                state.selection_anchor = null;
                self.app.notify(entity.id);
            },
            .controlled => return false,
        }
        const text = self.value.read(self.app);
        if (self.on_change) |handler| handler.func(handler.ctx, text);
        self.notifyTextChanged();
        return true;
    }
};

fn inputBounds(frame: *const element.FrameState, input_id: []const u8) ?Bounds(Pixels) {
    if (input_id.len == 0) return null;
    const id = element.elementId(input_id);
    for (frame.hitboxes.items) |hitbox| {
        if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
    }
    return null;
}

fn registerOverlay(arena: std.mem.Allocator, props: Props) !void {
    const is_open = props.app.read(AutocompleteState, props.state).open;
    if (!is_open) return;

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .frame = props.frame,
        .viewport = props.viewport,
        .input_id = props.input_id,
        .panel_style = props.panel_style,
        .panel_id = props.id,
        .list_id = props.list_id,
        .option_count = props.option_count,
        .items = props.items,
        .label_ctx = props.label_ctx,
        .label_fn = props.label_fn,
        .on_change = props.on_change,
        .on_select = props.on_select,
        .content_ctx = props.content_ctx,
        .content_fn = props.content_fn,
    };
    try props.overlays.push(.{
        .id = overlay_mod.overlayId(props.id),
        .z_index = props.z_index,
        .trap_focus = props.trap_focus,
        .modal = props.modal,
        .ctx = host,
        .render = Host.render,
        .on_dismiss = Host.dismiss,
    });
}

/// Zero-size placeholder; registers autocomplete overlay when open.
pub fn autocomplete(arena: std.mem.Allocator, props: Props) !*Div {
    try registerOverlay(arena, props);
    return div_mod.div(arena).sizePx(0, 0);
}

pub const InputProps = struct {
    id: []const u8,
    state: app_mod.Entity(AutocompleteState),
    value: Value,
    list_id: []const u8,
    app: *App,
    input: *element.InputState,
    on_change: ?ChangeHandler = null,
};

/// Focusable text input stub (textbox role) that opens the suggestion list.
pub fn autocompleteInput(arena: std.mem.Allocator, props: InputProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);
    const text = props.value.read(props.app);

    const host = arena.create(InputHost) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .input = props.input,
        .list_id = props.list_id,
        .on_change = props.on_change,
    };

    var s = style_mod.Style{};
    s.width = .{ .px = 180 };
    s.height = .{ .px = 32 };
    s.padding = .{
        .top = .{ .px = 6 },
        .right = .{ .px = 10 },
        .bottom = .{ .px = 6 },
        .left = .{ .px = 10 },
    };
    s.background = Rgba.fromHex(0xffffff);

    return div_mod.div(arena)
        .withId(props.id)
        .withStyle(s)
        .role(.textbox)
        .a11yValueText(text)
        .focusable(focus_id, .{ .ctx = host, .func = InputHost.onKey })
        .onTextInput(host, InputHost.onTextInput);
}

// ---------------------------------------------------------------------------
// List helpers
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    state: app_mod.Entity(AutocompleteState),
    value: Value,
    app: *App,
    visible_indices: []const usize,
    registry: *AutocompleteRegistry,
    label_ctx: ?*anyopaque = null,
    label_fn: ?LabelFn = null,
    items: []const []const u8 = &.{},
    on_change: ?ChangeHandler = null,
    on_select: ?SelectHandler = null,
};

const ListNav = struct {
    app: *App,
    state: app_mod.Entity(AutocompleteState),
    value: Value,
    visible_indices: []const usize,
    registry: *AutocompleteRegistry,
    label_ctx: ?*anyopaque,
    label_fn: ?LabelFn,
    items: []const []const u8,
    on_change: ?ChangeHandler,
    on_select: ?SelectHandler,

    fn labelAt(self: *ListNav, index: usize) []const u8 {
        if (self.label_fn) |lf| return lf(self.label_ctx, index);
        if (self.items.len > index) return self.items[index];
        return "";
    }

    fn moveHighlight(self: *ListNav, delta: i32) void {
        if (self.visible_indices.len == 0) return;
        var idx = highlightedIndex(self.app, self.state);
        if (idx < 0) idx = 0;

        var attempts: usize = 0;
        while (attempts < self.visible_indices.len) : (attempts += 1) {
            var next = idx + delta;
            while (next < 0) next += @as(i32, @intCast(self.visible_indices.len));
            while (next >= @as(i32, @intCast(self.visible_indices.len))) next -= @as(i32, @intCast(self.visible_indices.len));
            idx = next;

            const orig = self.visible_indices[@intCast(idx)];
            if (!self.registry.isDisabled(orig)) {
                self.app.read(AutocompleteState, self.state).highlighted_index = idx;
                self.app.notify(self.state.id);
                return;
            }
        }
    }

    fn selectHighlighted(self: *ListNav) void {
        const vi = highlightedIndex(self.app, self.state);
        if (vi < 0) return;
        const orig = self.visible_indices[@intCast(vi)];
        if (self.registry.isDisabled(orig)) return;
        const label = self.labelAt(orig);
        setText(self.app, self.value, label, self.on_change);
        if (self.on_select) |handler| handler.func(handler.ctx, label, orig);
        close(self.app, self.state);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ListNav = @ptrCast(@alignCast(ctx.?));
        if (self.visible_indices.len == 0) return false;

        switch (event.key) {
            .down => {
                self.moveHighlight(1);
                return true;
            },
            .up => {
                self.moveHighlight(-1);
                return true;
            },
            .enter, .tab => {
                self.selectHighlighted();
                return true;
            },
            .escape => {
                close(self.app, self.state);
                return true;
            },
            else => return false,
        }
    }
};

pub fn autocompleteList(arena: std.mem.Allocator, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .visible_indices = props.visible_indices,
        .registry = props.registry,
        .label_ctx = props.label_ctx,
        .label_fn = props.label_fn,
        .items = props.items,
        .on_change = props.on_change,
        .on_select = props.on_select,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .role(.list)
        .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
}

pub const ItemProps = struct {
    id: []const u8,
    state: app_mod.Entity(AutocompleteState),
    value: Value,
    app: *App,
    index: usize,
    visible_index: usize,
    disabled: bool = false,
    label: []const u8 = "",
    on_change: ?ChangeHandler = null,
    on_select: ?SelectHandler = null,
    style_fn: ?ItemStyleFn = null,
    registry: *AutocompleteRegistry,
};

const ItemSelect = struct {
    app: *App,
    state: app_mod.Entity(AutocompleteState),
    value: Value,
    label: []const u8,
    index: usize,
    on_change: ?ChangeHandler,
    on_select: ?SelectHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemSelect = @ptrCast(@alignCast(ctx.?));
        setText(self.app, self.value, self.label, self.on_change);
        if (self.on_select) |handler| handler.func(handler.ctx, self.label, self.index);
        close(self.app, self.state);
    }
};

pub fn autocompleteItem(arena: std.mem.Allocator, input: *const element.InputState, props: ItemProps) !*Div {
    const id = element.elementId(props.id);

    props.registry.register(arena, .{
        .index = props.index,
        .disabled = props.disabled,
    }) catch @panic("frame arena OOM");

    const item_state = ItemStyleState{
        .highlighted = isHighlighted(props.app, props.state, props.visible_index),
        .hovered = input.isHovered(id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena).withId(props.id).interactive();
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(item_state));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = 160 };
        s.height = .{ .px = 28 };
        s.background = if (item_state.highlighted)
            Rgba.fromHex(0xe5e7eb)
        else if (item_state.hovered)
            Rgba.fromHex(0xf3f4f6)
        else
            Rgba.fromHex(0xffffff);
        d = d.withStyle(s);
    }

    if (!props.disabled) {
        const select_ctx = arena.create(ItemSelect) catch @panic("frame arena OOM");
        select_ctx.* = .{
            .app = props.app,
            .state = props.state,
            .value = props.value,
            .label = props.label,
            .index = props.index,
            .on_change = props.on_change,
            .on_select = props.on_select,
        };
        d = d.onClick(select_ctx, ItemSelect.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const AutocompleteFixture = struct {
    harness: *testing_mod.Harness = undefined,
    ac_state: app_mod.Entity(AutocompleteState) = undefined,
    text_state: app_mod.Entity(TextStore) = undefined,

    const labels = [_][]const u8{ "Apple", "Banana", "Cherry", "Apricot" };

    fn label(ctx: ?*anyopaque, index: usize) []const u8 {
        _ = ctx;
        return labels[index];
    }

    fn itemStyle(state: ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 160 };
        s.height = .{ .px = 28 };
        s.background = if (state.highlighted) Rgba.fromHex(0xbfdbfe) else Rgba.fromHex(0xffffff);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *AutocompleteFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value: Value = .{ .uncontrolled = self.text_state };

        const input_el = autocompleteInput(arena, .{
            .id = "ac-input",
            .state = self.ac_state,
            .value = value,
            .list_id = "ac-list",
            .app = app,
            .input = &harness.input,
        });

        _ = try autocomplete(arena, .{
            .id = "fruit-ac",
            .input_id = "ac-input",
            .state = self.ac_state,
            .value = value,
            .overlays = &harness.overlays,
            .app = app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .list_id = "ac-list",
            .option_count = labels.len,
            .label_ctx = self,
            .label_fn = label,
            .content_ctx = self,
            .content_fn = buildList,
        });

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(input_el).any();
    }

    fn buildList(
        ctx: ?*anyopaque,
        arena: std.mem.Allocator,
        registry: *AutocompleteRegistry,
        visible_indices: []const usize,
    ) !*Div {
        const self: *AutocompleteFixture = @ptrCast(@alignCast(ctx.?));
        const app = &self.harness.app;
        const value: Value = .{ .uncontrolled = self.text_state };

        var list = autocompleteList(arena, .{
            .id = "ac-list",
            .state = self.ac_state,
            .value = value,
            .app = app,
            .visible_indices = visible_indices,
            .registry = registry,
            .label_ctx = self,
            .label_fn = label,
        });

        for (visible_indices, 0..) |orig_index, vi| {
            const name = try std.fmt.allocPrint(arena, "ac-item-{d}", .{orig_index});
            list = list.childDiv(try autocompleteItem(arena, &self.harness.input, .{
                .id = name,
                .state = self.ac_state,
                .value = value,
                .app = app,
                .index = orig_index,
                .visible_index = vi,
                .label = labels[orig_index],
                .style_fn = itemStyle,
                .registry = registry,
            }));
        }
        return list;
    }
};

test "autocomplete typing filters suggestions" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = AutocompleteFixture{ .harness = &harness };
    fixture.ac_state = try harness.app.new(AutocompleteState, .{});
    fixture.text_state = try harness.app.new(TextStore, .{});
    try harness.setRoot(&fixture, AutocompleteFixture.render);

    try harness.focusById(element.elementId("ac-input"));
    try harness.textInput("ap");
    try std.testing.expect(harness.app.read(AutocompleteState, fixture.ac_state).open);
    try std.testing.expectEqualStrings("ap", readText(&harness.app, .{ .uncontrolled = fixture.text_state }));

    // Apple + Apricot match "ap".
    try std.testing.expect(harness.hitboxBounds(element.elementId("ac-item-0")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("ac-item-3")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("ac-item-1")) == null);
}

test "autocomplete select item sets value and closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = AutocompleteFixture{ .harness = &harness };
    fixture.ac_state = try harness.app.new(AutocompleteState, .{});
    fixture.text_state = try harness.app.new(TextStore, .{});
    try harness.setRoot(&fixture, AutocompleteFixture.render);

    try harness.focusById(element.elementId("ac-input"));
    try harness.textInput("ban");
    try harness.clickOn("ac-item-1");
    try std.testing.expectEqualStrings("Banana", readText(&harness.app, .{ .uncontrolled = fixture.text_state }));
    try std.testing.expect(!harness.app.read(AutocompleteState, fixture.ac_state).open);
}

test "autocomplete closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = AutocompleteFixture{ .harness = &harness };
    fixture.ac_state = try harness.app.new(AutocompleteState, .{});
    fixture.text_state = try harness.app.new(TextStore, .{});
    try harness.setRoot(&fixture, AutocompleteFixture.render);

    try harness.focusById(element.elementId("ac-input"));
    try harness.textInput("a");
    try std.testing.expect(harness.app.read(AutocompleteState, fixture.ac_state).open);
    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(AutocompleteState, fixture.ac_state).open);
}

test "autocomplete keyboard select" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = AutocompleteFixture{ .harness = &harness };
    fixture.ac_state = try harness.app.new(AutocompleteState, .{});
    fixture.text_state = try harness.app.new(TextStore, .{});
    try harness.setRoot(&fixture, AutocompleteFixture.render);

    try harness.focusById(element.elementId("ac-input"));
    try harness.textInput("a");
    try harness.focusById(element.elementId("ac-list"));
    try harness.keyDown(.down);
    try harness.keyDown(.enter);
    try std.testing.expect(!harness.app.read(AutocompleteState, fixture.ac_state).open);
    const text = readText(&harness.app, .{ .uncontrolled = fixture.text_state });
    try std.testing.expect(text.len > 0);
}

test "labelMatchesFilter subsequence" {
    try std.testing.expect(labelMatchesFilter("Banana", "ban"));
    try std.testing.expect(!labelMatchesFilter("Apple", "xyz"));
    try std.testing.expect(labelMatchesFilter("Cherry", ""));
}
