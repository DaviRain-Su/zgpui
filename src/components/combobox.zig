//! Headless combobox: select dropdown with an editable trigger stub and
//! optional filter string stored in entity state. Reuses select list/items.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const select_mod = @import("select.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;

pub const Value = select_mod.Value;
pub const ChangeHandler = select_mod.ChangeHandler;
pub const ItemStyleState = select_mod.ItemStyleState;
pub const ItemStyleFn = select_mod.ItemStyleFn;
pub const StyleFn = select_mod.StyleFn;
pub const SelectRegistry = select_mod.SelectRegistry;

pub const filter_capacity = 64;

pub const ComboboxState = struct {
    open: bool = false,
    highlighted_index: i32 = -1,
    filter_buf: [filter_capacity]u8 = undefined,
    filter_len: usize = 0,

    pub fn filter(self: *const ComboboxState) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }

    pub fn setFilter(self: *ComboboxState, text: []const u8) void {
        const len = @min(text.len, filter_capacity);
        @memcpy(self.filter_buf[0..len], text[0..len]);
        self.filter_len = len;
    }

    pub fn clearFilter(self: *ComboboxState) void {
        self.filter_len = 0;
    }

    pub fn openCombobox(self: *ComboboxState, highlight: i32) void {
        self.open = true;
        self.highlighted_index = highlight;
    }

    pub fn close(self: *ComboboxState) void {
        self.open = false;
        self.highlighted_index = -1;
    }
};

