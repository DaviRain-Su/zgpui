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

/// OKLCH (CSS: L 0..1, C, H degrees) → gamma-encoded sRGB 0..1.
/// Matrices match CSS Color 4 / Björn Ottosson OKLab (same as comet-kit).
pub fn oklchToSrgb(l: f32, c: f32, h_deg: f32) [3]f32 {
    const h = std.math.degreesToRadians(h_deg);
    const a = c * @cos(h);
    const b = c * @sin(h);

    const l_ = l + 0.39633778 * a + 0.21580376 * b;
    const m_ = l - 0.105561346 * a - 0.06385417 * b;
    const s_ = l - 0.08948418 * a - 1.2914855 * b;
    const l3 = l_ * l_ * l_;
    const m3 = m_ * m_ * m_;
    const s3 = s_ * s_ * s_;

    const r = 4.0767417 * l3 - 3.3077116 * m3 + 0.23096993 * s3;
    const g = -1.268438 * l3 + 2.6097574 * m3 - 0.3413194 * s3;
    const bl = -0.0041960863 * l3 - 0.7034186 * m3 + 1.7076147 * s3;

    return .{ gammaEncode(r), gammaEncode(g), gammaEncode(bl) };
}

pub fn oklch(l: f32, c: f32, h_deg: f32) Rgba {
    const rgb = oklchToSrgb(l, c, h_deg);
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 1 };
}

/// HSL with h/s/l in 0..1 (gpui Hsla convention) → sRGB 0..1.
pub fn hslToRgb(h: f32, s: f32, l: f32) [3]f32 {
    if (s <= 1e-6) return .{ l, l, l };
    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;
    const hue = struct {
        fn eval(t_in: f32, p_: f32, q_: f32) f32 {
            var t = t_in - @floor(t_in);
            if (t < 0) t += 1;
            if (t < 1.0 / 6.0) return p_ + (q_ - p_) * 6 * t;
            if (t < 0.5) return q_;
            if (t < 2.0 / 3.0) return p_ + (q_ - p_) * (2.0 / 3.0 - t) * 6;
            return p_;
        }
    }.eval;
    return .{ hue(h + 1.0 / 3.0, p, q), hue(h, p, q), hue(h - 1.0 / 3.0, p, q) };
}

pub fn hsla(h: f32, s: f32, l: f32, a: f32) Rgba {
    const rgb = hslToRgb(h, s, l);
    return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = a };
}

fn gammaEncode(x: f32) f32 {
    const c = std.math.clamp(x, 0, 1);
    if (c <= 0.0031308) return 12.92 * c;
    return 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

fn linearizeChannel(c: f32) f32 {
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

/// WCAG 2.1 relative luminance (treats alpha as opaque paint).
pub fn relativeLuminance(c: Rgba) f32 {
    return 0.2126 * linearizeChannel(c.r) + 0.7152 * linearizeChannel(c.g) + 0.0722 * linearizeChannel(c.b);
}

/// WCAG 2.1 contrast ratio (1.0 … 21.0).
pub fn contrastRatio(a: Rgba, b: Rgba) f32 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const lighter = @max(la, lb);
    const darker = @min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
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

fn srgbU8(c: [3]f32) [3]u8 {
    return .{
        @intFromFloat(@round(c[0] * 255)),
        @intFromFloat(@round(c[1] * 255)),
        @intFromFloat(@round(c[2] * 255)),
    };
}

test "oklch neutral-950 is #0a0a0a" {
    const rgb = srgbU8(oklchToSrgb(0.145, 0, 0));
    try std.testing.expectEqual(@as(u8, 10), rgb[0]);
    try std.testing.expectEqual(@as(u8, 10), rgb[1]);
    try std.testing.expectEqual(@as(u8, 10), rgb[2]);
}

test "oklch accents match comet-kit references" {
    const indigo = srgbU8(oklchToSrgb(0.673, 0.182, 276.935));
    try std.testing.expectEqual(@as(u8, 124), indigo[0]);
    try std.testing.expectEqual(@as(u8, 134), indigo[1]);
    try std.testing.expectEqual(@as(u8, 255), indigo[2]);

    const red400 = srgbU8(oklchToSrgb(0.704, 0.191, 22.216));
    try std.testing.expectEqual(@as(u8, 255), red400[0]);
    try std.testing.expectEqual(@as(u8, 100), red400[1]);
    try std.testing.expectEqual(@as(u8, 103), red400[2]);

    const amber = srgbU8(oklchToSrgb(0.828, 0.189, 84.429));
    try std.testing.expectEqual(@as(u8, 255), amber[0]);
    try std.testing.expectEqual(@as(u8, 185), amber[1]);
    try std.testing.expectEqual(@as(u8, 0), amber[2]);
}

test "contrast ratio anchors" {
    try std.testing.expectApproxEqAbs(@as(f32, 21), contrastRatio(Rgba.white, Rgba.black), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1), contrastRatio(Rgba.white, Rgba.white), 0.01);
}
