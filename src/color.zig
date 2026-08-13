//! Color types, modeled on gpui's `color.rs`.

const std = @import("std");

/// Linear-ish sRGB color with premultiplication left to the renderer.
pub const Rgba = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn init(r: f32, g: f32, b: f32, a: f32) Rgba {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Parse 0xRRGGBB into an opaque color.
    pub fn fromHex(hex: u24) Rgba {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 16) & 0xff)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255.0,
            .b = @as(f32, @floatFromInt(hex & 0xff)) / 255.0,
            .a = 1,
        };
    }

    pub fn withAlpha(self: Rgba, a: f32) Rgba {
        var c = self;
        c.a = a;
        return c;
    }

    pub const transparent: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const white: Rgba = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const red: Rgba = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const green: Rgba = .{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const blue: Rgba = .{ .r = 0, .g = 0, .b = 1, .a = 1 };
};

/// HSV color space: hue 0..360 degrees, saturation and value 0..1.
pub const Hsv = struct {
    h: f32 = 0,
    s: f32 = 0,
    v: f32 = 0,
};

/// Convert sRGB components (0..1) to HSV.
pub fn rgbToHsv(c: Rgba) Hsv {
    const max = @max(@max(c.r, c.g), c.b);
    const min = @min(@min(c.r, c.g), c.b);
    const delta = max - min;

    var h: f32 = 0;
    const s: f32 = if (max <= 0) 0 else delta / max;
    const v: f32 = max;

    if (delta > 0) {
        if (max == c.r) {
            h = (c.g - c.b) / delta;
            if (c.g < c.b) h += 6;
        } else if (max == c.g) {
            h = 2 + (c.b - c.r) / delta;
        } else {
            h = 4 + (c.r - c.g) / delta;
        }
        h *= 60;
    }

    return .{ .h = h, .s = s, .v = v };
}

/// Convert HSV to opaque sRGB.
pub fn hsvToRgb(hsv: Hsv) Rgba {
    return hsvToRgba(hsv, 1);
}

/// Convert HSV to sRGB, preserving the given alpha.
pub fn hsvToRgba(hsv: Hsv, a: f32) Rgba {
    if (hsv.s <= 0) {
        return .{ .r = hsv.v, .g = hsv.v, .b = hsv.v, .a = a };
    }

    const h = hsv.h / 60;
    const sector = @mod(@as(i32, @intFromFloat(@floor(h))), 6);
    const f = h - @floor(h);
    const p = hsv.v * (1 - hsv.s);
    const q = hsv.v * (1 - hsv.s * f);
    const t = hsv.v * (1 - hsv.s * (1 - f));

    return switch (sector) {
        0 => .{ .r = hsv.v, .g = t, .b = p, .a = a },
        1 => .{ .r = q, .g = hsv.v, .b = p, .a = a },
        2 => .{ .r = p, .g = hsv.v, .b = t, .a = a },
        3 => .{ .r = p, .g = q, .b = hsv.v, .a = a },
        4 => .{ .r = t, .g = p, .b = hsv.v, .a = a },
        else => .{ .r = hsv.v, .g = p, .b = q, .a = a },
    };
}

test "fromHex" {
    const c = Rgba.fromHex(0x336699);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), c.r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), c.g, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), c.b, 0.01);
}

test "hsv roundtrip" {
    const samples = [_]Rgba{
        Rgba.red,
        Rgba.green,
        Rgba.blue,
        Rgba.fromHex(0xff8800),
        Rgba.fromHex(0x336699),
        .{ .r = 0.5, .g = 0.25, .b = 0.75, .a = 1 },
    };
    for (samples) |original| {
        const hsv = rgbToHsv(original);
        const round = hsvToRgba(hsv, original.a);
        try std.testing.expectApproxEqAbs(original.r, round.r, 0.02);
        try std.testing.expectApproxEqAbs(original.g, round.g, 0.02);
        try std.testing.expectApproxEqAbs(original.b, round.b, 0.02);
    }
}
