//! Soft line wrapping for shaped text.
//!
//! Line height is the sum of each line's `(ascent + descent)` from the primary
//! font metrics. No extra leading is added between lines.

const std = @import("std");
const geometry = @import("../geometry.zig");
const shape_mod = @import("shape.zig");
const font = @import("font.zig");

pub const Pixels = geometry.Pixels;
pub const FontId = font.FontId;
pub const FontSystem = font.FontSystem;
pub const ShapedLine = shape_mod.ShapedLine;
pub const shape = shape_mod.shape;

const wrap_epsilon: Pixels = 0.5;

const LineMetrics = font.LineMetrics;

pub const WrappedText = struct {
    lines: []ShapedLine,
    /// Maximum line width across all lines.
    width: Pixels,
    /// Sum of each line's `(ascent + descent)`.
    height: Pixels,

    pub fn deinit(self: *WrappedText, allocator: std.mem.Allocator) void {
        for (self.lines) |*line| line.deinit(allocator);
        allocator.free(self.lines);
        self.* = undefined;
    }
};

/// Shapes UTF-8 text, optionally wrapping to `max_width` logical pixels.
/// When `max_width` is null the result is a single line (same as `shape`).
pub fn shapeWrapped(
    font_system: *FontSystem,
    font_id: FontId,
    size_px: f32,
    utf8_text: []const u8,
    max_width: ?Pixels,
    allocator: std.mem.Allocator,
) !WrappedText {
    if (max_width == null or utf8_text.len == 0) {
        var line = try shape(font_system, font_id, size_px, utf8_text, allocator);
        errdefer line.deinit(allocator);

        const lines = try allocator.alloc(ShapedLine, 1);
        lines[0] = line;
        const line_height = line.ascent + line.descent;
        return .{
            .lines = lines,
            .width = line.width,
            .height = line_height,
        };
    }

    const limit = max_width.?;
    const metrics: LineMetrics = try font_system.lineMetrics(font_id, size_px);
    const line_height = metrics.ascent + metrics.descent;

    var shaped_lines: std.ArrayList(ShapedLine) = .empty;
    errdefer {
        for (shaped_lines.items) |*ln| ln.deinit(allocator);
        shaped_lines.deinit(allocator);
    }

    var max_line_width: Pixels = 0;
    var total_height: Pixels = 0;

    var cursor: usize = 0;
    while (cursor < utf8_text.len) {
        cursor = skipWhitespace(utf8_text, cursor);
        if (cursor >= utf8_text.len) break;

        var line_start = cursor;
        var line_width: Pixels = 0;
        var line_end = cursor;

        while (cursor < utf8_text.len) {
            const ws_start = cursor;
            cursor = skipWhitespace(utf8_text, cursor);
            if (cursor >= utf8_text.len) {
                line_end = ws_start;
                break;
            }

            const word_start = cursor;
            cursor = nextWordEnd(utf8_text, cursor);
            const word = utf8_text[word_start..cursor];

            var word_line = try shape(font_system, font_id, size_px, word, allocator);
            defer word_line.deinit(allocator);

            const needs_space = line_end > line_start and line_end < word_start;
            const space_extra = if (needs_space) blk: {
                var sp = try shape(font_system, font_id, size_px, " ", allocator);
                defer sp.deinit(allocator);
                break :blk sp.width;
            } else 0;

            if (word_line.width > limit) {
                if (line_end > line_start) {
                    try appendLine(
                        font_system,
                        font_id,
                        size_px,
                        utf8_text[line_start..line_end],
                        metrics,
                        &shaped_lines,
                        &max_line_width,
                        &total_height,
                        line_height,
                        allocator,
                    );
                    line_start = word_start;
                    line_width = 0;
                    line_end = word_start;
                }
                try breakLongWord(
                    font_system,
                    font_id,
                    size_px,
                    word,
                    limit,
                    metrics,
                    &shaped_lines,
                    &max_line_width,
                    &total_height,
                    line_height,
                    allocator,
                );
                line_start = cursor;
                line_width = 0;
                line_end = cursor;
                continue;
            }

            const candidate_width = line_width + space_extra + word_line.width;
            if (candidate_width > limit + wrap_epsilon and line_end > line_start) {
                try appendLine(
                    font_system,
                    font_id,
                    size_px,
                    utf8_text[line_start..line_end],
                    metrics,
                    &shaped_lines,
                    &max_line_width,
                    &total_height,
                    line_height,
                    allocator,
                );
                line_start = word_start;
                line_width = word_line.width;
                line_end = cursor;
            } else {
                line_width = candidate_width;
                line_end = cursor;
            }
        }

        if (line_end > line_start) {
            try appendLine(
                font_system,
                font_id,
                size_px,
                utf8_text[line_start..line_end],
                metrics,
                &shaped_lines,
                &max_line_width,
                &total_height,
                line_height,
                allocator,
            );
        }
    }

    if (shaped_lines.items.len == 0) {
        var empty = try shape(font_system, font_id, size_px, "", allocator);
        errdefer empty.deinit(allocator);
        try shaped_lines.append(allocator, empty);
        max_line_width = 0;
        total_height = line_height;
    }

    return .{
        .lines = try shaped_lines.toOwnedSlice(allocator),
        .width = max_line_width,
        .height = total_height,
    };
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i;
}

