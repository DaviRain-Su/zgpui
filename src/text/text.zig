//! Text system: FreeType rasterization + HarfBuzz shaping + glyph atlas.
//! On macOS, CoreText can resolve system/UI font paths for FreeType.

const std = @import("std");

const font_mod = @import("font.zig");
const shape_mod = @import("shape.zig");
const atlas_mod = @import("atlas.zig");
const wrap_mod = @import("wrap.zig");

pub const FontId = font_mod.FontId;
pub const FontSystem = font_mod.FontSystem;
pub const LineMetrics = font_mod.LineMetrics;
pub const GlyphBitmap = font_mod.GlyphBitmap;
pub const defaultFontPath = font_mod.defaultFontPath;
pub const rasterizeGlyph = font_mod.rasterizeGlyph;
pub const rasterizeGlyphFont = font_mod.rasterizeGlyphFont;

pub const ShapedGlyph = shape_mod.ShapedGlyph;
pub const ShapedLine = shape_mod.ShapedLine;
pub const shape = shape_mod.shape;

pub const WrappedText = wrap_mod.WrappedText;
pub const shapeWrapped = wrap_mod.shapeWrapped;

pub const GlyphKey = atlas_mod.GlyphKey;
pub const AtlasGlyph = atlas_mod.AtlasGlyph;
pub const GlyphAtlas = atlas_mod.GlyphAtlas;
pub const quantizeSize = atlas_mod.quantizeSize;
pub const default_atlas_size = atlas_mod.default_atlas_size;
pub const test_font_paths = font_mod.test_font_paths;
pub const loadTestFont = font_mod.loadTestFont;
pub const coretext = @import("coretext.zig");

test "loadUiFont shapes on every platform" {
    const allocator = std.testing.allocator;
    var fs = try FontSystem.init(allocator);
    defer fs.deinit();

    const font_id = try fs.loadUiFont();
    var line = try shape(&fs, font_id, 16.0, "UiFont", allocator);
    defer line.deinit(allocator);
    try std.testing.expect(line.glyphs.len > 0);
}

test "loadSystemFont Helvetica on macOS" {
    if (@import("builtin").os.tag != .macos) return;
    const allocator = std.testing.allocator;
    var fs = try FontSystem.init(allocator);
    defer fs.deinit();

    const font_id = try fs.loadSystemFont("Helvetica");
    var line = try shape(&fs, font_id, 14.0, "CT", allocator);
    defer line.deinit(allocator);
    try std.testing.expect(line.glyphs.len > 0);
}

test "shape hello zgpui at 16px" {
    const allocator = std.testing.allocator;

    var fs = try FontSystem.init(allocator);
    defer fs.deinit();

    const font_id = try loadTestFont(&fs);

    var line = try shape(&fs, font_id, 16.0, "Hello zgpui", allocator);
    defer line.deinit(allocator);

    try std.testing.expect(line.glyphs.len > 0);
    try std.testing.expect(line.width > 0);
    try std.testing.expect(line.ascent > 0);
    for (line.glyphs) |glyph| {
        try std.testing.expect(glyph.advance >= 0);
    }
}

test "rasterize glyph A" {
    const allocator = std.testing.allocator;

    var fs = try FontSystem.init(allocator);
    defer fs.deinit();

    const font_id = try loadTestFont(&fs);
    const face = try fs.getFace(font_id);
    try fs.setPixelSize(font_id, 16.0);

    const c = @import("text_c");
    const glyph_id = c.FT_Get_Char_Index(face, 'A');
    try std.testing.expect(glyph_id > 0);

    var bitmap = try rasterizeGlyph(&fs, font_id, 16.0, glyph_id, allocator);
    defer bitmap.deinit(allocator);

    try std.testing.expect(bitmap.width > 0);
    try std.testing.expect(bitmap.height > 0);

    var has_nonzero = false;
    for (bitmap.data) |alpha| {
        if (alpha != 0) {
            has_nonzero = true;
            break;
        }
    }
    try std.testing.expect(has_nonzero);
}

test "glyph atlas packing and cache" {
    const allocator = std.testing.allocator;

    var fs = try FontSystem.init(allocator);
    defer fs.deinit();

    const font_id = try loadTestFont(&fs);
    const face = try fs.getFace(font_id);

    const c = @import("text_c");
    var glyph_atlas = try GlyphAtlas.init(allocator, default_atlas_size);
    defer glyph_atlas.deinit();

    var entries: std.ArrayList(AtlasGlyph) = try .initCapacity(allocator, 32);
    defer entries.deinit(allocator);

    const size_px: f32 = 16.0;
    var letter: u8 = 'A';
    while (letter <= 'Z') : (letter += 1) {
        const glyph_id = c.FT_Get_Char_Index(face, letter);
        try std.testing.expect(glyph_id > 0);

        var bitmap = try rasterizeGlyph(&fs, font_id, size_px, glyph_id, allocator);
        defer bitmap.deinit(allocator);

        const key = GlyphKey.fromSize(font_id, glyph_id, size_px);
        const placed = try glyph_atlas.getOrInsert(key, bitmap);
        try entries.append(allocator, placed);
    }
    try std.testing.expect(entries.items.len >= 20);

    for (entries.items) |entry| {
        try std.testing.expect(entry.bounds.origin.x >= 0);
        try std.testing.expect(entry.bounds.origin.y >= 0);
        try std.testing.expect(entry.bounds.right() <= glyph_atlas.size.width);
        try std.testing.expect(entry.bounds.bottom() <= glyph_atlas.size.height);
    }

    for (entries.items, 0..) |a, i| {
        for (entries.items[i + 1 ..]) |b| {
            try std.testing.expect(!a.bounds.intersects(b.bounds));
        }
    }

    const first_key = GlyphKey.fromSize(font_id, c.FT_Get_Char_Index(face, 'A'), size_px);
    var bitmap_a = try rasterizeGlyph(&fs, font_id, size_px, first_key.glyph_id, allocator);
    defer bitmap_a.deinit(allocator);

    const cached = try glyph_atlas.getOrInsert(first_key, bitmap_a);
    try std.testing.expectEqual(entries.items[0].bounds.origin.x, cached.bounds.origin.x);
    try std.testing.expectEqual(entries.items[0].bounds.origin.y, cached.bounds.origin.y);
    try std.testing.expectEqual(entries.items[0].bounds.size.width, cached.bounds.size.width);
    try std.testing.expectEqual(entries.items[0].bounds.size.height, cached.bounds.size.height);
}
