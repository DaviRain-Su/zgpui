//! Optional design tokens aligned with ProofShip `comet-kit`.
//!
//! zgpui components stay **headless** — they do not read this module. Apps that
//! want the comet / ProofShip look can hold a [`Theme`] and paint via `Style` /
//! `StyleFn`.
//!
//! Palette design notes mirror proofship `crates/kit/src/theme.rs`: light is
//! designed (role remapping + accent scale shift), not a lightness invert.

const std = @import("std");
const builtin = @import("builtin");
const color = @import("color.zig");
const style = @import("style.zig");

const Rgba = color.Rgba;

pub const Appearance = enum {
    dark,
    light,

    pub fn isDark(self: Appearance) bool {
        return self == .dark;
    }

    pub fn isLight(self: Appearance) bool {
        return self == .light;
    }
};

/// Paint + layout tokens. Colors are [`Rgba`] (sRGB); layout numbers are px.
pub const Theme = struct {
    appearance: Appearance,

    bg: Rgba,
    surface: Rgba,
    surface_raised: Rgba,
    surface_card: Rgba,
    surface_dialog: Rgba,
    surface_overlay: Rgba,
    element_hover: Rgba,
    element_active: Rgba,
    border: Rgba,
    border_strong: Rgba,

    text: Rgba,
    text_muted: Rgba,
    text_faint: Rgba,
    text_dim: Rgba,

    solid: Rgba,
    on_solid: Rgba,
    accent: Rgba,
    accent_strong: Rgba,
    on_accent: Rgba,
    danger: Rgba,
    danger_muted: Rgba,
    warning: Rgba,
    warning_muted: Rgba,
    success: Rgba,
    busy: Rgba,
    success_muted: Rgba,

    surface_raised_hover: Rgba,
    band: Rgba,
    input_bg: Rgba,
    selection: Rgba,
    cursor: Rgba,
    caret: Rgba,
    danger_strong: Rgba,

    code_text: Rgba,
    code_wash: Rgba,
    syntax_keyword: Rgba,
    syntax_string: Rgba,
    syntax_number: Rgba,
    diff_add: Rgba,
    diff_del: Rgba,
    diff_hunk_bg: Rgba,

    font_sans: []const u8,
    font_mono: []const u8,

    // ---- numbers drive layout (px) ----
    pub const header_height: f32 = 44;
    pub const titlebar_height: f32 = 38;
    pub const titlebar_top_pad: f32 = 2;
    pub const status_strip_height: f32 = 24;
    pub const transcript_fade_band: f32 = 24;
    pub const bubble_radius: f32 = 16;
    pub const panel_radius: f32 = 10;
    pub const control_radius: f32 = 6;
    pub const space_xs: f32 = 4;
    pub const space_sm: f32 = 8;
    pub const space_md: f32 = 12;
    pub const space_lg: f32 = 16;

    pub fn dark() Theme {
        return .{
            .appearance = .dark,
            .bg = grey(6),
            .surface = grey(13),
            .surface_raised = neutral(0.235),
            .surface_card = grey(0x0e),
            .surface_dialog = grey(0x10),
            .surface_overlay = grey(0x16),
            .element_hover = color.hsla(0, 0, 0.92, 0.11),
            .element_active = color.hsla(0, 0, 0.92, 0.16),
            .border = color.hsla(0, 0, 1, 0.08),
            .border_strong = color.hsla(0, 0, 1, 0.14),
            .text = neutral(0.922),
            .text_muted = neutral(0.708),
            .text_faint = neutral(0.556),
            .text_dim = grey(0x98),
            .solid = neutral(0.922),
            .on_solid = grey(0x0e),
            .accent = color.oklch(0.673, 0.182, 276.935),
            .accent_strong = color.oklch(0.585, 0.233, 277.117),
            .on_accent = neutral(0.985),
            .danger = color.oklch(0.704, 0.191, 22.216),
            .danger_muted = color.oklch(0.808, 0.114, 19.571),
            .warning = color.oklch(0.828, 0.189, 84.429),
            .warning_muted = color.oklch(0.924, 0.12, 95.746),
            .success = color.oklch(0.765, 0.177, 163.223),
            .busy = color.oklch(0.718, 0.202, 349.761),
            .success_muted = color.oklch(0.845, 0.143, 164.978),
            .surface_raised_hover = neutral(0.29),
            .band = color.hsla(0, 0, 0, 0.16),
            .input_bg = color.hsla(0, 0, 1, 0.03),
            .selection = color.hsla(0.66, 0.6, 0.55, 0.35),
            .cursor = color.hsla(0, 0, 1, 0.35),
            .caret = color.hsla(0.66, 0.7, 0.7, 1),
            .danger_strong = color.oklch(0.58, 0.16, 25),
            .code_text = color.oklch(0.811, 0.111, 293.571),
            .code_wash = color.oklch(0.702, 0.183, 293.541).withAlpha(0.12),
            .syntax_keyword = color.oklch(0.709, 0.129, 20),
            .syntax_string = color.oklch(0.77, 0.11, 168),
            .syntax_number = color.oklch(0.78, 0.12, 80),
            .diff_add = color.oklch(0.765, 0.177, 163.223),
            .diff_del = color.oklch(0.704, 0.191, 22.216),
            .diff_hunk_bg = color.hsla(0.6, 0.35, 0.6, 0.05),
            .font_sans = "Geist",
            .font_mono = "Geist Mono",
        };
    }

    pub fn light() Theme {
        return .{
            .appearance = .light,
            .bg = grey(0xff),
            .surface = neutral(0.968),
            .surface_raised = neutral(0.940),
            .surface_card = grey(0xff),
            .surface_dialog = grey(0xff),
            .surface_overlay = grey(0xff),
            .element_hover = color.hsla(0, 0, 0.10, 0.06),
            .element_active = color.hsla(0, 0, 0.10, 0.10),
            .border = color.hsla(0, 0, 0, 0.10),
            .border_strong = color.hsla(0, 0, 0, 0.17),
            .text = neutral(0.25),
            .text_muted = neutral(0.439),
            .text_faint = neutral(0.535),
            .text_dim = neutral(0.50),
            .solid = neutral(0.205),
            .on_solid = neutral(0.985),
            .accent = color.oklch(0.511, 0.262, 276.966),
            .accent_strong = color.oklch(0.511, 0.262, 276.966),
            .on_accent = neutral(0.985),
            .danger = color.oklch(0.577, 0.245, 27.325),
            .danger_muted = color.oklch(0.505, 0.213, 27.518),
            .warning = color.oklch(0.555, 0.163, 48.998),
            .warning_muted = color.oklch(0.473, 0.137, 46.201),
            .success = color.oklch(0.596, 0.145, 163.225),
            .busy = color.oklch(0.592, 0.249, 0.584),
            .success_muted = color.oklch(0.508, 0.118, 165.612),
            .surface_raised_hover = neutral(0.900),
            .band = color.hsla(0, 0, 0, 0.045),
            .input_bg = grey(0xff),
            .selection = color.hsla(0.66, 0.75, 0.62, 0.28),
            .cursor = color.hsla(0, 0, 0, 0.55),
            .caret = color.hsla(0.66, 0.78, 0.42, 1),
            .danger_strong = color.oklch(0.51, 0.20, 25),
            .code_text = color.oklch(0.491, 0.27, 292.581),
            .code_wash = color.oklch(0.541, 0.281, 293.009).withAlpha(0.10),
            .syntax_keyword = color.oklch(0.52, 0.19, 20),
            .syntax_string = color.oklch(0.46, 0.11, 168),
            .syntax_number = color.oklch(0.52, 0.13, 70),
            .diff_add = color.oklch(0.596, 0.145, 163.225),
            .diff_del = color.oklch(0.577, 0.245, 27.325),
            .diff_hunk_bg = color.hsla(0.6, 0.35, 0.35, 0.07),
            .font_sans = "Geist",
            .font_mono = "Geist Mono",
        };
    }

    pub fn forAppearance(appearance: Appearance) Theme {
        return switch (appearance) {
            .dark => dark(),
            .light => light(),
        };
    }

    /// Frost alpha over blurred desktop (macOS vibrancy). Opaque elsewhere.
    pub const glass_alpha: f32 = if (builtin.os.tag == .macos) 0.80 else 1.0;
    pub const glass_alpha_light: f32 = if (builtin.os.tag == .macos) 0.80 else 1.0;

    /// Frost tint over blurred window background (or opaque `surface` when glass is off).
    pub fn glass(self: Theme) Rgba {
        return switch (self.appearance) {
            .dark => if (glass_alpha < 1.0) grey(8).withAlpha(glass_alpha) else self.surface,
            .light => if (glass_alpha_light < 1.0) grey(0xfa).withAlpha(glass_alpha_light) else self.surface,
        };
    }

    pub fn isGlass(self: Theme) bool {
        return self.glass().a < 1.0;
    }

    /// Hover wash for chrome sitting on glass (sidebar rows, tabs).
    pub fn glassHover(self: Theme) Rgba {
        return switch (self.appearance) {
            .dark => wash(self.appearance, 0.11),
            .light => wash(self.appearance, 0.06),
        };
    }

    /// Translucent tint for floating cards over backdrop blur.
    pub fn glassOverlay(self: Theme) Rgba {
        return switch (self.appearance) {
            .dark => self.surface_overlay.withAlpha(0.65),
            .light => self.surface_overlay.withAlpha(0.85),
        };
    }

    /// Composer / input fill when painted over glass.
    pub fn inputGlassBg(self: Theme) Rgba {
        if (self.isGlass() and self.appearance == .light) {
            return self.input_bg.withAlpha(0.30);
        }
        return self.input_bg;
    }

    /// Section-card fill thinned over glass.
    pub fn cardGlassBg(self: Theme) Rgba {
        if (self.isGlass()) return self.surface.withAlpha(0.40);
        return self.surface;
    }

    /// Modal backdrop (always black; light mode uses a lighter alpha).
    pub fn scrim(self: Theme) Rgba {
        return scrimFor(self.appearance, scrim_alpha_dark);
    }
};