/// Returns true when `label` contains every filter character in order
/// (case-insensitive). Empty filter matches all labels.
pub fn labelMatchesFilter(label: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    var label_i: usize = 0;
    for (filter) |fc| {
        const want = std.ascii.toLower(fc);
        var found = false;
        while (label_i < label.len) : (label_i += 1) {
            if (std.ascii.toLower(label[label_i]) == want) {
                label_i += 1;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub fn selectedIndex(app: *App, value: Value) usize {
    return select_mod.selectedIndex(app, value);
}

pub fn isSelected(app: *App, value: Value, index: usize) bool {
    return select_mod.isSelected(app, value, index);
}

pub fn selectIndex(app: *App, value: Value, index: usize, on_change: ?ChangeHandler) void {
    select_mod.selectIndex(app, value, index, on_change);
}

pub fn highlightedIndex(app: *App, state: app_mod.Entity(ComboboxState)) i32 {
    return app.read(ComboboxState, state).highlighted_index;
}

pub fn close(app: *App, state: app_mod.Entity(ComboboxState)) void {
    app.read(ComboboxState, state).close();
    app.notify(state.id);
}

pub fn open(app: *App, state: app_mod.Entity(ComboboxState), value: Value) void {
    const highlight = @as(i32, @intCast(selectedIndex(app, value)));
    app.read(ComboboxState, state).openCombobox(highlight);
    app.notify(state.id);
}

/// Label provider for filter/type-ahead. `index` is the option index.
pub const LabelFn = *const fn (ctx: ?*anyopaque, index: usize) []const u8;

pub const ContentFn = *const fn (
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    registry: *SelectRegistry,
    visible_indices: []const usize,
) anyerror!*Div;

pub const Props = struct {
    id: []const u8,
    trigger_id: []const u8,
    state: app_mod.Entity(ComboboxState),
    value: Value,
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    list_id: []const u8,
    option_count: usize,
    label_ctx: ?*anyopaque = null,
    label_fn: ?LabelFn = null,
    z_index: i32 = 66,
    trap_focus: bool = true,
    modal: bool = true,
    on_change: ?ChangeHandler = null,
    panel_style: ?StyleFn = null,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
};

fn keyToFilterChar(key: platform.Key) ?u8 {
    return switch (key) {
        .a => 'a', .b => 'b', .c => 'c', .d => 'd', .e => 'e', .f => 'f', .g => 'g',
        .h => 'h', .i => 'i', .j => 'j', .k => 'k', .l => 'l', .m => 'm', .n => 'n',
        .o => 'o', .p => 'p', .q => 'q', .r => 'r', .s => 's', .t => 't', .u => 'u',
        .v => 'v', .w => 'w', .x => 'x', .y => 'y', .z => 'z',
        else => null,
    };
}

fn visibleIndices(
    arena: std.mem.Allocator,
    app: *App,
    state: app_mod.Entity(ComboboxState),
    option_count: usize,
    label_ctx: ?*anyopaque,
    label_fn: ?LabelFn,
) ![]usize {
    const filter_text = app.read(ComboboxState, state).filter();
    var out = std.ArrayList(usize).empty;
    var i: usize = 0;
    while (i < option_count) : (i += 1) {
        const label = if (label_fn) |lf| lf(label_ctx, i) else "";
        if (labelMatchesFilter(label, filter_text)) {
            try out.append(arena, i);
        }
    }
    return out.items;
}

fn remapHighlight(app: *App, state: app_mod.Entity(ComboboxState), visible: []const usize) void {
    const combo = app.read(ComboboxState, state);
    if (visible.len == 0) {
        combo.highlighted_index = -1;
        return;
    }
    const current = combo.highlighted_index;
    if (current >= 0) {
        for (visible, 0..) |orig, vi| {
            if (orig == @as(usize, @intCast(current))) {
                combo.highlighted_index = @intCast(vi);
                return;
            }
        }
    }
    combo.highlighted_index = 0;
}

const Host = struct {
    app: *App,
    state: app_mod.Entity(ComboboxState),
    value: Value,
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    trigger_id: []const u8,
    panel_style: ?StyleFn,
    panel_id: []const u8,
    list_id: []const u8,
    option_count: usize,
    label_ctx: ?*anyopaque,
    label_fn: ?LabelFn,
    on_change: ?ChangeHandler,
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
        const combo = self.app.read(ComboboxState, self.state);
        if (!combo.open) return div_mod.div(arena).sizePx(0, 0).any();

        const visible = try visibleIndices(
            arena,
            self.app,
            self.state,
            self.option_count,
            self.label_ctx,
            self.label_fn,
        );
        remapHighlight(self.app, self.state, visible);

        var backdrop = div_mod.div(arena)
            .withId("combobox-backdrop")
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
            const registry = arena.create(SelectRegistry) catch @panic("frame arena OOM");
            registry.* = SelectRegistry.init();
            const body = try content_fn(self.content_ctx, arena, registry, visible);
            panel = panel.childDiv(body);
        }

        if (triggerBounds(self.frame, self.trigger_id)) |bounds| {
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

const TriggerHost = struct {
    app: *App,
    state: app_mod.Entity(ComboboxState),
    value: Value,
    input: *element.InputState,
    list_id: []const u8,
    option_count: usize,
    label_ctx: ?*anyopaque,
    label_fn: ?LabelFn,

    fn openList(self: *TriggerHost) void {
        const combo = self.app.read(ComboboxState, self.state);
        combo.openCombobox(@intCast(selectedIndex(self.app, self.value)));
        self.input.focus(element.elementId(self.list_id));
        self.app.notify(self.state.id);
    }

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TriggerHost = @ptrCast(@alignCast(ctx.?));
        const combo = self.app.read(ComboboxState, self.state);
        if (combo.open) {
            combo.close();
        } else {
            self.openList();
        }
        self.app.notify(self.state.id);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *TriggerHost = @ptrCast(@alignCast(ctx.?));
        const combo = self.app.read(ComboboxState, self.state);

        switch (event.key) {
            .down, .enter, .space => {
                if (!combo.open) self.openList();
                return true;
            },
            .escape => {
                if (combo.open) {
                    combo.close();
                    self.app.notify(self.state.id);
                    return true;
                }
                return false;
            },
            .backspace => {
                if (combo.filter_len == 0) return false;
                combo.filter_len -= 1;
                if (!combo.open) self.openList();
                self.app.notify(self.state.id);
                return true;
            },
            else => {},
        }

        if (keyToFilterChar(event.key)) |ch| {
            if (combo.filter_len < filter_capacity) {
                combo.filter_buf[combo.filter_len] = ch;
                combo.filter_len += 1;
            }
            if (!combo.open) self.openList();
            self.app.notify(self.state.id);
            return true;
        }

        return false;
    }
};

fn triggerBounds(frame: *const element.FrameState, trigger_id: []const u8) ?Bounds(Pixels) {
    if (trigger_id.len == 0) return null;
    const id = element.elementId(trigger_id);
    for (frame.hitboxes.items) |hitbox| {
        if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
    }
    return null;
}

fn registerOverlay(arena: std.mem.Allocator, props: Props) !void {
    const is_open = props.app.read(ComboboxState, props.state).open;
    if (!is_open) return;

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .frame = props.frame,
        .viewport = props.viewport,
        .trigger_id = props.trigger_id,
        .panel_style = props.panel_style,
        .panel_id = props.id,
        .list_id = props.list_id,
        .option_count = props.option_count,
        .label_ctx = props.label_ctx,
        .label_fn = props.label_fn,
        .on_change = props.on_change,
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

/// Zero-size placeholder; registers combobox overlay when open.
pub fn combobox(arena: std.mem.Allocator, props: Props) !*Div {
    try registerOverlay(arena, props);
    return div_mod.div(arena).sizePx(0, 0);
}

/// Editable trigger stub (focusable, type-ahead filter) + overlay list.
pub fn comboboxWithTrigger(
    arena: std.mem.Allocator,
    props: Props,
    trigger: *Div,
) !*Div {
    const trigger_host = arena.create(TriggerHost) catch @panic("frame arena OOM");
    trigger_host.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .input = props.input,
        .list_id = props.list_id,
        .option_count = props.option_count,
        .label_ctx = props.label_ctx,
        .label_fn = props.label_fn,
    };

    const focus_id: element.FocusId = element.elementId(props.trigger_id);
    _ = trigger
        .focusable(focus_id, .{ .ctx = trigger_host, .func = TriggerHost.onKey })
        .onClick(trigger_host, TriggerHost.onClick);
    if (trigger.a11y_role == null) _ = trigger.role(.button);
    const is_open = props.app.read(ComboboxState, props.state).open;
    _ = trigger.a11yExpanded(is_open);

    try registerOverlay(arena, props);
    return trigger;
}

// ---------------------------------------------------------------------------
// List helpers (visible-index aware)
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    state: app_mod.Entity(ComboboxState),
    value: Value,
    app: *App,
    visible_indices: []const usize,
    registry: *SelectRegistry,
    on_change: ?ChangeHandler = null,
};

const ListNav = struct {
    app: *App,
    state: app_mod.Entity(ComboboxState),
    value: Value,
    visible_indices: []const usize,
    registry: *SelectRegistry,
    on_change: ?ChangeHandler,

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
                self.app.read(ComboboxState, self.state).highlighted_index = idx;
                self.app.notify(self.state.id);
                return;
            }
        }
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
            .enter, .space => {
                const vi = highlightedIndex(self.app, self.state);
                if (vi < 0) return false;
                const orig = self.visible_indices[@intCast(vi)];
                if (self.registry.isDisabled(orig)) return false;
                selectIndex(self.app, self.value, orig, self.on_change);
                close(self.app, self.state);
                return true;
            },
            else => return false,
        }
    }
};

