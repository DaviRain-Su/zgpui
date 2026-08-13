//! Headless command palette: centered modal overlay with filter input,
//! keyboard navigation (Up/Down, Enter, Escape), and click-to-select.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const combobox_mod = @import("combobox.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;
const Size = geometry.Size;

pub const labelMatchesFilter = combobox_mod.labelMatchesFilter;

pub const filter_capacity = 128;

pub const CommandPaletteState = struct {
    open: bool = false,
    filter_buf: [filter_capacity]u8 = undefined,
    filter_len: usize = 0,
    highlighted_index: i32 = -1,

    pub fn filter(self: *const CommandPaletteState) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }

    pub fn setFilter(self: *CommandPaletteState, text: []const u8) void {
        const len = @min(text.len, filter_capacity);
        @memcpy(self.filter_buf[0..len], text[0..len]);
        self.filter_len = len;
    }

    pub fn clearFilter(self: *CommandPaletteState) void {
        self.filter_len = 0;
    }

    pub fn openPalette(self: *CommandPaletteState) void {
        self.open = true;
        self.highlighted_index = 0;
        self.filter_len = 0;
    }

    pub fn close(self: *CommandPaletteState) void {
        self.open = false;
        self.highlighted_index = -1;
        self.filter_len = 0;
    }
};

pub const Command = struct {
    id: []const u8,
    label: []const u8,
    disabled: bool = false,
    keywords: ?[]const u8 = null,
};

pub const SelectHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, id: []const u8, index: usize) void,
};

pub const ItemStyleState = struct {
    highlighted: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;
pub const StyleFn = *const fn (open: bool) style_mod.Style;
pub const LabelFn = *const fn (ctx: ?*anyopaque, index: usize) []const u8;
pub const KeywordsFn = *const fn (ctx: ?*anyopaque, index: usize) ?[]const u8;
pub const IdFn = *const fn (ctx: ?*anyopaque, index: usize) []const u8;

pub const ContentFn = *const fn (
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    registry: *CommandRegistry,
    visible_indices: []const usize,
) anyerror!*Div;

pub const CommandRegistry = struct {
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        index: usize,
        id: []const u8,
        disabled: bool,
    };

    pub fn init() CommandRegistry {
        return .{ .entries = .empty };
    }

    pub fn register(self: *CommandRegistry, arena: std.mem.Allocator, entry: Entry) !void {
        try self.entries.append(arena, entry);
    }

    pub fn isDisabled(self: *const CommandRegistry, index: usize) bool {
        for (self.entries.items) |entry| {
            if (entry.index == index) return entry.disabled;
        }
        return false;
    }

    pub fn idAt(self: *const CommandRegistry, index: usize) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (entry.index == index) return entry.id;
        }
        return null;
    }
};

pub fn highlightedIndex(app: *App, state: app_mod.Entity(CommandPaletteState)) i32 {
    return app.read(CommandPaletteState, state).highlighted_index;
}

pub fn isHighlighted(app: *App, state: app_mod.Entity(CommandPaletteState), visible_index: usize) bool {
    return highlightedIndex(app, state) == @as(i32, @intCast(visible_index));
}

fn setHighlighted(app: *App, state: app_mod.Entity(CommandPaletteState), index: i32) void {
    app.read(CommandPaletteState, state).highlighted_index = index;
    app.notify(state.id);
}

pub fn close(app: *App, state: app_mod.Entity(CommandPaletteState)) void {
    app.read(CommandPaletteState, state).close();
    app.notify(state.id);
}

pub fn open(app: *App, state: app_mod.Entity(CommandPaletteState), input: *element.InputState, filter_id: []const u8) void {
    app.read(CommandPaletteState, state).openPalette();
    input.focus(element.elementId(filter_id));
    app.notify(state.id);
}

pub fn toggle(app: *App, state: app_mod.Entity(CommandPaletteState), input: *element.InputState, filter_id: []const u8) void {
    const s = app.read(CommandPaletteState, state);
    if (s.open) {
        s.close();
    } else {
        s.openPalette();
        input.focus(element.elementId(filter_id));
    }
    app.notify(state.id);
}

fn commandMatchesFilter(label: []const u8, keywords: ?[]const u8, filter: []const u8) bool {
    if (labelMatchesFilter(label, filter)) return true;
    if (keywords) |kw| return labelMatchesFilter(kw, filter);
    return false;
}

