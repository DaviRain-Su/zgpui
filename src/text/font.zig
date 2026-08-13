//! FreeType font loading and glyph rasterization.

const std = @import("std");
const c = @import("text_c");
const geometry = @import("../geometry.zig");

pub const Pixels = geometry.Pixels;
pub const FontId = u32;

pub const LineMetrics = struct {
    ascent: Pixels,
    descent: Pixels,
};

pub const FontSystem = struct {
    allocator: std.mem.Allocator,
    library: c.FT_Library,
    faces: std.ArrayList(c.FT_Face),
    fallbacks: std.ArrayList(FontId),

    pub fn init(allocator: std.mem.Allocator) !FontSystem {
        var library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = c.FT_Done_FreeType(library);
        return .{
            .allocator = allocator,
            .library = library,
            .faces = try std.ArrayList(c.FT_Face).initCapacity(allocator, 4),
            .fallbacks = .empty,
        };
    }

    pub fn deinit(self: *FontSystem) void {
        for (self.faces.items) |face| {
            _ = c.FT_Done_Face(face);
        }
        self.faces.deinit(self.allocator);
        self.fallbacks.deinit(self.allocator);
        _ = c.FT_Done_FreeType(self.library);
    }

    /// Appends a font to the end of the fallback chain tried after the primary font.
    pub fn addFallback(self: *FontSystem, font: FontId) !void {
        try self.fallbacks.append(self.allocator, font);
    }

    /// Replaces the fallback chain with `fonts` (in try order).
    pub fn setFallbacks(self: *FontSystem, fonts: []const FontId) !void {
        self.fallbacks.clearRetainingCapacity();
        try self.fallbacks.appendSlice(self.allocator, fonts);
    }

    pub fn clearFallbacks(self: *FontSystem) void {
        self.fallbacks.clearRetainingCapacity();
    }

    /// Loads a font face from `path` (NUL-terminated). `face_index` selects a face inside
    /// collections such as `.ttc` files.
    pub fn loadFont(self: *FontSystem, path: [:0]const u8, face_index: i32) !FontId {
        var face: c.FT_Face = null;
        if (c.FT_New_Face(self.library, path.ptr, face_index, &face) != 0) {
            return error.FontLoadFailed;
        }
        try self.faces.append(self.allocator, face);
        return @intCast(self.faces.items.len - 1);
    }

    /// Sets the active pixel size for subsequent rasterization/shaping on this face.
    /// `size_px` is rounded to the nearest integer pixel height.
    pub fn setPixelSize(self: *FontSystem, font: FontId, size_px: f32) !void {
        const face = try self.getFace(font);
        const px = @as(c.FT_UInt, @intFromFloat(@round(size_px)));
        if (c.FT_Set_Pixel_Sizes(face, px, px) != 0) return error.InvalidPixelSize;
    }

    pub fn getFace(self: *FontSystem, font: FontId) !c.FT_Face {
        if (font >= self.faces.items.len) return error.InvalidFontId;
        return self.faces.items[font];
    }

    pub fn lineMetrics(self: *FontSystem, font: FontId, size_px: f32) !LineMetrics {
        const face = try self.getFace(font);
        try self.setPixelSize(font, size_px);
        const size = face.*.size orelse return error.InvalidFontId;
        const metrics = size.*.metrics;
        return .{
            .ascent = @as(Pixels, @floatFromInt(metrics.ascender)) / 64.0,
            .descent = @as(Pixels, @floatFromInt(-metrics.descender)) / 64.0,
        };
    }

    /// Returns the FreeType glyph index for `codepoint` in `font`, or 0 if missing.
    pub fn glyphIndex(self: *FontSystem, font: FontId, codepoint: u32) !u32 {
        const face = try self.getFace(font);
        return c.FT_Get_Char_Index(face, codepoint);
    }

    /// Returns true when `glyph_id` is the font's `.notdef` glyph (0).
    pub fn isMissingGlyph(_: *FontSystem, glyph_id: u32) bool {
        return glyph_id == 0;
    }

    /// Picks the first font in `primary` + fallbacks that defines `codepoint`.
    pub fn resolveGlyph(
        self: *FontSystem,
        primary: FontId,
        codepoint: u32,
    ) !struct { font: FontId, glyph_id: u32 } {
        const primary_id = try self.glyphIndex(primary, codepoint);
        if (!self.isMissingGlyph(primary_id)) {
            return .{ .font = primary, .glyph_id = primary_id };
        }
        for (self.fallbacks.items) |fallback| {
            const gid = try self.glyphIndex(fallback, codepoint);
            if (!self.isMissingGlyph(gid)) {
                return .{ .font = fallback, .glyph_id = gid };
            }
        }
        return .{ .font = primary, .glyph_id = primary_id };
    }
};

/// Cross-platform font paths for unit tests (first existing file wins).
pub const test_font_paths = [_][:0]const u8{
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Monaco.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "C:\\Windows\\Fonts\\arial.ttf",
};

/// Load the first available font from `test_font_paths`, or `error.SkipZigTest`.
pub fn loadTestFont(fs: *FontSystem) !FontId {
    for (test_font_paths) |path| {
        if (fs.loadFont(path, 0)) |id| return id else |_| {}
    }
    return error.SkipZigTest;
}

pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    data: []u8,

    pub fn deinit(self: *GlyphBitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Rasterizes a glyph to an 8-bit alpha bitmap (tightly packed rows).
/// When `glyph_id` is missing in `font`, fallbacks registered on `font_system` are tried.
pub fn rasterizeGlyph(
    font_system: *FontSystem,
    font: FontId,
    size_px: f32,
    glyph_id: u32,
    allocator: std.mem.Allocator,
) !GlyphBitmap {
    return rasterizeGlyphFont(font_system, font, size_px, glyph_id, allocator);
}

pub fn rasterizeGlyphFont(
    font_system: *FontSystem,
    font: FontId,
    size_px: f32,
    glyph_id: u32,
    allocator: std.mem.Allocator,
) !GlyphBitmap {
    const face = try font_system.getFace(font);
    try font_system.setPixelSize(font, size_px);

    if (c.FT_Load_Glyph(face, @intCast(glyph_id), c.FT_LOAD_RENDER) != 0) {
        return error.GlyphLoadFailed;
    }

    const slot = face.*.glyph orelse return error.GlyphLoadFailed;
    const src_bitmap = slot.*.bitmap;

    const width: u32 = @intCast(src_bitmap.width);
    const height: u32 = @intCast(src_bitmap.rows);
    if (width == 0 or height == 0) {
        return .{
            .width = width,
            .height = height,
            .bearing_x = slot.*.bitmap_left,
            .bearing_y = slot.*.bitmap_top,
            .data = try allocator.alloc(u8, 0),
        };
    }

    const src = src_bitmap.buffer orelse return error.GlyphLoadFailed;
    const pitch: isize = @intCast(src_bitmap.pitch);
    const data = try allocator.alloc(u8, @as(usize, width) * height);
    errdefer allocator.free(data);

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const src_row = if (pitch >= 0)
            src + @as(usize, @intCast(row)) * @as(usize, @intCast(pitch))
        else
            src + @as(usize, @intCast(height - 1 - row)) * @as(usize, @intCast(-pitch));
        @memcpy(data[@as(usize, row) * width ..][0..width], src_row[0..width]);
    }

    return .{
        .width = width,
        .height = height,
        .bearing_x = slot.*.bitmap_left,
        .bearing_y = slot.*.bitmap_top,
        .data = data,
    };
}
