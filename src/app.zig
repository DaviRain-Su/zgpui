//! Entity/context state model, modeled on gpui's `app.rs`.
//!
//! `App` owns all entity state. An `Entity(T)` is a typed, copyable handle
//! to state owned by the app. Observers are notified when an entity calls
//! `notify`; subscribers receive typed events sent with `emit`.
//!
//! Unlike gpui there is no closure-based `update`: read state with
//! `app.read(T, handle)`, mutate it directly, then call `app.notify(...)`.

const std = @import("std");
const clipboard_mod = @import("clipboard.zig");

pub const EntityId = enum(u64) {
    _,

    pub fn format(self: EntityId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("EntityId({d})", .{@intFromEnum(self)});
    }
};

pub fn Entity(comptime T: type) type {
    return struct {
        id: EntityId,

        pub const State = T;
    };
}

/// Handle returned by `observe`/`subscribe`; pass to `unsubscribe` to cancel.
pub const SubscriptionId = enum(u64) { _ };

const AnyEntity = struct {
    ptr: *anyopaque,
    type_name: []const u8,
    destroy: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) void,
};

const Observer = struct {
    id: SubscriptionId,
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, app: *App, entity_id: EntityId) void,
};

const Subscriber = struct {
    id: SubscriptionId,
    event_type_name: []const u8,
    ctx: ?*anyopaque,
    /// `event` points at a value of the subscribed event type; only valid
    /// during the callback.
    func: *const fn (ctx: ?*anyopaque, app: *App, entity_id: EntityId, event: *const anyopaque) void,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    clipboard: clipboard_mod.Clipboard,
    /// Set by `Window.init` when the platform exposes OS clipboard APIs.
    clipboard_bridge: ?clipboard_mod.ClipboardBridge = null,
    entities: std.AutoHashMapUnmanaged(EntityId, AnyEntity),
    observers: std.AutoHashMapUnmanaged(EntityId, std.ArrayList(Observer)),
    subscribers: std.AutoHashMapUnmanaged(EntityId, std.ArrayList(Subscriber)),
    pending_notifications: std.ArrayList(EntityId),
    next_entity_id: u64,
    next_subscription_id: u64,
    /// Set whenever any entity notifies; upper layers clear it after
    /// scheduling a redraw.
    needs_redraw: bool,

    pub fn init(gpa: std.mem.Allocator) App {
        return .{
            .gpa = gpa,
            .clipboard = clipboard_mod.Clipboard.init(gpa),
            .entities = .empty,
            .observers = .empty,
            .subscribers = .empty,
            .pending_notifications = .empty,
            .next_entity_id = 0,
            .next_subscription_id = 0,
            .needs_redraw = false,
        };
    }

    /// Write app clipboard and mirror to the OS when a bridge is installed.
    pub fn setClipboardText(self: *App, text: []const u8) !void {
        try self.clipboard.setText(text);
        self.clipboard.pushToOs(self.clipboard_bridge);
    }

    /// Refresh from the OS when content differs, then return in-memory text.
    pub fn clipboardTextForPaste(self: *App) []const u8 {
        self.clipboard.syncFromOs(self.clipboard_bridge);
        return self.clipboard.getText();
    }

    /// Pull OS clipboard into the app (e.g. on window focus).
    pub fn pullClipboardFromOs(self: *App) void {
        self.clipboard.pullFromOs(self.clipboard_bridge);
    }

    pub fn deinit(self: *App) void {
        self.clipboard.deinit();
        var entity_it = self.entities.valueIterator();
        while (entity_it.next()) |entity| {
            entity.destroy(entity.ptr, self.gpa);
        }
        self.entities.deinit(self.gpa);

        var observer_it = self.observers.valueIterator();
        while (observer_it.next()) |list| list.deinit(self.gpa);
        self.observers.deinit(self.gpa);

        var subscriber_it = self.subscribers.valueIterator();
        while (subscriber_it.next()) |list| list.deinit(self.gpa);
        self.subscribers.deinit(self.gpa);

        self.pending_notifications.deinit(self.gpa);
    }

    // ------------------------------------------------------------------
    // Entities
    // ------------------------------------------------------------------

    /// Move `value` into app-owned heap storage and return a typed handle.
    pub fn new(self: *App, comptime T: type, value: T) !Entity(T) {
        const ptr = try self.gpa.create(T);
        errdefer self.gpa.destroy(ptr);
        ptr.* = value;

        const id: EntityId = @enumFromInt(self.next_entity_id);
        self.next_entity_id += 1;

        try self.entities.put(self.gpa, id, .{
            .ptr = ptr,
            .type_name = @typeName(T),
            .destroy = struct {
                fn destroy(erased: *anyopaque, gpa: std.mem.Allocator) void {
                    const typed: *T = @ptrCast(@alignCast(erased));
                    if (comptime std.meta.hasFn(T, "deinit")) {
                        const fn_info = @typeInfo(@TypeOf(T.deinit)).@"fn";
                        if (fn_info.params.len == 1) {
                            typed.deinit();
                        } else {
                            typed.deinit(gpa);
                        }
                    }
                    gpa.destroy(typed);
                }
            }.destroy,
        });
        return .{ .id = id };
    }

    /// Access an entity's state. The pointer stays valid until the entity is
    /// released.
    pub fn read(self: *App, comptime T: type, handle: Entity(T)) *T {
        const entity = self.entities.get(handle.id) orelse
            std.debug.panic("read of released entity {f}", .{handle.id});
        std.debug.assert(std.mem.eql(u8, entity.type_name, @typeName(T)));
        return @ptrCast(@alignCast(entity.ptr));
    }

    pub fn exists(self: *App, id: EntityId) bool {
        return self.entities.contains(id);
    }

    /// Destroy an entity and drop its observers/subscribers.
    pub fn release(self: *App, id: EntityId) void {
        if (self.entities.fetchRemove(id)) |kv| {
            kv.value.destroy(kv.value.ptr, self.gpa);
        }
        if (self.observers.fetchRemove(id)) |kv| {
            var list = kv.value;
            list.deinit(self.gpa);
        }
        if (self.subscribers.fetchRemove(id)) |kv| {
            var list = kv.value;
            list.deinit(self.gpa);
        }
    }

    // ------------------------------------------------------------------
    // Notify / observe
    // ------------------------------------------------------------------

    /// Mark an entity as changed. Observers run on the next `flushEffects`.
    pub fn notify(self: *App, id: EntityId) void {
        self.needs_redraw = true;
        self.pending_notifications.append(self.gpa, id) catch return;
    }

    /// Observe changes (notify calls) of `watched`.
    pub fn observe(
        self: *App,
        watched: EntityId,
        ctx: ?*anyopaque,
        func: *const fn (ctx: ?*anyopaque, app: *App, entity_id: EntityId) void,
    ) !SubscriptionId {
        const sub_id: SubscriptionId = @enumFromInt(self.next_subscription_id);
        self.next_subscription_id += 1;

        const gop = try self.observers.getOrPut(self.gpa, watched);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.gpa, .{ .id = sub_id, .ctx = ctx, .func = func });
        return sub_id;
    }

    /// Run all pending observer notifications (deduplicated, in first-notify
    /// order). Call once per frame after event handling.
    pub fn flushEffects(self: *App) void {
        // Notifications appended during flushing are processed in the same
        // pass, with a safety cap against infinite notify loops.
        var processed: usize = 0;
        var guard: usize = 0;
        while (processed < self.pending_notifications.items.len) {
            guard += 1;
            if (guard > 10_000) {
                std.log.warn("flushEffects: notify loop detected, aborting", .{});
                break;
            }
            const id = self.pending_notifications.items[processed];
            processed += 1;

            // Skip duplicates already handled this flush.
            var duplicate = false;
            for (self.pending_notifications.items[0 .. processed - 1]) |earlier| {
                if (earlier == id) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            if (self.observers.get(id)) |list| {
                for (list.items) |observer| {
                    observer.func(observer.ctx, self, id);
                }
            }
        }
        self.pending_notifications.clearRetainingCapacity();
    }

    // ------------------------------------------------------------------
    // Typed events (emit / subscribe)
    // ------------------------------------------------------------------

    /// Subscribe to `Event` values emitted by `emitter`.
    pub fn subscribe(
        self: *App,
        comptime Event: type,
        emitter: EntityId,
        ctx: ?*anyopaque,
        comptime func: fn (ctx: ?*anyopaque, app: *App, entity_id: EntityId, event: *const Event) void,
    ) !SubscriptionId {
        const sub_id: SubscriptionId = @enumFromInt(self.next_subscription_id);
        self.next_subscription_id += 1;

        const gop = try self.subscribers.getOrPut(self.gpa, emitter);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.gpa, .{
            .id = sub_id,
            .event_type_name = @typeName(Event),
            .ctx = ctx,
            .func = struct {
                fn call(c: ?*anyopaque, app: *App, entity_id: EntityId, event: *const anyopaque) void {
                    func(c, app, entity_id, @ptrCast(@alignCast(event)));
                }
            }.call,
        });
        return sub_id;
    }

    /// Synchronously dispatch `event` to subscribers of `emitter` that
    /// subscribed with the same event type.
    pub fn emit(self: *App, comptime Event: type, emitter: EntityId, event: Event) void {
        const list = self.subscribers.get(emitter) orelse return;
        for (list.items) |subscriber| {
            if (std.mem.eql(u8, subscriber.event_type_name, @typeName(Event))) {
                subscriber.func(subscriber.ctx, self, emitter, &event);
            }
        }
    }

    pub fn unsubscribe(self: *App, sub_id: SubscriptionId) void {
        var observer_it = self.observers.valueIterator();
        while (observer_it.next()) |list| {
            for (list.items, 0..) |observer, i| {
                if (observer.id == sub_id) {
                    _ = list.swapRemove(i);
                    return;
                }
            }
        }
        var subscriber_it = self.subscribers.valueIterator();
        while (subscriber_it.next()) |list| {
            for (list.items, 0..) |subscriber, i| {
                if (subscriber.id == sub_id) {
                    _ = list.swapRemove(i);
                    return;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Counter = struct {
    count: i32 = 0,
};

test "entity create, read, mutate, release" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const counter = try app.new(Counter, .{ .count = 1 });
    try std.testing.expectEqual(@as(i32, 1), app.read(Counter, counter).count);

    app.read(Counter, counter).count += 1;
    try std.testing.expectEqual(@as(i32, 2), app.read(Counter, counter).count);

    app.release(counter.id);
    try std.testing.expect(!app.exists(counter.id));
}

test "observe and notify" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const counter = try app.new(Counter, .{});

    var observed_count: u32 = 0;
    _ = try app.observe(counter.id, &observed_count, struct {
        fn onChange(ctx: ?*anyopaque, _: *App, _: EntityId) void {
            const count: *u32 = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    }.onChange);

    app.notify(counter.id);
    app.notify(counter.id); // duplicate within one flush is coalesced
    try std.testing.expectEqual(@as(u32, 0), observed_count);
    try std.testing.expect(app.needs_redraw);

    app.flushEffects();
    try std.testing.expectEqual(@as(u32, 1), observed_count);

    app.notify(counter.id);
    app.flushEffects();
    try std.testing.expectEqual(@as(u32, 2), observed_count);
}

test "typed events" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const Increment = struct { by: i32 };
    const Reset = struct {};

    const counter = try app.new(Counter, .{});

    var received: i32 = 0;
    _ = try app.subscribe(Increment, counter.id, &received, struct {
        fn onEvent(ctx: ?*anyopaque, _: *App, _: EntityId, event: *const Increment) void {
            const total: *i32 = @ptrCast(@alignCast(ctx.?));
            total.* += event.by;
        }
    }.onEvent);

    app.emit(Increment, counter.id, .{ .by = 5 });
    app.emit(Reset, counter.id, .{}); // different event type: not delivered
    app.emit(Increment, counter.id, .{ .by = 2 });

    try std.testing.expectEqual(@as(i32, 7), received);
}

test "unsubscribe stops notifications" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const counter = try app.new(Counter, .{});

    var observed_count: u32 = 0;
    const sub = try app.observe(counter.id, &observed_count, struct {
        fn onChange(ctx: ?*anyopaque, _: *App, _: EntityId) void {
            const count: *u32 = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    }.onChange);

    app.notify(counter.id);
    app.flushEffects();
    try std.testing.expectEqual(@as(u32, 1), observed_count);

    app.unsubscribe(sub);
    app.notify(counter.id);
    app.flushEffects();
    try std.testing.expectEqual(@as(u32, 1), observed_count);
}

test "setClipboardText pushes through bridge" {
    const Fake = struct {
        var last_push: ?[]const u8 = null;

        fn pull(ctx: ?*anyopaque, gpa: std.mem.Allocator) !?[]u8 {
            _ = ctx;
            _ = gpa;
            return null;
        }

        fn push(ctx: ?*anyopaque, text: []const u8) !void {
            _ = ctx;
            last_push = text;
        }
    };

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.clipboard_bridge = .{ .pull = Fake.pull, .push = Fake.push };

    try app.setClipboardText("copied");
    try std.testing.expectEqualStrings("copied", app.clipboard.getText());
    try std.testing.expectEqualStrings("copied", Fake.last_push.?);
}

test "pullClipboardFromOs updates in-memory clipboard" {
    const Fake = struct {
        var pull_text: []const u8 = "os-content";

        fn pull(ctx: ?*anyopaque, gpa: std.mem.Allocator) !?[]u8 {
            _ = ctx;
            return try gpa.dupe(u8, pull_text);
        }

        fn push(ctx: ?*anyopaque, text: []const u8) !void {
            _ = ctx;
            _ = text;
        }
    };

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.clipboard.setText("stale");
    app.clipboard_bridge = .{ .pull = Fake.pull, .push = Fake.push };

    app.pullClipboardFromOs();
    try std.testing.expectEqualStrings("os-content", app.clipboard.getText());
}

test "entity with deinit is destroyed on release" {
    const Resource = struct {
        buffer: []u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.buffer);
        }
    };

    var app = App.init(std.testing.allocator);
    defer app.deinit();

    const buffer = try std.testing.allocator.alloc(u8, 16);
    const resource = try app.new(Resource, .{ .buffer = buffer, .allocator = std.testing.allocator });
    app.release(resource.id);
    // testing allocator verifies no leak on exit
}