fn visibleIndicesFromSlice(arena: std.mem.Allocator, commands: []const Command, filter: []const u8) ![]usize {
    var out = std.ArrayList(usize).empty;
    for (commands, 0..) |cmd, i| {
        if (commandMatchesFilter(cmd.label, cmd.keywords, filter)) {
            try out.append(arena, i);
        }
    }
    return out.items;
}

fn visibleIndicesFromFns(
    arena: std.mem.Allocator,
    app: *App,
    state: app_mod.Entity(CommandPaletteState),
    command_count: usize,
    label_ctx: ?*anyopaque,
    label_fn: ?LabelFn,
    keywords_ctx: ?*anyopaque,
    keywords_fn: ?KeywordsFn,
) ![]usize {
    const filter_text = app.read(CommandPaletteState, state).filter();
    var out = std.ArrayList(usize).empty;
    var i: usize = 0;
    while (i < command_count) : (i += 1) {
        const label = if (label_fn) |lf| lf(label_ctx, i) else "";
        const keywords = if (keywords_fn) |kf| kf(keywords_ctx, i) else null;
        if (commandMatchesFilter(label, keywords, filter_text)) {
            try out.append(arena, i);
        }
    }
    return out.items;
}

fn remapHighlight(app: *App, state: app_mod.Entity(CommandPaletteState), visible: []const usize) void {
    const palette = app.read(CommandPaletteState, state);
    if (visible.len == 0) {
        palette.highlighted_index = -1;
        return;
    }
    const current = palette.highlighted_index;
    if (current >= 0) {
        for (visible, 0..) |orig, vi| {
            if (orig == @as(usize, @intCast(current))) {
                palette.highlighted_index = @intCast(vi);
                return;
            }
        }
    }
    palette.highlighted_index = 0;
}

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(CommandPaletteState),
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState = undefined,
    input: *element.InputState,
    viewport: Size(Pixels),
    filter_id: []const u8 = "command-palette-filter",
    list_id: []const u8 = "command-palette-list",
    /// Static command list (for tests or fixed palettes).
    commands: []const Command = &.{},
    command_count: usize = 0,
    label_ctx: ?*anyopaque = null,
    label_fn: ?LabelFn = null,
    keywords_ctx: ?*anyopaque = null,
    keywords_fn: ?KeywordsFn = null,
    id_ctx: ?*anyopaque = null,
    id_fn: ?IdFn = null,
    on_select: SelectHandler,
    z_index: i32 = 80,
    trap_focus: bool = true,
    modal: bool = true,
    panel_style: ?StyleFn = null,
    a11y_label: []const u8 = "Command palette",
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
};

// ---------------------------------------------------------------------------
// Filter input
// ---------------------------------------------------------------------------

pub const FilterProps = struct {
    id: []const u8,
    state: app_mod.Entity(CommandPaletteState),
    app: *App,
    list_id: []const u8,
    input: *element.InputState,
    a11y_label: []const u8 = "Filter commands",
};

const FilterNav = struct {
    app: *App,
    state: app_mod.Entity(CommandPaletteState),
    input: *element.InputState,
    list_id: []const u8,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *FilterNav = @ptrCast(@alignCast(ctx.?));
        const palette = self.app.read(CommandPaletteState, self.state);

        switch (event.key) {
            .down => {
                self.input.focus(element.elementId(self.list_id));
                return true;
            },
            .backspace => {
                if (palette.filter_len == 0) return false;
                palette.filter_len -= 1;
                palette.highlighted_index = 0;
                self.app.notify(self.state.id);
                return true;
            },
            .escape => {
                close(self.app, self.state);
                return true;
            },
            else => return false,
        }
    }

    fn onTextInput(ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool {
        const self: *FilterNav = @ptrCast(@alignCast(ctx.?));
        const palette = self.app.read(CommandPaletteState, self.state);
        for (event.text) |ch| {
            if (palette.filter_len >= filter_capacity) break;
            palette.filter_buf[palette.filter_len] = ch;
            palette.filter_len += 1;
        }
        palette.highlighted_index = 0;
        self.app.notify(self.state.id);
        return true;
    }
};

