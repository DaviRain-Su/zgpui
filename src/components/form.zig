//! Lightweight form validation skeleton. Not a full form library — just
//! `Field(T)` wrappers with meta state and comptime-friendly validators.

const std = @import("std");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const App = app_mod.App;

pub const FieldState = struct {
    touched: bool = false,
    dirty: bool = false,
    invalid: bool = false,
    error_message: ?[]const u8 = null,
};

pub fn Validator(comptime T: type) type {
    return *const fn (ctx: ?*anyopaque, value_ptr: *const T) ?[]const u8;
}

/// Wraps `Value(T)` with validation meta (`touched`, `dirty`, `error_message`).
pub fn Field(comptime T: type) type {
    const V = value_mod.Value(T);
    return struct {
        pub const ValueType = V;
        pub const Store = V.Store;

        value: V,
        meta: FieldState = .{},
        validator: ?Validator(T) = null,
        validator_ctx: ?*anyopaque = null,

        const Self = @This();

        pub fn get(self: Self, app: *App) T {
            return self.value.get(app);
        }

        pub fn setValidator(self: *Self, ctx: ?*anyopaque, validator: Validator(T)) void {
            self.validator_ctx = ctx;
            self.validator = validator;
        }

        pub fn markTouched(self: *Self) void {
            self.meta.touched = true;
        }

        pub fn markDirty(self: *Self) void {
            self.meta.dirty = true;
        }

        pub fn clearError(self: *Self) void {
            self.meta.error_message = null;
            self.meta.invalid = false;
        }

        pub fn isValid(self: *const Self) bool {
            return !self.meta.invalid;
        }

        /// Run this field's validator; sets `meta.error_message` and `meta.invalid`. Returns true when valid.
        pub fn validate(self: *Self, app: *App) bool {
            self.meta.error_message = null;
            self.meta.invalid = false;
            if (self.validator) |v| {
                const val = self.value.get(app);
                if (v(self.validator_ctx, &val)) |err| {
                    self.meta.error_message = err;
                    self.meta.invalid = true;
                    return false;
                }
            }
            return true;
        }
    };
}

/// Validate every `Field(T)` on a struct. Pass `&form` so errors are written back.
pub fn validate(app: *App, fields: anytype) bool {
    var all_valid = true;
    inline for (std.meta.fields(@TypeOf(fields.*))) |f| {
        const field_ptr = &@field(fields.*, f.name);
        if (!field_ptr.validate(app)) all_valid = false;
    }
    return all_valid;
}

// ---------------------------------------------------------------------------
// Built-in validators (static error strings — no allocation)
// ---------------------------------------------------------------------------

pub fn requiredString(_: ?*anyopaque, value_ptr: *const []const u8) ?[]const u8 {
    if (value_ptr.*.len == 0) return "Required";
    return null;
}

pub fn minInt(comptime min_val: i64) Validator(i64) {
    return struct {
        fn validate(_: ?*anyopaque, value_ptr: *const i64) ?[]const u8 {
            if (value_ptr.* < min_val) return "Too small";
            return null;
        }
    }.validate;
}

pub fn maxInt(comptime max_val: i64) Validator(i64) {
    return struct {
        fn validate(_: ?*anyopaque, value_ptr: *const i64) ?[]const u8 {
            if (value_ptr.* > max_val) return "Too large";
            return null;
        }
    }.validate;
}

pub fn mustBeTrue(_: ?*anyopaque, value_ptr: *const bool) ?[]const u8 {
    if (!value_ptr.*) return "Must be checked";
    return null;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "Field validate sets and clears errors" {
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    const F = Field(i64);
    const entity = try app.new(F.Store, .{ .value = 3 });
    var field: F = .{ .value = .{ .uncontrolled = entity } };
    field.setValidator(null, minInt(5));

    try std.testing.expect(!field.validate(&app));
    try std.testing.expectEqualStrings("Too small", field.meta.error_message.?);

    field.value.set(&app, 10);
    try std.testing.expect(field.validate(&app));
    try std.testing.expect(field.meta.error_message == null);
}

test "validate runs all fields on a struct" {
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    const F = Field(i64);
    const name_entity = try app.new(value_mod.Value([]const u8).Store, .{ .value = "" });
    const age_entity = try app.new(F.Store, .{ .value = 20 });

    var form = struct {
        name: Field([]const u8),
        age: F,
    }{
        .name = .{ .value = .{ .uncontrolled = name_entity } },
        .age = .{ .value = .{ .uncontrolled = age_entity } },
    };
    form.name.setValidator(null, requiredString);
    form.age.setValidator(null, maxInt(18));

    try std.testing.expect(!validate(&app, &form));
    try std.testing.expectEqualStrings("Required", form.name.meta.error_message.?);
    try std.testing.expectEqualStrings("Too large", form.age.meta.error_message.?);

    form.name.value.set(&app, "Ada");
    form.age.value.set(&app, 16);
    try std.testing.expect(validate(&app, &form));
}

test "mustBeTrue validator" {
    var app = app_mod.App.init(std.testing.allocator);
    defer app.deinit();

    const F = Field(bool);
    const entity = try app.new(F.Store, .{ .value = false });
    var field: F = .{ .value = .{ .uncontrolled = entity } };
    field.setValidator(null, mustBeTrue);

    try std.testing.expect(!field.validate(&app));
    field.value.set(&app, true);
    try std.testing.expect(field.validate(&app));
}