/// Dark-mode fill alpha scale when deriving light fills (kept at 1.0 in kit).
pub const ink_fill_scale: f32 = 1.0;
/// Light-mode hairline ink is stronger than the dark quote so 1px edges survive white.
pub const ink_hairline_scale: f32 = 1.35;
/// Standard modal scrim alpha in dark mode.
pub const scrim_alpha_dark: f32 = 0.60;

/// Soft-white (dark) / soft-black (light) fill ink. `alpha` is quoted in dark-mode terms.
pub fn ink(appearance: Appearance, alpha: f32) Rgba {
    return switch (appearance) {
        .dark => color.hsla(0, 0, 1, alpha),
        .light => color.hsla(0, 0, 0, alpha * ink_fill_scale),
    };
}

/// Border / divider / ring ink. Light scales alpha up (capped) so edges stay visible.
pub fn hairline(appearance: Appearance, alpha: f32) Rgba {
    return switch (appearance) {
        .dark => color.hsla(0, 0, 1, alpha),
        .light => color.hsla(0, 0, 0, @min(alpha * ink_hairline_scale, 0.5)),
    };
}

/// Interactive wash — softened ink so hover reads as tinted glass.
pub fn wash(appearance: Appearance, alpha: f32) Rgba {
    return switch (appearance) {
        .dark => color.hsla(0, 0, 0.92, alpha),
        .light => color.hsla(0, 0, 0.10, alpha * ink_fill_scale),
    };
}