pub fn commandPaletteFilter(arena: std.mem.Allocator, props: FilterProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);
    const filter_text = props.app.read(CommandPaletteState, props.state).filter();

    const nav = arena.create(FilterNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .input = props.input,
        .list_id = props.list_id,
    };

    var s = style_mod.Style{};
    s.width = .{ .px = 280 };
    s.height = .{ .px = 32 };
    s.padding = .{
        .top = .{ .px = 6 },
        .right = .{ .px = 10 },
        .bottom = .{ .px = 6 },
        .left = .{ .px = 10 },
    };
    s.background = Rgba.fromHex(0xf9fafb);

    return div_mod.div(arena)
        .withId(props.id)
        .withStyle(s)
        .role(.search)
        .a11yName(props.a11y_label)
        .a11yValueText(filter_text)
        .focusable(focus_id, .{ .ctx = nav, .func = FilterNav.onKey })
        .onTextInput(nav, FilterNav.onTextInput);
}

// ---------------------------------------------------------------------------
// List + items
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    state: app_mod.Entity(CommandPaletteState),
    app: *App,
    visible_indices: []const usize,
    registry: *CommandRegistry,
    on_select: SelectHandler,
    a11y_label: []const u8 = "Commands",
};

const ListNav = struct {
    app: *App,
    state: app_mod.Entity(CommandPaletteState),
    visible_indices: []const usize,
    registry: *CommandRegistry,
    on_select: SelectHandler,

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
                setHighlighted(self.app, self.state, idx);
                return;
            }
        }
    }

    fn activate(self: *ListNav, visible_index: i32) void {
        if (visible_index < 0) return;
        const orig = self.visible_indices[@intCast(visible_index)];
        if (self.registry.isDisabled(orig)) return;
        const id = self.registry.idAt(orig) orelse "";
        self.on_select.func(self.on_select.ctx, id, orig);
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
            .enter, .space => {
                self.activate(highlightedIndex(self.app, self.state));
                return true;
            },
            else => return false,
        }
    }
};

pub fn commandPaletteList(arena: std.mem.Allocator, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .visible_indices = props.visible_indices,
        .registry = props.registry,
        .on_select = props.on_select,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .role(.list)
        .a11yName(props.a11y_label)
        .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
}

pub const ItemProps = struct {
    id: []const u8,
    state: app_mod.Entity(CommandPaletteState),
    app: *App,
    index: usize,
    visible_index: usize,
    command_id: []const u8,
    disabled: bool = false,
    a11y_label: ?[]const u8 = null,
    on_select: SelectHandler,
    style_fn: ?ItemStyleFn = null,
    registry: *CommandRegistry,
};

const ItemSelect = struct {
    app: *App,
    state: app_mod.Entity(CommandPaletteState),
    index: usize,
    command_id: []const u8,
    on_select: SelectHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemSelect = @ptrCast(@alignCast(ctx.?));
        setHighlighted(self.app, self.state, @intCast(self.index));
        self.on_select.func(self.on_select.ctx, self.command_id, self.index);
        close(self.app, self.state);
    }
};

