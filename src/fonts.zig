//! Embedded Geist / Geist Mono faces (ProofShip comet-kit).
//!
//! Optional for apps that want comet typography; the framework itself keeps
//! using system / test fonts. Attribution: [`src/assets/ATTRIBUTION.md`](assets/ATTRIBUTION.md).

const std = @import("std");
const font_mod = @import("text/font.zig");

pub const FontSystem = font_mod.FontSystem;
pub const FontId = font_mod.FontId;

pub const geist = @embedFile("assets/fonts/Geist.ttf");
pub const geist_mono = @embedFile("assets/fonts/GeistMono.ttf");
pub const geist_medium = @embedFile("assets/fonts/Geist-Medium.ttf");
pub const geist_semibold = @embedFile("assets/fonts/Geist-SemiBold.ttf");
pub const geist_bold = @embedFile("assets/fonts/Geist-Bold.ttf");

/// Font ids after [`register`].
pub const Registered = struct {
    sans: FontId,
    mono: FontId,
    medium: FontId,
    semibold: FontId,
    bold: FontId,
};

/// Load all embedded Geist faces into `fs` via FreeType memory faces.
pub fn register(fs: *FontSystem) !Registered {
    return .{
        .sans = try fs.loadFontFromMemory(geist, 0),
        .mono = try fs.loadFontFromMemory(geist_mono, 0),
        .medium = try fs.loadFontFromMemory(geist_medium, 0),
        .semibold = try fs.loadFontFromMemory(geist_semibold, 0),
        .bold = try fs.loadFontFromMemory(geist_bold, 0),
    };
}

test "register geist from embedded bytes" {
    var fs = try FontSystem.init(std.testing.allocator);
    defer fs.deinit();
    const ids = try register(&fs);
    try fs.setPixelSize(ids.sans, 16);
    const metrics = try fs.lineMetrics(ids.sans, 16);
    try std.testing.expect(metrics.ascent > 0);
    const gid = try fs.glyphIndex(ids.sans, 'A');
    try std.testing.expect(!fs.isMissingGlyph(gid));
}