/// Modal scrim. Always black; light mode scales strength from the dark quote.
pub fn scrimFor(appearance: Appearance, alpha_dark: f32) Rgba {
    return switch (appearance) {
        .dark => color.hsla(0, 0, 0, alpha_dark),
        .light => color.hsla(0, 0, 0, 0.32 * (alpha_dark / scrim_alpha_dark)),
    };
}

/// Recessed band behind picker header/footer strips.
pub fn band(appearance: Appearance) Rgba {
    return switch (appearance) {
        .dark => color.hsla(0, 0, 0, 0.16),
        .light => color.hsla(0, 0, 0, 0.045),
    };
}

/// Selected fill on glass chrome (tabs / session rows) — same wash as `Theme.glassHover`.
pub fn glassSelectedBg(appearance: Appearance) Rgba {
    return switch (appearance) {
        .dark => wash(appearance, 0.11),
        .light => wash(appearance, 0.06),
    };
}

/// Softer wash for user message bubbles over glass.
pub fn userBubbleBg(appearance: Appearance) Rgba {
    return switch (appearance) {
        .dark => wash(appearance, 0.08),
        .light => wash(appearance, 0.04),
    };
}

/// Selected fill for rows/chips inside a floating card.
pub fn cardSelectedBg(appearance: Appearance) Rgba {
    return glassSelectedBg(appearance);
}