pub fn commandPaletteItem(arena: std.mem.Allocator, input: *const element.InputState, props: ItemProps) !*Div {
    const id = element.elementId(props.id);

    props.registry.register(arena, .{
        .index = props.index,
        .id = props.command_id,
        .disabled = props.disabled,
    }) catch @panic("frame arena OOM");

    const item_state = ItemStyleState{
        .highlighted = isHighlighted(props.app, props.state, props.visible_index),
        .hovered = input.isHovered(id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.list_item)
        .a11ySelected(item_state.highlighted);
    const accessible_name = if (props.a11y_label) |label|
        if (label.len > 0) label else props.command_id
    else
        props.command_id;
    if (accessible_name.len > 0) d = d.a11yName(accessible_name);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(item_state));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = 280 };
        s.height = .{ .px = 28 };
        s.padding = .{
            .top = .{ .px = 6 },
            .right = .{ .px = 10 },
            .bottom = .{ .px = 6 },
            .left = .{ .px = 10 },
        };
        s.background = if (item_state.highlighted)
            Rgba.fromHex(0xe5e7eb)
        else if (item_state.hovered)
            Rgba.fromHex(0xf3f4f6)
        else
            Rgba.fromHex(0xffffff);
        d = d.withStyle(s);
    }

    if (!props.disabled) {
        const select = arena.create(ItemSelect) catch @panic("frame arena OOM");
        select.* = .{
            .app = props.app,
            .state = props.state,
            .index = props.index,
            .command_id = props.command_id,
            .on_select = props.on_select,
        };
        d = d.onClick(select, ItemSelect.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Overlay host
// ---------------------------------------------------------------------------

const Host = struct {
    props: Props,

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        close(self.props.app, self.props.state);
    }

    fn dismissMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        dismiss(ctx);
    }

    fn resolveVisible(self: *Host, arena: std.mem.Allocator) ![]usize {
        if (self.props.commands.len > 0) {
            const filter_text = self.props.app.read(CommandPaletteState, self.props.state).filter();
            return visibleIndicesFromSlice(arena, self.props.commands, filter_text);
        }
        const count = if (self.props.command_count > 0)
            self.props.command_count
        else
            self.props.commands.len;
        return visibleIndicesFromFns(
            arena,
            self.props.app,
            self.props.state,
            count,
            self.props.label_ctx,
            self.props.label_fn,
            self.props.keywords_ctx,
            self.props.keywords_fn,
        );
    }

    fn commandId(self: *Host, index: usize) []const u8 {
        if (self.props.commands.len > index) return self.props.commands[index].id;
        if (self.props.id_fn) |id_fn| return id_fn(self.props.id_ctx, index);
        return "";
    }

    fn commandLabel(self: *Host, index: usize, fallback: []const u8) []const u8 {
        if (self.props.commands.len > index and self.props.commands[index].label.len > 0) {
            return self.props.commands[index].label;
        }
        if (self.props.label_fn) |label_fn| {
            const label = label_fn(self.props.label_ctx, index);
            if (label.len > 0) return label;
        }
        return fallback;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const palette = self.props.app.read(CommandPaletteState, self.props.state);
        if (!palette.open) return div_mod.div(arena).sizePx(0, 0).any();

        const visible = try self.resolveVisible(arena);
        remapHighlight(self.props.app, self.props.state, visible);

        var backdrop = div_mod.div(arena)
            .withId("command-palette-backdrop")
            .absolute()
            .wFull()
            .hFull()
            .interactive()
            .bg(Rgba.init(0, 0, 0, 0.45))
            .onMouseDown(self, dismissMouseDown);

        var panel = div_mod.div(arena)
            .withId(self.props.id)
            .interactive()
            .role(.dialog)
            .a11yName(self.props.a11y_label)
            .a11yModal(self.props.modal);
        if (self.props.panel_style) |style_fn| {
            panel = panel.withStyle(style_fn(true));
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 320 };
            s.min_height = .{ .px = 80 };
            s.max_height = .{ .px = 360 };
            s.background = Rgba.fromHex(0xffffff);
            s.corner_radii = geometry.Corners(Pixels).all(8);
            s.padding = .{
                .top = .{ .px = 8 },
                .right = .{ .px = 8 },
                .bottom = .{ .px = 8 },
                .left = .{ .px = 8 },
            };
            panel = panel.withStyle(s);
        }
        panel = panel.onClick(null, struct {
            fn swallow(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
        }.swallow);

        const filter = commandPaletteFilter(arena, .{
            .id = self.props.filter_id,
            .state = self.props.state,
            .app = self.props.app,
            .list_id = self.props.list_id,
            .input = self.props.input,
        });

        var body: *Div = undefined;
        if (self.props.content_fn) |content_fn| {
            const registry = arena.create(CommandRegistry) catch @panic("frame arena OOM");
            registry.* = CommandRegistry.init();
            body = try content_fn(self.props.content_ctx, arena, registry, visible);
        } else {
            const registry = arena.create(CommandRegistry) catch @panic("frame arena OOM");
            registry.* = CommandRegistry.init();
            var list = commandPaletteList(arena, .{
                .id = self.props.list_id,
                .state = self.props.state,
                .app = self.props.app,
                .visible_indices = visible,
                .registry = registry,
                .on_select = self.props.on_select,
            });
            for (visible, 0..) |orig_index, vi| {
                const cmd = if (self.props.commands.len > orig_index)
                    self.props.commands[orig_index]
                else
                    Command{ .id = self.commandId(orig_index), .label = "" };
                const name = try std.fmt.allocPrint(arena, "palette-item-{d}", .{orig_index});
                list = list.childDiv(try commandPaletteItem(arena, self.props.input, .{
                    .id = name,
                    .state = self.props.state,
                    .app = self.props.app,
                    .index = orig_index,
                    .visible_index = vi,
                    .command_id = cmd.id,
                    .disabled = cmd.disabled,
                    .a11y_label = self.commandLabel(orig_index, cmd.id),
                    .on_select = self.props.on_select,
                    .registry = registry,
                }));
            }
            body = list;
        }

        panel = panel.flexCol().gapPx(4).childDiv(filter).childDiv(body);

        const center = div_mod.div(arena)
            .wFull()
            .hFull()
            .flexCol()
            .itemsCenter()
            .justifyCenter()
            .childDiv(panel);

        return backdrop.childDiv(center).any();
    }
};

