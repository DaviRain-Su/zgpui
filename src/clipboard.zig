//! In-memory clipboard storage. Used by `App` for copy/paste in text fields
//! and as a fallback when no OS clipboard backend is available.

const std = @import("std");
const platform_mod = @import("platform.zig");

pub const ClipboardBridge = struct {
    ctx: ?*anyopaque = null,
    /// Caller owns the returned slice when non-null.
    pull: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator) anyerror!?[]u8,
    push: *const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void,
};

pub const Clipboard = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Clipboard {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Clipboard) void {
        self.text.deinit(self.gpa);
    }

    pub fn setText(self: *Clipboard, slice: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, slice);
    }

    pub fn getText(self: *const Clipboard) []const u8 {
        return self.text.items;
    }

    pub fn clear(self: *Clipboard) void {
        self.text.clearRetainingCapacity();
    }

    /// Replace in-memory text with OS clipboard content (best-effort).
    pub fn pullFromOs(self: *Clipboard, bridge: ?ClipboardBridge) void {
        const b = bridge orelse return;
        const os_text = b.pull(b.ctx, self.gpa) catch return;
        if (os_text) |text| {
            defer self.gpa.free(text);
            self.setText(text) catch {};
        }
    }

    /// Refresh in-memory text when OS content differs (best-effort).
    pub fn syncFromOs(self: *Clipboard, bridge: ?ClipboardBridge) void {
        const b = bridge orelse return;
        const os_text = b.pull(b.ctx, self.gpa) catch return;
        if (os_text) |text| {
            defer self.gpa.free(text);
            if (!std.mem.eql(u8, text, self.getText())) {
                self.setText(text) catch {};
            }
        }
    }

    /// Write current in-memory text to the OS clipboard (best-effort).
    pub fn pushToOs(self: *const Clipboard, bridge: ?ClipboardBridge) void {
        const b = bridge orelse return;
        b.push(b.ctx, self.getText()) catch {};
    }

    /// Build a bridge that forwards to a `Platform` vtable.
    pub fn bridgeFromPlatform(platform: *const platform_mod.Platform) ?ClipboardBridge {
        if (platform.vtable.get_clipboard_text == null and platform.vtable.set_clipboard_text == null) {
            return null;
        }
        return .{
            .ctx = @constCast(platform),
            .pull = platformPull,
            .push = platformPush,
        };
    }

    fn platformPull(ctx: ?*anyopaque, gpa: std.mem.Allocator) !?[]u8 {
        const plat: *const platform_mod.Platform = @ptrCast(@alignCast(ctx.?));
        return try plat.getClipboardText(gpa);
    }

    fn platformPush(ctx: ?*anyopaque, text: []const u8) !void {
        const plat: *const platform_mod.Platform = @ptrCast(@alignCast(ctx.?));
        try plat.setClipboardText(text);
    }
};

test "Clipboard set and get roundtrip" {
    var cb = Clipboard.init(std.testing.allocator);
    defer cb.deinit();

    try cb.setText("hello");
    try std.testing.expectEqualStrings("hello", cb.getText());

    try cb.setText("world");
    try std.testing.expectEqualStrings("world", cb.getText());

    cb.clear();
    try std.testing.expectEqual(@as(usize, 0), cb.getText().len);
}

test "ClipboardBridge push and pull" {
    const Fake = struct {
        var last_push: ?[]const u8 = null;
        var pull_text: ?[]const u8 = "from-os";

        fn pull(ctx: ?*anyopaque, gpa: std.mem.Allocator) !?[]u8 {
            _ = ctx;
            const text = pull_text orelse return null;
            return try gpa.dupe(u8, text);
        }

        fn push(ctx: ?*anyopaque, text: []const u8) !void {
            _ = ctx;
            last_push = text;
        }
    };

    var cb = Clipboard.init(std.testing.allocator);
    defer cb.deinit();

    const bridge = ClipboardBridge{
        .pull = Fake.pull,
        .push = Fake.push,
    };

    try cb.setText("local");
    cb.pushToOs(bridge);
    try std.testing.expectEqualStrings("local", Fake.last_push.?);

    Fake.pull_text = "external";
    cb.syncFromOs(bridge);
    try std.testing.expectEqualStrings("external", cb.getText());

    Fake.pull_text = "external";
    cb.syncFromOs(bridge);
    try std.testing.expectEqualStrings("external", cb.getText());

    Fake.pull_text = "newer";
    cb.syncFromOs(bridge);
    try std.testing.expectEqualStrings("newer", cb.getText());

    Fake.pull_text = "focus-pull";
    cb.pullFromOs(bridge);
    try std.testing.expectEqualStrings("focus-pull", cb.getText());
}

test "ClipboardBridge push skipped when null" {
    var cb = Clipboard.init(std.testing.allocator);
    defer cb.deinit();
    try cb.setText("unchanged");
    cb.pushToOs(null);
    try std.testing.expectEqualStrings("unchanged", cb.getText());
}