/// Inset 1px selection ring (glass + in-card). Maps to `style.BoxShadow` with `inset`.
pub fn cardSelectedShadows(appearance: Appearance) [1]style.BoxShadow {
    const ring = switch (appearance) {
        .dark => hairline(appearance, 0.09),
        .light => color.hsla(0, 0, 0, 0.07),
    };
    return .{.{
        .color = ring,
        .offset = .{},
        .blur_radius = 0,
        .spread_radius = 1,
        .inset = true,
    }};
}

/// Alias — glass selection uses the same inset ring as in-card selection.
pub fn glassSelectedShadows(appearance: Appearance) [1]style.BoxShadow {
    return cardSelectedShadows(appearance);
}

/// Achromatic tone from an 8-bit channel (`grey(13)` ≡ `#0d0d0d`).
pub fn grey(value: u8) Rgba {
    const v: f32 = @as(f32, @floatFromInt(value)) / 255.0;
    return .{ .r = v, .g = v, .b = v, .a = 1 };
}

/// Neutral OKLCH (chroma 0) as opaque sRGB grey.
pub fn neutral(lightness: f32) Rgba {
    return color.oklch(lightness, 0, 0);
}

test "layout numbers match comet-kit" {
    try std.testing.expectEqual(@as(f32, 44), Theme.header_height);
    try std.testing.expectEqual(@as(f32, 24), Theme.status_strip_height);
    try std.testing.expectEqual(@as(f32, 16), Theme.bubble_radius);
}

test "dark surfaces are ordered" {
    const t = Theme.dark();
    try std.testing.expect(t.bg.r < t.surface.r);
    try std.testing.expect(t.surface.r < t.surface_raised.r);
}

test "text contrast paired across appearances" {
    const d = Theme.dark();
    const l = Theme.light();
    const pairs = [_]struct { []const u8, Rgba, Rgba }{
        .{ "text", d.text, l.text },
        .{ "text_muted", d.text_muted, l.text_muted },
        .{ "text_faint", d.text_faint, l.text_faint },
    };
    for (pairs) |p| {
        const dr = color.contrastRatio(p[1], d.bg);
        const lr = color.contrastRatio(p[2], l.bg);
        try std.testing.expect(@abs(dr - lr) < 1.0);
    }
}

test "text tones clear WCAG AA floors" {
    for ([_]Theme{ Theme.dark(), Theme.light() }) |t| {
        const checks = [_]struct { Rgba, f32 }{
            .{ t.text, 4.5 },
            .{ t.text_muted, 4.5 },
            .{ t.text_dim, 4.5 },
            .{ t.text_faint, 4.1 },
        };
        for (checks) |c| {
            try std.testing.expect(color.contrastRatio(c[0], t.bg) >= c[1]);
            try std.testing.expect(color.contrastRatio(c[0], t.surface) >= c[1]);
        }
    }
}

test "ink and hairline flip tone with appearance" {
    const di = ink(.dark, 0.2);
    const li = ink(.light, 0.2);
    try std.testing.expect(di.r > 0.9);
    try std.testing.expect(li.r < 0.1);
    const dh = hairline(.dark, 0.1);
    const lh = hairline(.light, 0.1);
    try std.testing.expect(dh.a == 0.1);
    try std.testing.expect(lh.a > dh.a);
}

test "scrim stays black and lightens in light mode" {
    const d = scrimFor(.dark, scrim_alpha_dark);
    const l = scrimFor(.light, scrim_alpha_dark);
    try std.testing.expect(d.r == 0 and d.g == 0 and d.b == 0);
    try std.testing.expect(l.r == 0 and l.g == 0 and l.b == 0);
    try std.testing.expect(l.a < d.a);
}

test "flatten and mix endpoints" {
    const fg = Rgba.white.withAlpha(0.5);
    const flat = fg.flattenOver(Rgba.black);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), flat.r, 1e-5);
    try std.testing.expectEqual(@as(f32, 1), flat.a);
    const mid = Rgba.black.mix(Rgba.white, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.r, 1e-5);
    const end = Rgba.black.mix(Rgba.white, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 1), end.r, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), end.a, 1e-5);
}

test "selection ring is inset hairline" {
    const shadows = glassSelectedShadows(.dark);
    try std.testing.expect(shadows[0].inset);
    try std.testing.expectEqual(@as(f32, 1), shadows[0].spread_radius);
    try std.testing.expect(shadows[0].color.a > 0);
}