fn registerOverlay(arena: std.mem.Allocator, props: Props) !void {
    const is_open = props.app.read(CommandPaletteState, props.state).open;
    if (!is_open) return;

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{ .props = props };
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

/// Zero-size main-tree placeholder; registers the command palette overlay when open.
pub fn commandPalette(arena: std.mem.Allocator, props: Props) !*Div {
    try registerOverlay(arena, props);
    return div_mod.div(arena).sizePx(0, 0);
}

// ---------------------------------------------------------------------------
// Global Cmd/Ctrl+K shortcut
// ---------------------------------------------------------------------------

pub const ShortcutProps = struct {
    state: app_mod.Entity(CommandPaletteState),
    app: *App,
    input: *element.InputState,
    filter_id: []const u8 = "command-palette-filter",
};

const ShortcutHost = struct {
    props: ShortcutProps,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ShortcutHost = @ptrCast(@alignCast(ctx.?));
        if (event.key != .k) return false;
        if (!event.modifiers.command and !event.modifiers.control) return false;
        toggle(self.props.app, self.props.state, self.props.input, self.props.filter_id);
        return true;
    }
};

/// Attach a document-level focus target that opens the palette on Cmd/Ctrl+K.
pub fn commandPaletteShortcut(arena: std.mem.Allocator, props: ShortcutProps) *Div {
    const host = arena.create(ShortcutHost) catch @panic("frame arena OOM");
    host.* = .{ .props = props };

    return div_mod.div(arena)
        .withId("command-palette-shortcut")
        .sizePx(0, 0)
        .focusable(element.elementId("command-palette-shortcut"), .{ .ctx = host, .func = ShortcutHost.onKey });
}

/// Register overlay + global Cmd/Ctrl+K shortcut in one call.
pub fn commandPaletteWithShortcut(arena: std.mem.Allocator, props: Props) !*Div {
    const shortcut = commandPaletteShortcut(arena, .{
        .state = props.state,
        .app = props.app,
        .input = props.input,
        .filter_id = props.filter_id,
    });
    try registerOverlay(arena, props);
    return div_mod.div(arena).sizePx(0, 0).childDiv(shortcut);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const a11y_mod = @import("../a11y.zig");

const PaletteFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(CommandPaletteState) = undefined,
    selected_id: ?[]const u8 = null,
    selected_index: usize = 0,

    const commands = [_]Command{
        .{ .id = "new", .label = "New File" },
        .{ .id = "open", .label = "Open File", .keywords = "browse" },
        .{ .id = "save", .label = "Save File" },
    };

    fn itemStyle(state: ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 280 };
        s.height = .{ .px = 28 };
        s.background = if (state.highlighted) Rgba.fromHex(0xbfdbfe) else Rgba.fromHex(0xffffff);
        return s;
    }

    fn onSelect(ctx: ?*anyopaque, id: []const u8, index: usize) void {
        const self: *PaletteFixture = @ptrCast(@alignCast(ctx.?));
        self.selected_id = id;
        self.selected_index = index;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *PaletteFixture = @ptrCast(@alignCast(ctx.?));

        const host = try commandPaletteWithShortcut(arena, .{
            .id = "command-palette",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .commands = &commands,
            .on_select = .{ .ctx = self, .func = onSelect },
        });

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(host).any();
    }
};

