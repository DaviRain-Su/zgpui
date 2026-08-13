//! HarfBuzz text shaping with font fallback for missing glyphs.

const std = @import("std");
const c = @import("text_c");
const geometry = @import("../geometry.zig");
const font = @import("font.zig");

pub const Pixels = geometry.Pixels;
pub const Point = geometry.Point;
pub const FontId = font.FontId;
pub const FontSystem = font.FontSystem;

pub const ShapedGlyph = struct {
    font: FontId,
    glyph_id: u32,
    cluster: u32,
    offset: Point(Pixels),
    advance: Pixels,
};

pub const ShapedLine = struct {
    glyphs: []ShapedGlyph,
    width: Pixels,
    ascent: Pixels,
    descent: Pixels,

    pub fn deinit(self: *ShapedLine, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        self.* = undefined;
    }
};

fn fixed26Dot6ToPixels(value: c.hb_position_t) Pixels {
    return @as(Pixels, @floatFromInt(value)) / 64.0;
}

fn decodeUtf8Scalar(text: []const u8, byte_offset: usize) ?u32 {
    if (byte_offset >= text.len) return null;
    const slice = text[byte_offset..];
    const decoded = std.unicode.utf8Decode(slice) catch return null;
    return decoded;
}

fn shapeRun(
    font_system: *FontSystem,
    font_id: FontId,
    size_px: f32,
    utf8_text: []const u8,
    allocator: std.mem.Allocator,
) ![]ShapedGlyph {
    const face = try font_system.getFace(font_id);
    try font_system.setPixelSize(font_id, size_px);

    const hb_font = c.hb_ft_font_create(face, null) orelse return error.ShapeFailed;
    defer c.hb_font_destroy(hb_font);

    const buffer = c.hb_buffer_create() orelse return error.ShapeFailed;
    defer c.hb_buffer_destroy(buffer);

    c.hb_buffer_add_utf8(
        buffer,
        utf8_text.ptr,
        @intCast(utf8_text.len),
        0,
        @intCast(utf8_text.len),
    );
    c.hb_buffer_guess_segment_properties(buffer);
    c.hb_shape(hb_font, buffer, null, 0);

    var glyph_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(buffer, &glyph_count);
    const positions = c.hb_buffer_get_glyph_positions(buffer, &glyph_count);

    const glyphs = try allocator.alloc(ShapedGlyph, glyph_count);
    errdefer allocator.free(glyphs);

    for (0..glyph_count) |i| {
        const info = infos[i];
        const pos = positions[i];
        glyphs[i] = .{
            .font = font_id,
            .glyph_id = info.codepoint,
            .cluster = info.cluster,
            .offset = .{
                .x = fixed26Dot6ToPixels(pos.x_offset),
                .y = fixed26Dot6ToPixels(pos.y_offset),
            },
            .advance = fixed26Dot6ToPixels(pos.x_advance),
        };
    }
    return glyphs;
}

fn applyFallbacks(
    font_system: *FontSystem,
    primary: FontId,
    size_px: f32,
    utf8_text: []const u8,
    glyphs: []ShapedGlyph,
    allocator: std.mem.Allocator,
) ![]ShapedGlyph {
    if (font_system.fallbacks.items.len == 0) return glyphs;

    var current = glyphs;
    var i: usize = 0;
    while (i < current.len) {
        if (!font_system.isMissingGlyph(current[i].glyph_id)) {
            i += 1;
            continue;
        }

        const cluster_start = current[i].cluster;
        var cluster_end = utf8_text.len;
        var j = i + 1;
        while (j < current.len) : (j += 1) {
            if (current[j].cluster != cluster_start) {
                cluster_end = current[j].cluster;
                break;
            }
        }

        const scalar = decodeUtf8Scalar(utf8_text, cluster_start) orelse {
            i = j;
            continue;
        };
        const resolved = try font_system.resolveGlyph(primary, scalar);

        if (font_system.isMissingGlyph(resolved.glyph_id)) {
            current[i].font = resolved.font;
            current[i].glyph_id = resolved.glyph_id;
            i = j;
            continue;
        }

        const cluster_text = utf8_text[cluster_start..cluster_end];
        const replacement = try shapeRun(font_system, resolved.font, size_px, cluster_text, allocator);
        defer allocator.free(replacement);

        if (replacement.len == 0) {
            current[i].font = resolved.font;
            current[i].glyph_id = resolved.glyph_id;
            i = j;
            continue;
        }

        const cluster_len = j - i;
        if (replacement.len == cluster_len) {
            for (0..cluster_len) |k| {
                current[i + k].font = replacement[k].font;
                current[i + k].glyph_id = replacement[k].glyph_id;
                current[i + k].offset = replacement[k].offset;
                current[i + k].advance = replacement[k].advance;
            }
            i = j;
            continue;
        }

        const new_glyphs = try allocator.alloc(ShapedGlyph, current.len - cluster_len + replacement.len);
        @memcpy(new_glyphs[0..i], current[0..i]);
        @memcpy(new_glyphs[i .. i + replacement.len], replacement);
        @memcpy(new_glyphs[i + replacement.len ..], current[j..]);

        allocator.free(current);
        current = new_glyphs;
        i += replacement.len;
    }
    return current;
}

/// Shapes UTF-8 text with HarfBuzz using the sized FreeType face.
/// Pixel size is applied per call via `size_px`.
pub fn shape(
    font_system: *FontSystem,
    font_id: FontId,
    size_px: f32,
    utf8_text: []const u8,
    allocator: std.mem.Allocator,
) !ShapedLine {
    var glyphs = try shapeRun(font_system, font_id, size_px, utf8_text, allocator);
    errdefer allocator.free(glyphs);

    glyphs = try applyFallbacks(font_system, font_id, size_px, utf8_text, glyphs, allocator);
    errdefer allocator.free(glyphs);

    var width: Pixels = 0;
    for (glyphs) |glyph| width += glyph.advance;

    const metrics = try font_system.lineMetrics(font_id, size_px);
    return .{
        .glyphs = glyphs,
        .width = width,
        .ascent = metrics.ascent,
        .descent = metrics.descent,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const cjk_font_paths = [_][:0]const u8{
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
};

const latin_font_paths = [_][:0]const u8{
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Monaco.ttf",
};

fn loadLatinFont(fs: *FontSystem) !FontId {
    for (latin_font_paths) |path| {
        if (fs.loadFont(path, 0)) |id| return id else |_| {}
    }
    return error.SkipZigTest;
}

fn loadCjkFont(fs: *FontSystem) !FontId {
    for (cjk_font_paths) |path| {
        if (fs.loadFont(path, 0)) |id| return id else |_| {}
    }
    return error.SkipZigTest;
}

test "font fallback shapes CJK without empty glyphs" {
    const allocator = std.testing.allocator;

    var fs = try FontSystem.init(allocator);
    defer fs.deinit();

    const latin = try loadLatinFont(&fs);
    const cjk = loadCjkFont(&fs) catch return error.SkipZigTest;
    try fs.addFallback(cjk);

    var line = try shape(&fs, latin, 16.0, "A\u{4E16}", allocator);
    defer line.deinit(allocator);

    try std.testing.expect(line.glyphs.len >= 2);

    var has_cjk_glyph = false;
    for (line.glyphs) |glyph| {
        try std.testing.expect(glyph.glyph_id > 0);
        if (glyph.font == cjk) has_cjk_glyph = true;
    }
    try std.testing.expect(has_cjk_glyph);
}
