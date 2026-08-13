//! Global/window-level keybinding dispatch — runs after overlays and before
//! the main frame so modal dialogs win, but app-level shortcuts (undo, etc.)
//! still work when no modal is open.

const std = @import("std");
const platform = @import("platform.zig");

pub const max_bindings = 64;
pub const max_handlers = 64;

pub const Chord = struct {
    key: platform.Key,
    modifiers: platform.Modifiers = .{},

    pub fn matches(self: Chord, event: platform.KeyEvent) bool {
        return self.key == event.key and modifiersEqual(self.modifiers, event.modifiers);
    }
};

pub const ActionId = u64;

pub fn actionId(name: []const u8) ActionId {
    return std.hash.Wyhash.hash(0x7a1b0e55, name);
}

pub const Binding = struct {
    chord: Chord,
    action: ActionId,
};

pub const BindError = error{
    KeymapFull,
    DuplicateBinding,
};

pub const Keymap = struct {
    bindings: [max_bindings]Binding = undefined,
    count: u8 = 0,

    pub fn init() Keymap {
        return .{};
    }

    pub fn bind(self: *Keymap, chord: Chord, action: ActionId) BindError!void {
        for (self.bindings[0..self.count]) |existing| {
            if (existing.chord.key == chord.key and
                modifiersEqual(existing.chord.modifiers, chord.modifiers))
            {
                return error.DuplicateBinding;
            }
        }
        if (self.count >= max_bindings) return error.KeymapFull;
        self.bindings[self.count] = .{ .chord = chord, .action = action };
        self.count += 1;
    }

    pub fn unbind(self: *Keymap, chord: Chord) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const existing = self.bindings[i].chord;
            if (existing.key == chord.key and modifiersEqual(existing.modifiers, chord.modifiers)) {
                self.count -= 1;
                if (i < self.count) self.bindings[i] = self.bindings[self.count];
                return;
            }
        }
    }

    pub fn match(self: *const Keymap, event: platform.KeyEvent) ?ActionId {
        for (self.bindings[0..self.count]) |binding| {
            if (binding.chord.matches(event)) return binding.action;
        }
        return null;
    }
};

const HandlerEntry = struct {
    action: ActionId = 0,
    ctx: ?*anyopaque = null,
    func: ?*const fn (?*anyopaque) void = null,

    fn isEmpty(self: HandlerEntry) bool {
        return self.func == null;
    }
};

pub const HotkeyRouter = struct {
    keymap: Keymap = .{},
    handlers: [max_handlers]HandlerEntry = [_]HandlerEntry{.{}} ** max_handlers,
    handler_count: u8 = 0,

    pub fn init() HotkeyRouter {
        return .{};
    }

    pub fn on(
        self: *HotkeyRouter,
        action: ActionId,
        ctx: ?*anyopaque,
        func: *const fn (?*anyopaque) void,
    ) void {
        for (self.handlers[0..self.handler_count]) |*entry| {
            if (entry.action == action) {
                entry.ctx = ctx;
                entry.func = func;
                return;
            }
        }
        if (self.handler_count >= max_handlers) return;
        self.handlers[self.handler_count] = .{
            .action = action,
            .ctx = ctx,
            .func = func,
        };
        self.handler_count += 1;
    }

    pub fn dispatch(self: *HotkeyRouter, event: platform.KeyEvent) bool {
        const action = self.keymap.match(event) orelse return false;
        for (self.handlers[0..self.handler_count]) |entry| {
            if (entry.action == action) {
                if (entry.func) |handler| {
                    handler(entry.ctx);
                    return true;
                }
            }
        }
        return false;
    }
};

fn modifiersEqual(a: platform.Modifiers, b: platform.Modifiers) bool {
    const Bits = @Int(.unsigned, @bitSizeOf(platform.Modifiers));
    return @as(Bits, @bitCast(a)) == @as(Bits, @bitCast(b));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "chord matches key and modifiers" {
    const chord = Chord{ .key = .k, .modifiers = .{ .command = true } };
    try std.testing.expect(chord.matches(.{ .key = .k, .modifiers = .{ .command = true } }));
    try std.testing.expect(!chord.matches(.{ .key = .k }));
    try std.testing.expect(!chord.matches(.{ .key = .j, .modifiers = .{ .command = true } }));
}

test "actionId is stable" {
    try std.testing.expectEqual(actionId("undo"), actionId("undo"));
    try std.testing.expect(actionId("undo") != actionId("redo"));
}

test "keymap bind match unbind" {
    var map = Keymap.init();
    const undo = actionId("undo");
    const redo = actionId("redo");
    const undo_chord = Chord{ .key = .z, .modifiers = .{ .command = true } };
    const redo_chord = Chord{ .key = .z, .modifiers = .{ .command = true, .shift = true } };

    try map.bind(undo_chord, undo);
    try map.bind(redo_chord, redo);
    try std.testing.expectEqual(undo, map.match(.{ .key = .z, .modifiers = .{ .command = true } }).?);
    try std.testing.expectEqual(redo, map.match(.{ .key = .z, .modifiers = .{ .command = true, .shift = true } }).?);
    try std.testing.expect(map.match(.{ .key = .y, .modifiers = .{ .command = true } }) == null);

    try std.testing.expectError(error.DuplicateBinding, map.bind(undo_chord, redo));

    map.unbind(undo_chord);
    try std.testing.expect(map.match(.{ .key = .z, .modifiers = .{ .command = true } }) == null);
    try std.testing.expectEqual(redo, map.match(.{ .key = .z, .modifiers = .{ .command = true, .shift = true } }).?);
}

test "hotkey router dispatch" {
    var router = HotkeyRouter.init();
    const toggle = actionId("palette.toggle");
    const chord = Chord{ .key = .k, .modifiers = .{ .command = true } };
    try router.keymap.bind(chord, toggle);

    var fired: u32 = 0;
    const handler = struct {
        fn cb(ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    }.cb;

    router.on(toggle, &fired, handler);

    try std.testing.expect(!router.dispatch(.{ .key = .k }));
    try std.testing.expect(router.dispatch(.{ .key = .k, .modifiers = .{ .command = true } }));
    try std.testing.expectEqual(@as(u32, 1), fired);
    try std.testing.expect(!router.dispatch(.{ .key = .k, .modifiers = .{ .command = true, .shift = true } }));
}

test "keymap full" {
    var map = Keymap.init();
    var i: u8 = 0;
    while (i < max_bindings) : (i += 1) {
        const key: platform.Key = @enumFromInt(@intFromEnum(platform.Key.a) + i);
        try map.bind(.{ .key = key }, actionId("action"));
    }
    try std.testing.expectError(error.KeymapFull, map.bind(.{ .key = .unknown }, actionId("overflow")));
}