test "command palette opens via Cmd+K and closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = PaletteFixture{ .harness = &harness };
    fixture.state = try harness.app.new(CommandPaletteState, .{});
    try harness.setRoot(&fixture, PaletteFixture.render);

    try std.testing.expect(!harness.app.read(CommandPaletteState, fixture.state).open);
    try harness.focusById(element.elementId("command-palette-shortcut"));
    try harness.keyDownWith(.k, .{ .command = true });
    try std.testing.expect(harness.app.read(CommandPaletteState, fixture.state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expectEqual(a11y_mod.Role.dialog, harness.a11yRole("command-palette").?);
    try std.testing.expectEqualStrings("Command palette", harness.a11yName("command-palette").?);
    try std.testing.expect(harness.a11yNode("command-palette").?.modal);
    try std.testing.expectEqual(a11y_mod.Role.search, harness.a11yRole("command-palette-filter").?);
    try std.testing.expectEqual(a11y_mod.Role.list, harness.a11yRole("command-palette-list").?);
    try std.testing.expectEqual(a11y_mod.Role.list_item, harness.a11yRole("palette-item-0").?);
    try std.testing.expectEqualStrings("New File", harness.a11yName("palette-item-0").?);
    try std.testing.expect(harness.a11yNode("palette-item-0").?.pressable);

    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(CommandPaletteState, fixture.state).open);
}

test "command palette filter narrows visible items" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = PaletteFixture{ .harness = &harness };
    fixture.state = try harness.app.new(CommandPaletteState, .{});
    try harness.setRoot(&fixture, PaletteFixture.render);

    open(&harness.app, fixture.state, &harness.input, "command-palette-filter");
    try harness.renderFrame();

    try harness.focusById(element.elementId("command-palette-filter"));
    try harness.textInput("save");
    try harness.renderFrame();
    try std.testing.expectEqualStrings(
        "save",
        harness.a11yNode("command-palette-filter").?.value_text.?,
    );

    // Only "Save File" should remain.
    try std.testing.expect(harness.hitboxBounds(element.elementId("palette-item-2")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("palette-item-0")) == null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("palette-item-1")) == null);
}

test "command palette keyboard select Enter" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = PaletteFixture{ .harness = &harness };
    fixture.state = try harness.app.new(CommandPaletteState, .{});
    try harness.setRoot(&fixture, PaletteFixture.render);

    open(&harness.app, fixture.state, &harness.input, "command-palette-filter");
    try harness.renderFrame();
    try harness.focusById(element.elementId("command-palette-filter"));
    try harness.keyDown(.down);
    try harness.keyDown(.down);
    try harness.keyDown(.enter);
    try std.testing.expect(!harness.app.read(CommandPaletteState, fixture.state).open);
    try std.testing.expectEqualStrings("open", fixture.selected_id.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.selected_index);
}

test "command palette item click selects and closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = PaletteFixture{ .harness = &harness };
    fixture.state = try harness.app.new(CommandPaletteState, .{});
    try harness.setRoot(&fixture, PaletteFixture.render);

    open(&harness.app, fixture.state, &harness.input, "command-palette-filter");
    try harness.renderFrame();
    try harness.clickOn("palette-item-2");
    try std.testing.expect(!harness.app.read(CommandPaletteState, fixture.state).open);
    try std.testing.expectEqualStrings("save", fixture.selected_id.?);
    try std.testing.expectEqual(@as(usize, 2), fixture.selected_index);
}

test "command palette item accessibility press selects and closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = PaletteFixture{ .harness = &harness };
    fixture.state = try harness.app.new(CommandPaletteState, .{});
    try harness.setRoot(&fixture, PaletteFixture.render);

    open(&harness.app, fixture.state, &harness.input, "command-palette-filter");
    try harness.renderFrame();
    try harness.a11yPressOn("palette-item-1");
    try std.testing.expect(!harness.app.read(CommandPaletteState, fixture.state).open);
    try std.testing.expectEqualStrings("open", fixture.selected_id.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.selected_index);
}

test "commandMatchesFilter uses keywords" {
    try std.testing.expect(commandMatchesFilter("Open File", "browse", "bro"));
    try std.testing.expect(!commandMatchesFilter("Save File", null, "bro"));
}