fn nextWordEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and !std.ascii.isWhitespace(text[i])) i += 1;
    return i;
}

fn appendLine(
    font_system: *FontSystem,
    font_id: FontId,
    size_px: f32,
    substring: []const u8,
    metrics: LineMetrics,
    shaped_lines: *std.ArrayList(ShapedLine),
    max_line_width: *Pixels,
    total_height: *Pixels,
    line_height: Pixels,
    allocator: std.mem.Allocator,
) !void {
    if (substring.len == 0) return;
    var line = try shape(font_system, font_id, size_px, substring, allocator);
    line.ascent = metrics.ascent;
    line.descent = metrics.descent;
    try shaped_lines.append(allocator, line);
    max_line_width.* = @max(max_line_width.*, line.width);
    total_height.* += line_height;
}

fn breakLongWord(
    font_system: *FontSystem,
    font_id: FontId,
    size_px: f32,
    word: []const u8,
    max_width: Pixels,
    metrics: LineMetrics,
    shaped_lines: *std.ArrayList(ShapedLine),
    max_line_width: *Pixels,
    total_height: *Pixels,
    line_height: Pixels,
    allocator: std.mem.Allocator,
) !void {
    var full = try shape(font_system, font_id, size_px, word, allocator);
    defer full.deinit(allocator);

    if (full.glyphs.len == 0) {
        try appendLine(
            font_system,
            font_id,
            size_px,
            word,
            metrics,
            shaped_lines,
            max_line_width,
            total_height,
            line_height,
            allocator,
        );
        return;
    }

    var start: usize = 0;
    var run_width: Pixels = 0;

    for (full.glyphs, 0..) |glyph, i| {
        const next_width = run_width + glyph.advance;
        if (next_width > max_width + wrap_epsilon and i > start) {
            try appendGlyphSlice(
                full.glyphs[start..i],
                metrics,
                shaped_lines,
                max_line_width,
                total_height,
                line_height,
                allocator,
            );
            start = i;
            run_width = glyph.advance;
        } else {
            run_width = next_width;
        }
    }

    if (start < full.glyphs.len) {
        try appendGlyphSlice(
            full.glyphs[start..],
            metrics,
            shaped_lines,
            max_line_width,
            total_height,
            line_height,
            allocator,
        );
    }
}

fn appendGlyphSlice(
    glyphs: []const shape_mod.ShapedGlyph,
    metrics: LineMetrics,
    shaped_lines: *std.ArrayList(ShapedLine),
    max_line_width: *Pixels,
    total_height: *Pixels,
    line_height: Pixels,
    allocator: std.mem.Allocator,
) !void {
    const owned = try allocator.alloc(shape_mod.ShapedGlyph, glyphs.len);
    @memcpy(owned, glyphs);

    var width: Pixels = 0;
    for (owned) |g| width += g.advance;

    const line = ShapedLine{
        .glyphs = owned,
        .width = width,
        .ascent = metrics.ascent,
        .descent = metrics.descent,
    };
    try shaped_lines.append(allocator, line);
    max_line_width.* = @max(max_line_width.*, width);
    total_height.* += line_height;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn loadTestFont(fs: *FontSystem) !FontId {
    return font.loadTestFont(fs);
}

test "wrap hello world forces multiple lines" {
    const allocator = std.testing.allocator;

    var fs = try FontSystem.init(allocator);
    defer fs.deinit();
    const font_id = try loadTestFont(&fs);

    var single = try shape(&fs, font_id, 16.0, "hello world", allocator);
    defer single.deinit(allocator);

    // Pick a width that fits "hello" but not "hello world".
    const max_width = single.width * 0.55;

    var wrapped = try shapeWrapped(&fs, font_id, 16.0, "hello world", max_width, allocator);
    defer wrapped.deinit(allocator);

    try std.testing.expect(wrapped.lines.len >= 2);
    try std.testing.expect(wrapped.width <= max_width + wrap_epsilon);
    try std.testing.expect(wrapped.height > single.ascent + single.descent);
}

test "no-wrap path matches single-line shape" {
    const allocator = std.testing.allocator;

    var fs = try FontSystem.init(allocator);
    defer fs.deinit();
    const font_id = try loadTestFont(&fs);

    var wrapped = try shapeWrapped(&fs, font_id, 16.0, "hello world", null, allocator);
    defer wrapped.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);

    var direct = try shape(&fs, font_id, 16.0, "hello world", allocator);
    defer direct.deinit(allocator);

    try std.testing.expectApproxEqAbs(direct.width, wrapped.width, wrap_epsilon);
    try std.testing.expectApproxEqAbs(direct.ascent + direct.descent, wrapped.height, wrap_epsilon);
}

test "wrap does not leak" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const allocator = gpa.allocator();

    var fs = try FontSystem.init(allocator);
    defer fs.deinit();
    const font_id = try loadTestFont(&fs);

    var wrapped = try shapeWrapped(&fs, font_id, 16.0, "hello world", 40.0, allocator);
    wrapped.deinit(allocator);
}