pub fn comboboxList(arena: std.mem.Allocator, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .visible_indices = props.visible_indices,
        .registry = props.registry,
        .on_change = props.on_change,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
}

pub const ItemProps = struct {
    id: []const u8,
    state: app_mod.Entity(ComboboxState),
    value: Value,
    app: *App,
    index: usize,
    visible_index: usize,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?ItemStyleFn = null,
    registry: *SelectRegistry,
};

const ItemSelect = struct {
    app: *App,
    state: app_mod.Entity(ComboboxState),
    value: Value,
    index: usize,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemSelect = @ptrCast(@alignCast(ctx.?));
        selectIndex(self.app, self.value, self.index, self.on_change);
        close(self.app, self.state);
    }
};

pub fn isHighlighted(app: *App, state: app_mod.Entity(ComboboxState), visible_index: usize) bool {
    return highlightedIndex(app, state) == @as(i32, @intCast(visible_index));
}

pub fn comboboxItem(arena: std.mem.Allocator, input: *const element.InputState, props: ItemProps) !*Div {
    const id = element.elementId(props.id);

    props.registry.register(arena, .{
        .index = props.index,
        .disabled = props.disabled,
    }) catch @panic("frame arena OOM");

    const item_state = ItemStyleState{
        .selected = isSelected(props.app, props.value, props.index),
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
        else if (item_state.selected)
            Rgba.fromHex(0xdbeafe)
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
            .index = props.index,
            .on_change = props.on_change,
        };
        d = d.onClick(select_ctx, ItemSelect.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const ComboboxFixture = struct {
    harness: *testing_mod.Harness = undefined,
    combo_state: app_mod.Entity(ComboboxState) = undefined,
    value_entity: app_mod.Entity(Value.Store) = undefined,

    const labels = [_][]const u8{ "Apple", "Banana", "Cherry" };

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
        const self: *ComboboxFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value: Value = .{ .uncontrolled = self.value_entity };

        var trigger = div_mod.div(arena)
            .withId("combo-trigger")
            .sizePx(140, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try comboboxWithTrigger(arena, .{
            .id = "fruit-combo",
            .trigger_id = "combo-trigger",
            .state = self.combo_state,
            .value = value,
            .overlays = &harness.overlays,
            .app = app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .list_id = "combo-list",
            .option_count = labels.len,
            .label_ctx = self,
            .label_fn = label,
            .content_ctx = self,
            .content_fn = buildList,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }

    fn buildList(
        ctx: ?*anyopaque,
        arena: std.mem.Allocator,
        registry: *SelectRegistry,
        visible_indices: []const usize,
    ) !*Div {
        const self: *ComboboxFixture = @ptrCast(@alignCast(ctx.?));
        const app = &self.harness.app;
        const value: Value = .{ .uncontrolled = self.value_entity };

        var list = comboboxList(arena, .{
            .id = "combo-list",
            .state = self.combo_state,
            .value = value,
            .app = app,
            .visible_indices = visible_indices,
            .registry = registry,
        });

        for (visible_indices, 0..) |orig_index, vi| {
            const name = try std.fmt.allocPrint(arena, "combo-item-{d}", .{orig_index});
            list = list.childDiv(try comboboxItem(arena, &self.harness.input, .{
                .id = name,
                .state = self.combo_state,
                .value = value,
                .app = app,
                .index = orig_index,
                .visible_index = vi,
                .style_fn = itemStyle,
                .registry = registry,
            }));
        }
        return list;
    }
};

test "combobox opens via trigger" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ComboboxFixture{ .harness = &harness };
    fixture.combo_state = try harness.app.new(ComboboxState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, ComboboxFixture.render);

    try std.testing.expect(!harness.app.read(ComboboxState, fixture.combo_state).open);
    try harness.clickOn("combo-trigger");
    try std.testing.expect(harness.app.read(ComboboxState, fixture.combo_state).open);
}

test "combobox item click selects and closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ComboboxFixture{ .harness = &harness };
    fixture.combo_state = try harness.app.new(ComboboxState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, ComboboxFixture.render);

    try harness.clickOn("combo-trigger");
    try harness.clickOn("combo-item-2");
    try std.testing.expect(!harness.app.read(ComboboxState, fixture.combo_state).open);
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, .{ .uncontrolled = fixture.value_entity }));
}

test "combobox closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ComboboxFixture{ .harness = &harness };
    fixture.combo_state = try harness.app.new(ComboboxState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, ComboboxFixture.render);

    try harness.clickOn("combo-trigger");
    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(ComboboxState, fixture.combo_state).open);
}

test "combobox keyboard select" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ComboboxFixture{ .harness = &harness };
    fixture.combo_state = try harness.app.new(ComboboxState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, ComboboxFixture.render);

    try harness.clickOn("combo-trigger");
    try harness.focusById(element.elementId("combo-list"));
    try harness.keyDown(.down);
    try harness.keyDown(.enter);
    try std.testing.expect(!harness.app.read(ComboboxState, fixture.combo_state).open);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(&harness.app, .{ .uncontrolled = fixture.value_entity }));
}

test "labelMatchesFilter subsequence" {
    try std.testing.expect(labelMatchesFilter("Banana", "ban"));
    try std.testing.expect(!labelMatchesFilter("Apple", "xyz"));
    try std.testing.expect(labelMatchesFilter("Cherry", ""));
}
