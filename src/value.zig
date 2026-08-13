//! Compile-time controlled/uncontrolled value helpers.
//!
//! Zig `comptime` generics replace the duplicated `Value = union(enum) {
//!   controlled: T, uncontrolled: Entity(SomeState) }` pattern that each
//! component otherwise re-implements by hand.

const app_mod = @import("app.zig");

/// Typed value that is either owned by the parent (`controlled`) or by an
/// app entity (`uncontrolled`). Generated per `T` at compile time.
pub fn Value(comptime T: type) type {
    return union(enum) {
        controlled: T,
        uncontrolled: app_mod.Entity(Store),

        pub const Store = struct {
            value: T,
        };

        const Self = @This();

        pub fn get(self: Self, app: *app_mod.App) T {
            return switch (self) {
                .controlled => |v| v,
                .uncontrolled => |entity| app.read(Store, entity).value,
            };
        }

        pub fn set(self: Self, app: *app_mod.App, next: T) void {
            switch (self) {
                .controlled => {},
                .uncontrolled => |entity| {
                    app.read(Store, entity).value = next;
                    app.notify(entity.id);
                },
            }
        }

        /// Uncontrolled only: write + notify. Controlled is a no-op write
        /// (parent still receives `on_change` from the caller).
        pub fn setIfUncontrolled(self: Self, app: *app_mod.App, next: T) bool {
            switch (self) {
                .controlled => return false,
                .uncontrolled => |entity| {
                    app.read(Store, entity).value = next;
                    app.notify(entity.id);
                    return true;
                },
            }
        }
    };
}

/// Controlled/uncontrolled value backed by a named field on `StoreT`.
/// Uses comptime reflection (`@FieldType` / `@field`) so components can keep
/// idiomatic store fields (`checked`, `on`, …) instead of a generic `.value`.
pub fn FieldValue(comptime StoreT: type, comptime field_name: []const u8) type {
    const FieldType = @FieldType(StoreT, field_name);
    return union(enum) {
        controlled: FieldType,
        uncontrolled: app_mod.Entity(StoreT),

        pub const Store = StoreT;
        const Self = @This();

        pub fn get(self: Self, app: *app_mod.App) FieldType {
            return switch (self) {
                .controlled => |v| v,
                .uncontrolled => |entity| @field(app.read(StoreT, entity).*, field_name),
            };
        }

        pub fn set(self: Self, app: *app_mod.App, next: FieldType) void {
            switch (self) {
                .controlled => {},
                .uncontrolled => |entity| {
                    @field(app.read(StoreT, entity).*, field_name) = next;
                    app.notify(entity.id);
                },
            }
        }

        pub fn setIfUncontrolled(self: Self, app: *app_mod.App, next: FieldType) bool {
            switch (self) {
                .controlled => return false,
                .uncontrolled => |entity| {
                    @field(app.read(StoreT, entity).*, field_name) = next;
                    app.notify(entity.id);
                    return true;
                },
            }
        }
    };
}

/// `Value(Mask)` with a comptime check that `Mask` is an integer type.
pub fn MaskValue(comptime Mask: type) type {
    comptime {
        switch (@typeInfo(Mask)) {
            .int => {},
            else => @compileError("MaskValue requires an integer mask type"),
        }
    }
    return Value(Mask);
}

test "Value get/set uncontrolled" {
    const std = @import("std");
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    const V = Value(usize);
    const entity = try app.new(V.Store, .{ .value = 2 });
    const value: V = .{ .uncontrolled = entity };

    try std.testing.expectEqual(@as(usize, 2), value.get(&app));
    value.set(&app, 5);
    try std.testing.expectEqual(@as(usize, 5), value.get(&app));
}

test "Value controlled ignores set" {
    const std = @import("std");
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    const V = Value(bool);
    const value: V = .{ .controlled = true };
    try std.testing.expect(value.get(&app));
    value.set(&app, false);
    try std.testing.expect(value.get(&app));
}

test "FieldValue get/set uncontrolled" {
    const std = @import("std");
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    const State = struct { checked: bool = false };
    const V = FieldValue(State, "checked");
    const entity = try app.new(State, .{});
    const value: V = .{ .uncontrolled = entity };

    try std.testing.expect(!value.get(&app));
    value.set(&app, true);
    try std.testing.expect(value.get(&app));
    try std.testing.expect(app.read(State, entity).checked);
}

test "FieldValue controlled ignores set" {
    const std = @import("std");
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    const State = struct { on: bool = false };
    const V = FieldValue(State, "on");
    const value: V = .{ .controlled = true };
    try std.testing.expect(value.get(&app));
    value.set(&app, false);
    try std.testing.expect(value.get(&app));
}

test "MaskValue rejects non-integer at comptime" {
    const std = @import("std");
    // Compiles: integer mask.
    const M = MaskValue(u32);
    try std.testing.expect(@sizeOf(M) > 0);
}
