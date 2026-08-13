//! Kitchen sink stress demo: hotkeys, command palette, dialog fade,
//! virtual list, tabs, form fields, nav chrome, toasts — many systems at once.
//!
//! Run with: zig build run-06_kitchen_sink
//! Hotkeys: Cmd/Ctrl+K palette · Cmd/Ctrl+D dialog · Cmd/Ctrl+T toast · F3 debug HUD

const std = @import("std");
const zgpui = @import("zgpui");

const Rgba = zgpui.Rgba;
const Style = zgpui.style.Style;
const button = zgpui.components.button;
const tabs = zgpui.components.tabs;
const dialog = zgpui.components.dialog;
const text_field = zgpui.components.text_field;
const list = zgpui.components.list;
const toast = zgpui.components.toast;
const command_palette = zgpui.components.command_palette;
const checkbox_group = zgpui.components.checkbox_group;
const otp_field = zgpui.components.otp_field;
const number_field = zgpui.components.number_field;
const meter = zgpui.components.meter;
const menubar = zgpui.components.menubar;
const toolbar = zgpui.components.toolbar;
const drawer = zgpui.components.drawer;
const TextInputState = zgpui.TextInputState;

const otp_length: usize = 5;
const number_max: i64 = 20;

const Demo = struct {
    app: *zgpui.App,
    window: *zgpui.Window = undefined,
    tabs_state: zgpui.Entity(tabs.TabsState) = undefined,
    dialog_state: zgpui.Entity(dialog.DialogState) = undefined,
    palette_state: zgpui.Entity(command_palette.CommandPaletteState) = undefined,
    toast_host: zgpui.Entity(toast.ToastHostState) = undefined,
    list_selected: zgpui.Entity(list.Value.Store) = undefined,
    list_scroll: zgpui.ScrollState = .{},
    text_state: zgpui.Entity(TextInputState) = undefined,
    checkbox_group_state: zgpui.Entity(checkbox_group.CheckboxGroupState) = undefined,
    otp_state: zgpui.Entity(otp_field.Value.Store) = undefined,
    number_state: zgpui.Entity(number_field.Value.Store) = undefined,
    menubar_state: zgpui.Entity(menubar.MenubarState) = undefined,
    menu_state: zgpui.Entity(menubar.MenuState) = undefined,
    toolbar_state: zgpui.Entity(toolbar.ToolbarState) = undefined,
    drawer_open: zgpui.Entity(drawer.OpenValue.Store) = undefined,
    text_resources: zgpui.TextResources = undefined,
    status: [128]u8 = undefined,
    status_len: usize = 0,

    const commands = [_]command_palette.Command{
        .{ .id = "toast", .label = "Show toast", .keywords = "notify" },
        .{ .id = "dialog", .label = "Open dialog", .keywords = "modal" },
        .{ .id = "drawer", .label = "Open drawer", .keywords = "panel" },
        .{ .id = "clear", .label = "Clear status", .keywords = "reset" },
    };

    const checkbox_labels = [_][]const u8{ "Alpha", "Beta", "Gamma" };
    const toolbar_labels = [_][]const u8{ "New", "Save", "Share" };

    fn setStatus(self: *Demo, msg: []const u8) void {
        const n = @min(msg.len, self.status.len);
        @memcpy(self.status[0..n], msg[0..n]);
        self.status_len = n;
        self.app.needs_redraw = true;
    }

    fn statusSlice(self: *const Demo) []const u8 {
        return self.status[0..self.status_len];
    }

    fn label(self: *Demo, arena: std.mem.Allocator, content: []const u8, size: f32, text_color: Rgba) zgpui.Element {
        return zgpui.textEl(arena, &self.text_resources, content).size(size).withColor(text_color).any();
    }

    fn btnStyle(state: button.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 120 };
        s.height = .{ .px = 34 };
        s.corner_radii = zgpui.Corners(f32).all(8);
        s.background = if (state.pressed)
            Rgba.fromHex(0x1d4ed8)
        else if (state.hovered)
            Rgba.fromHex(0x3b82f6)
        else
            Rgba.fromHex(0x2563eb);
        if (state.focus_visible) {
            s.border_widths = zgpui.Edges(f32).all(2);
            s.border_color = Rgba.fromHex(0xfbbf24);
        }
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn tabStyle(state: tabs.TabStyleState) Style {
        var s = Style{};
        s.width = .{ .px = 72 };
        s.height = .{ .px = 30 };
        s.corner_radii = .{ .top_left = 6, .top_right = 6, .bottom_right = 0, .bottom_left = 0 };
        s.background = if (state.selected)
            Rgba.fromHex(0x334155)
        else if (state.hovered)
            Rgba.fromHex(0x1e293b)
        else
            Rgba.fromHex(0x0f172a);
        if (state.focus_visible) {
            s.border_widths = zgpui.Edges(f32).all(2);
            s.border_color = Rgba.fromHex(0xfbbf24);
        }
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn listItemStyle(state: list.ItemStyleState) Style {
        var s = Style{};
        s.height = .{ .px = 28 };
        s.background = if (state.selected)
            Rgba.fromHex(0x1d4ed8)
        else if (state.hovered)
            Rgba.fromHex(0x334155)
        else
            Rgba.fromHex(0x1e293b);
        return s;
    }

    fn fieldStyle(state: text_field.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 280 };
        s.height = .{ .px = 36 };
        s.corner_radii = zgpui.Corners(f32).all(8);
        s.background = Rgba.fromHex(0x1e293b);
        s.border_widths = zgpui.Edges(f32).all(1);
        s.border_color = if (state.focus_visible)
            Rgba.fromHex(0xfbbf24)
        else if (state.focused)
            Rgba.fromHex(0x60a5fa)
        else
            Rgba.fromHex(0x475569);
        return s;
    }

    fn cbItemStyle(state: checkbox_group.ItemStyleState) Style {
        var s = Style{};
        s.width = .{ .px = 22 };
        s.height = .{ .px = 22 };
        s.corner_radii = zgpui.Corners(f32).all(4);
        s.background = if (state.checked) Rgba.fromHex(0x2563eb) else Rgba.fromHex(0x334155);
        if (state.focus_visible) {
            s.border_widths = zgpui.Edges(f32).all(2);
            s.border_color = Rgba.fromHex(0xfbbf24);
        }
        return s;
    }

    fn otpSlotStyle(state: otp_field.SlotStyleState) Style {
        var s = Style{};
        s.width = .{ .px = 36 };
        s.height = .{ .px = 40 };
        s.corner_radii = zgpui.Corners(f32).all(8);
        s.background = Rgba.fromHex(0x1e293b);
        s.border_widths = zgpui.Edges(f32).all(1);
        s.border_color = if (state.active and state.focus_visible)
            Rgba.fromHex(0xfbbf24)
        else if (state.active)
            Rgba.fromHex(0x60a5fa)
        else if (state.filled)
            Rgba.fromHex(0x475569)
        else
            Rgba.fromHex(0x334155);
        return s;
    }

    fn numberStyle(state: number_field.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 96 };
        s.height = .{ .px = 36 };
        s.corner_radii = zgpui.Corners(f32).all(8);
        s.background = Rgba.fromHex(0x1e293b);
        s.border_widths = zgpui.Edges(f32).all(1);
        s.border_color = if (state.focus_visible)
            Rgba.fromHex(0xfbbf24)
        else if (state.focused)
            Rgba.fromHex(0x60a5fa)
        else
            Rgba.fromHex(0x475569);
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn meterTrack(_: meter.StyleState) Style {
        var s = Style{};
        s.width = .{ .px = 260 };
        s.height = .{ .px = 10 };
        s.corner_radii = zgpui.Corners(f32).all(5);
        s.background = Rgba.fromHex(0x1e293b);
        return s;
    }

    fn meterFill(state: meter.StyleState) Style {
        var s = Style{};
        s.height = .{ .px = 10 };
        s.corner_radii = zgpui.Corners(f32).all(5);
        s.background = Rgba.fromHex(0x38bdf8);
        s.width = .{ .percent = state.fraction * 100 };
        return s;
    }

    fn menubarTriggerStyle(state: menubar.TriggerStyleState) Style {
        var s = Style{};
        s.height = .{ .px = 28 };
        s.padding = .{ .top = .{ .px = 4 }, .bottom = .{ .px = 4 }, .left = .{ .px = 10 }, .right = .{ .px = 10 } };
        s.background = if (state.open)
            Rgba.fromHex(0x334155)
        else if (state.focus_visible)
            Rgba.fromHex(0x1e293b)
        else if (state.hovered)
            Rgba.fromHex(0x1e293b)
        else
            Rgba.fromHex(0x0f172a);
        if (state.focus_visible) {
            s.border_widths = zgpui.Edges(f32).all(1);
            s.border_color = Rgba.fromHex(0xfbbf24);
        }
        return s;
    }

    fn toolbarBtnStyle(state: toolbar.ButtonStyleState) Style {
        var s = Style{};
        s.width = .{ .px = 72 };
        s.height = .{ .px = 32 };
        s.corner_radii = zgpui.Corners(f32).all(6);
        s.background = if (state.focus_visible)
            Rgba.fromHex(0x334155)
        else if (state.hovered)
            Rgba.fromHex(0x1e293b)
        else
            Rgba.fromHex(0x0f172a);
        if (state.focus_visible) {
            s.border_widths = zgpui.Edges(f32).all(1);
            s.border_color = Rgba.fromHex(0xfbbf24);
        }
        s.align_items = .center;
        s.justify_content = .center;
        return s;
    }

    fn onOpenDialog(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        dialog.open(self.app, self.dialog_state);
        self.setStatus("dialog open");
    }

    fn onOpenPalette(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        command_palette.open(self.app, self.palette_state, &self.window.input, "palette-filter");
        self.setStatus("palette open (Cmd+K)");
    }

    fn onPushToast(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        _ = toast.push(self.app, self.toast_host, .{
            .message = "Hello from hotkey / command",
            .ttl_frames = 120,
        }) catch {};
        self.setStatus("toast pushed");
    }

    fn onOpenDrawer(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        drawer.openDrawer(self.app, .{ .uncontrolled = self.drawer_open });
        self.setStatus("drawer open");
    }

    fn onCommand(ctx: ?*anyopaque, id: []const u8, _: usize) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, id, "toast")) {
            onPushToast(self);
        } else if (std.mem.eql(u8, id, "dialog")) {
            onOpenDialog(self);
        } else if (std.mem.eql(u8, id, "drawer")) {
            onOpenDrawer(self);
        } else if (std.mem.eql(u8, id, "clear")) {
            self.setStatus("ready");
        }
    }

    fn onOtpComplete(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const msg = std.fmt.bufPrint(&self.status, "OTP complete: {s}", .{text}) catch return;
        self.setStatus(msg);
    }

    fn onToolbarPress(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const idx = toolbar.focusedIndex(self.app, self.toolbar_state);
        const msg = std.fmt.bufPrint(&self.status, "toolbar: {s}", .{toolbar_labels[idx]}) catch return;
        self.setStatus(msg);
    }

    fn onMenuSelect(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        self.setStatus("File menu action");
    }

    fn dialogBody(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*zgpui.Div {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        return zgpui.div(arena)
            .flexCol()
            .gapPx(12)
            .child(self.label(arena, "Kitchen sink dialog", 16, Rgba.fromHex(0x0f172a)))
            .child(self.label(arena, "Escape fades out when timeline is set.", 13, Rgba.fromHex(0x475569)))
            .childDiv(button.button(arena, &self.window.input, .{
                .id = "dialog-ok",
                .label = "Close",
                .on_press = .{ .ctx = self, .func = onDialogOk },
                .style_fn = btnStyle,
            }).child(self.label(arena, "Close", 14, Rgba.white)));
    }

    fn onDialogOk(ctx: ?*anyopaque) void {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        dialog.close(self.app, self.dialog_state, .{
            .timeline = &self.window.timeline,
            .id = "sink-dialog",
        });
        self.setStatus("dialog closing…");
    }

    fn drawerBody(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*zgpui.Div {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        return zgpui.div(arena)
            .flexCol()
            .gapPx(8)
            .child(self.label(arena, "Side drawer panel", 16, Rgba.fromHex(0x0f172a)))
            .child(self.label(arena, "Click backdrop or Escape to dismiss.", 13, Rgba.fromHex(0x475569)));
    }

    fn buildFileMenu(ctx: ?*anyopaque, arena: std.mem.Allocator, registry: *menubar.MenuRegistry) !*zgpui.Div {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const app = self.app;
        const input = &self.window.input;

        var menu_list = menubar.menuList(arena, .{
            .id = "sink-file-menu-list",
            .state = self.menu_state,
            .app = app,
            .item_count = 2,
            .registry = registry,
        });

        const items = [_]struct { id: []const u8, label: []const u8 }{
            .{ .id = "file-new", .label = "New" },
            .{ .id = "file-quit", .label = "Quit" },
        };
        for (items, 0..) |item, i| {
            menu_list = menu_list.childDiv((try menubar.menuItem(arena, input, .{
                .id = item.id,
                .state = self.menu_state,
                .app = app,
                .index = i,
                .on_select = .{ .ctx = self, .func = onMenuSelect },
                .registry = registry,
            })).child(self.label(arena, item.label, 13, Rgba.fromHex(0x0f172a))));
        }
        return menu_list;
    }

    fn renderListItem(ctx: ?*anyopaque, arena: std.mem.Allocator, index: usize, state: list.ItemStyleState) anyerror!*zgpui.Div {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const text = try std.fmt.allocPrint(arena, "row {d}", .{index});
        const id = try std.fmt.allocPrint(arena, "row-{d}", .{index});
        return list.item(arena, self.app, &self.window.input, .{
            .id = id,
            .index = index,
            .selected = .{ .uncontrolled = self.list_selected },
            .list_id = "big-list",
            .style_fn = listItemStyle,
        }).child(self.label(arena, text, 13, if (state.selected) Rgba.white else Rgba.fromHex(0xcbd5e1)));
    }

    fn renderFormPanel(self: *Demo, arena: std.mem.Allocator, input: *zgpui.element.InputState, panel: *zgpui.Div) !*zgpui.Div {
        const app = self.app;
        const cb_value: checkbox_group.Value = .{ .uncontrolled = self.checkbox_group_state };
        const otp_value: otp_field.Value = .{ .uncontrolled = self.otp_state };
        const num_value: number_field.Value = .{ .uncontrolled = self.number_state };

        const otp_text = otp_field.readText(app, otp_value);
        const otp_len: f32 = @floatFromInt(otp_text.len);
        const otp_frac = otp_len / @as(f32, @floatFromInt(otp_length));
        const n = number_field.readValue(app, num_value, 0, number_max);
        const n_text = try std.fmt.allocPrint(arena, "{d}", .{n});

        var cb_group = checkbox_group.group(arena, .{ .id = "prefs-group" }).gapPx(8);
        for (checkbox_labels, 0..) |name, i| {
            const cb_id = try std.fmt.allocPrint(arena, "cb-{d}", .{i});
            cb_group = cb_group.childDiv(zgpui.div(arena)
                .flexRow()
                .gapPx(8)
                .itemsCenter()
                .childDiv(checkbox_group.item(arena, app, input, .{
                    .id = cb_id,
                    .value = cb_value,
                    .index = i,
                    .style_fn = cbItemStyle,
                }))
                .child(self.label(arena, name, 13, Rgba.fromHex(0xcbd5e1))));
        }

        const otp_el = otp_field.otpField(arena, app, input, .{
            .id = "sink-otp",
            .value = otp_value,
            .length = otp_length,
            .on_complete = .{ .ctx = self, .func = onOtpComplete },
            .slot_style_fn = otpSlotStyle,
        });

        const number_el = number_field.numberField(arena, app, input, .{
            .id = "sink-number",
            .value = num_value,
            .min = 0,
            .max = number_max,
            .step = 1,
            .style_fn = numberStyle,
        }).child(self.label(arena, n_text, 15, Rgba.white));

        const meter_el = meter.root(arena, .{
            .id = "otp-meter",
            .value = otp_frac,
            .min = 0,
            .max = 1,
            .track_style_fn = meterTrack,
            .indicator_style_fn = meterFill,
        });

        return panel
            .child(self.label(arena, "Form — checkbox group, OTP, number, meter", 14, Rgba.fromHex(0xcbd5e1)))
            .childDiv(cb_group)
            .child(self.label(arena, "OTP (5 digits)", 13, Rgba.fromHex(0x94a3b8)))
            .childDiv(otp_el)
            .child(self.label(arena, "Number (↑↓ / +/-)", 13, Rgba.fromHex(0x94a3b8)))
            .childDiv(number_el)
            .child(self.label(arena, "OTP fill progress", 13, Rgba.fromHex(0x94a3b8)))
            .childDiv(meter_el);
    }

    fn renderNavPanel(self: *Demo, arena: std.mem.Allocator, win: *zgpui.Window, panel: *zgpui.Div) !*zgpui.Div {
        const app = self.app;
        const input = &win.input;

        const bar = menubar.menubar(arena, input, .{
            .id = "sink-menubar",
            .menubar_state = self.menubar_state,
            .menu_state = self.menu_state,
            .app = app,
            .item_count = 1,
            .list_id = "sink-file-menu-list",
        }).childDiv(menubar.menubarItem(arena, .{
            .id = "mb-file",
            .menubar_state = self.menubar_state,
            .menu_state = self.menu_state,
            .app = app,
            .input = input,
            .index = 0,
            .menubar_id = "sink-menubar",
            .list_id = "sink-file-menu-list",
            .style_fn = menubarTriggerStyle,
        }).child(self.label(arena, "File", 13, Rgba.white)));

        _ = try menubar.menubarMenu(arena, .{
            .id = "menu-file",
            .menubar_state = self.menubar_state,
            .menu_state = self.menu_state,
            .item_index = 0,
            .trigger_id = "mb-file",
            .overlays = &win.overlays,
            .app = app,
            .frame = &win.frame_state,
            .input = input,
            .viewport = win.platform_window.logicalSize(),
            .list_id = "sink-file-menu-list",
            .content_ctx = self,
            .content_fn = buildFileMenu,
        });

        var tb = toolbar.toolbar(arena, .{
            .id = "sink-toolbar",
            .state = self.toolbar_state,
            .app = app,
            .item_count = toolbar_labels.len,
        }).gapPx(4);
        for (toolbar_labels, 0..) |name, i| {
            const tb_id = try std.fmt.allocPrint(arena, "tb-{d}", .{i});
            tb = tb.childDiv(toolbar.toolbarButton(arena, .{
                .id = tb_id,
                .state = self.toolbar_state,
                .app = app,
                .input = input,
                .index = i,
                .toolbar_id = "sink-toolbar",
                .on_press = .{ .ctx = self, .func = onToolbarPress },
                .style_fn = toolbarBtnStyle,
            }).child(self.label(arena, name, 13, Rgba.fromHex(0xcbd5e1))));
        }

        _ = try drawer.drawer(arena, .{
            .id = "sink-drawer",
            .open = .{ .uncontrolled = self.drawer_open },
            .side = .right,
            .overlays = &win.overlays,
            .app = app,
            .content_ctx = self,
            .content_fn = drawerBody,
        });

        const drawer_btn = button.button(arena, input, .{
            .id = "btn-drawer",
            .label = "Drawer",
            .on_press = .{ .ctx = self, .func = onOpenDrawer },
            .style_fn = btnStyle,
        }).child(self.label(arena, "Open drawer", 14, Rgba.white));

        return panel
            .child(self.label(arena, "Nav — menubar, toolbar, drawer", 14, Rgba.fromHex(0xcbd5e1)))
            .childDiv(bar)
            .childDiv(tb)
            .childDiv(drawer_btn);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, win: *zgpui.Window) anyerror!zgpui.Element {
        const self: *Demo = @ptrCast(@alignCast(ctx.?));
        const app = self.app;
        const input = &win.input;

        _ = try dialog.dialogWithContent(arena, .{
            .id = "sink-dialog",
            .state = self.dialog_state,
            .overlays = &win.overlays,
            .app = app,
            .timeline = &win.timeline,
        }, self, dialogBody);

        _ = try toast.toastHost(arena, .{
            .id = "toasts",
            .host = self.toast_host,
            .overlays = &win.overlays,
            .app = app,
            .timeline = &win.timeline,
        });

        _ = try command_palette.commandPalette(arena, .{
            .id = "palette",
            .state = self.palette_state,
            .overlays = &win.overlays,
            .app = app,
            .input = input,
            .viewport = win.platform_window.logicalSize(),
            .filter_id = "palette-filter",
            .commands = &commands,
            .on_select = .{ .ctx = self, .func = onCommand },
        });

        const tab_names = [_][]const u8{ "Controls", "List", "Text", "Form", "Nav" };
        const tab_ids = [_][]const u8{ "tab-controls", "tab-list", "tab-text", "tab-form", "tab-nav" };
        const tab_value: tabs.Value = .{ .uncontrolled = self.tabs_state };
        var tab_list = tabs.list(arena, app, .{
            .id = "sink-tabs",
            .value = tab_value,
            .tab_count = tab_names.len,
        }).gapPx(4);
        for (tab_names, tab_ids, 0..) |name, id, i| {
            tab_list = tab_list.childDiv(tabs.tab(arena, app, input, .{
                .id = id,
                .value = tab_value,
                .index = i,
                .list_id = "sink-tabs",
                .style_fn = tabStyle,
            }).child(self.label(arena, name, 13, Rgba.white)));
        }

        const selected = tabs.selectedIndex(app, tab_value);
        var panel = zgpui.div(arena).flexCol().wFull().grow().gapPx(12).padPx(12).bg(Rgba.fromHex(0x0f172a)).rounded(8);

        if (selected == 0) {
            panel = panel
                .childDiv(zgpui.div(arena).flexRow().gapPx(10)
                    .childDiv(button.button(arena, input, .{
                        .id = "btn-palette",
                        .label = "Palette",
                        .on_press = .{ .ctx = self, .func = onOpenPalette },
                        .style_fn = btnStyle,
                    }).child(self.label(arena, "Palette", 14, Rgba.white)))
                    .childDiv(button.button(arena, input, .{
                        .id = "btn-dialog",
                        .label = "Dialog",
                        .on_press = .{ .ctx = self, .func = onOpenDialog },
                        .style_fn = btnStyle,
                    }).child(self.label(arena, "Dialog", 14, Rgba.white)))
                    .childDiv(button.button(arena, input, .{
                        .id = "btn-toast",
                        .label = "Toast",
                        .on_press = .{ .ctx = self, .func = onPushToast },
                        .style_fn = btnStyle,
                    }).child(self.label(arena, "Toast", 14, Rgba.white))))
                .child(self.label(arena, "Yellow ring = focus-visible (Tab). Cmd/Ctrl+K/D/T · F3 = debug HUD.", 13, Rgba.fromHex(0x94a3b8)));
        } else if (selected == 1) {
            const list_el = try list.list(arena, input, .{
                .app = app,
                .id = "big-list",
                .item_count = 500,
                .item_height = 28,
                .viewport_width = 420,
                .viewport_height = 260,
                .item_fn = renderListItem,
                .item_ctx = self,
                .scroll_state = &self.list_scroll,
                .selected = .{ .uncontrolled = self.list_selected },
                .keyboard = true,
                .overscan = 3,
            });
            panel = panel
                .child(self.label(arena, "Virtual list — 500 rows", 14, Rgba.fromHex(0xcbd5e1)))
                .child(list_el);
        } else if (selected == 2) {
            const field = text_field.textField(arena, input, app, .{
                .id = "notes",
                .value = .{ .uncontrolled = self.text_state },
                .resources = &self.text_resources,
                .style_fn = fieldStyle,
            });
            panel = panel
                .child(self.label(arena, "Text field — Cmd+C/V/Z work via clipboard/undo", 14, Rgba.fromHex(0xcbd5e1)))
                .childDiv(field);
        } else if (selected == 3) {
            panel = try self.renderFormPanel(arena, input, panel);
        } else {
            panel = try self.renderNavPanel(arena, win, panel);
        }

        const status = if (self.status_len == 0) "ready" else self.statusSlice();

        return zgpui.div(arena)
            .flexCol()
            .wFull()
            .hFull()
            .padPx(20)
            .gapPx(12)
            .bg(Rgba.fromHex(0x020617))
            .child(self.label(arena, "zgpui kitchen sink", 22, Rgba.white))
            .child(self.label(arena, status, 13, Rgba.fromHex(0x38bdf8)))
            .childDiv(tab_list)
            .childDiv(panel)
            .any();
    }

    fn bindHotkeys(self: *Demo) !void {
        const open_palette = zgpui.actionId("sink.open_palette");
        const open_dialog = zgpui.actionId("sink.open_dialog");
        const push_toast = zgpui.actionId("sink.push_toast");
        const toggle_hud = zgpui.actionId("sink.toggle_hud");

        try self.window.hotkeys.keymap.bind(.{ .key = .k, .modifiers = .{ .command = true } }, open_palette);
        try self.window.hotkeys.keymap.bind(.{ .key = .k, .modifiers = .{ .control = true } }, open_palette);
        try self.window.hotkeys.keymap.bind(.{ .key = .d, .modifiers = .{ .command = true } }, open_dialog);
        try self.window.hotkeys.keymap.bind(.{ .key = .d, .modifiers = .{ .control = true } }, open_dialog);
        try self.window.hotkeys.keymap.bind(.{ .key = .t, .modifiers = .{ .command = true } }, push_toast);
        try self.window.hotkeys.keymap.bind(.{ .key = .t, .modifiers = .{ .control = true } }, push_toast);
        try self.window.hotkeys.keymap.bind(.{ .key = .f3 }, toggle_hud);

        self.window.hotkeys.on(open_palette, self, onOpenPalette);
        self.window.hotkeys.on(open_dialog, self, onOpenDialog);
        self.window.hotkeys.on(push_toast, self, onPushToast);
        self.window.hotkeys.on(toggle_hud, self, struct {
            fn toggle(ctx: ?*anyopaque) void {
                const state: *Demo = @ptrCast(@alignCast(ctx.?));
                state.window.debug_hud = !state.window.debug_hud;
                if (state.window.debug_hud) state.window.enableProfiler(true);
                state.window.markDirty();
            }
        }.toggle);
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
        .title = "zgpui kitchen sink",
        .size = .{ .width = 720, .height = 560 },
    });
    defer win.deinit();

    var demo = Demo{ .app = &app };
    demo.window = win;
    demo.tabs_state = try app.new(tabs.TabsState, .{});
    demo.dialog_state = try app.new(dialog.DialogState, .{});
    demo.palette_state = try app.new(command_palette.CommandPaletteState, .{});
    demo.toast_host = try app.new(toast.ToastHostState, .{});
    demo.list_selected = try app.new(list.Value.Store, .{ .value = 0 });
    demo.text_state = try app.new(TextInputState, try TextInputState.initWithText(gpa, "type here"));
    demo.checkbox_group_state = try app.new(checkbox_group.CheckboxGroupState, .{});
    demo.otp_state = try app.new(otp_field.Value.Store, .{ .value = .{} });
    demo.number_state = try app.new(number_field.Value.Store, .{ .value = 4 });
    demo.menubar_state = try app.new(menubar.MenubarState, .{});
    demo.menu_state = try app.new(menubar.MenuState, .{});
    demo.toolbar_state = try app.new(toolbar.ToolbarState, .{});
    demo.drawer_open = try app.new(drawer.OpenValue.Store, .{ .value = false });
    demo.setStatus("ready — Cmd/Ctrl+K · F3 HUD");

    try demo.bindHotkeys();

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
