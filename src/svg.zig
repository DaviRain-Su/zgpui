//! Optional SVG → single-channel alpha rasterizer (NanoSVG).
//!
//! Used to turn embedded Solar / hand icons into atlas-ready coverage masks
//! that paint as monochrome sprites. Not a full SVG/CSS engine.

const std = @import("std");
const c = @import("nanosvg_c");
const icons = @import("icons.zig");

pub const AlphaBitmap = struct {
    width: u32,
    height: u32,
    /// Row-major coverage, `width * height` bytes.
    data: []u8,

    pub fn deinit(self: *AlphaBitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Rasterize SVG XML (`svg_xml`) into an alpha mask whose longer side is
/// about `size_px` pixels. `currentColor` is rewritten to black so stroke icons
/// produce coverage; the result is tinted at paint time.
pub fn rasterize(allocator: std.mem.Allocator, svg_xml: []const u8, size_px: u32) !AlphaBitmap {
    if (size_px == 0) return error.InvalidSize;

    var editable = try allocator.alloc(u8, svg_xml.len + 1);
    defer allocator.free(editable);
    @memcpy(editable[0..svg_xml.len], svg_xml);
    editable[svg_xml.len] = 0;
    rewriteCurrentColor(editable[0..svg_xml.len]);

    const image = c.nsvgParse(editable.ptr, "px", 96.0) orelse return error.SvgParseFailed;
    defer c.nsvgDelete(image);

    const iw = image.*.width;
    const ih = image.*.height;
    if (!(iw > 0) or !(ih > 0)) return error.SvgEmpty;

    const scale = @as(f32, @floatFromInt(size_px)) / @max(iw, ih);
    const w: u32 = @intFromFloat(@ceil(iw * scale));
    const h: u32 = @intFromFloat(@ceil(ih * scale));
    if (w == 0 or h == 0) return error.SvgEmpty;

    const rast = c.nsvgCreateRasterizer() orelse return error.SvgRasterizerFailed;
    defer c.nsvgDeleteRasterizer(rast);

    const rgba = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    defer allocator.free(rgba);
    @memset(rgba, 0);

    c.nsvgRasterize(rast, image, 0, 0, scale, rgba.ptr, @intCast(w), @intCast(h), @intCast(w * 4));

    const alpha = try allocator.alloc(u8, @as(usize, w) * @as(usize, h));
    errdefer allocator.free(alpha);
    var i: usize = 0;
    while (i < alpha.len) : (i += 1) {
        const r = rgba[i * 4];
        const g = rgba[i * 4 + 1];
        const b = rgba[i * 4 + 2];
        const a = rgba[i * 4 + 3];
        alpha[i] = @max(a, @max(r, @max(g, b)));
    }

    return .{ .width = w, .height = h, .data = alpha };
}

/// Rasterize a catalog icon by logical path (`icons/….svg`).
pub fn rasterizeIcon(allocator: std.mem.Allocator, path: []const u8, size_px: u32) !AlphaBitmap {
    const bytes = icons.load(path) orelse return error.UnknownIcon;
    return rasterize(allocator, bytes, size_px);
}

fn rewriteCurrentColor(buf: []u8) void {
    const needle = "currentColor";
    const replacement = "black       "; // same length, spaces pad
    var i: usize = 0;
    while (i + needle.len <= buf.len) {
        if (std.mem.eql(u8, buf[i..][0..needle.len], needle)) {
            @memcpy(buf[i..][0..needle.len], replacement);
            i += needle.len;
        } else {
            i += 1;
        }
    }
}

fn coverageRatio(bitmap: AlphaBitmap) f32 {
    if (bitmap.data.len == 0) return 0;
    var sum: u64 = 0;
    for (bitmap.data) |p| sum += p;
    return @as(f32, @floatFromInt(sum)) / (@as(f32, @floatFromInt(bitmap.data.len)) * 255.0);
}

test "rasterize check icon has coverage" {
    var bmp = try rasterizeIcon(std.testing.allocator, icons.check, 24);
    defer bmp.deinit(std.testing.allocator);
    try std.testing.expect(bmp.width > 0 and bmp.height > 0);
    try std.testing.expect(coverageRatio(bmp) > 0.01);
}

test "rasterize plus icon" {
    var bmp = try rasterizeIcon(std.testing.allocator, icons.plus, 16);
    defer bmp.deinit(std.testing.allocator);
    try std.testing.expect(coverageRatio(bmp) > 0.01);
}

test "unknown icon errors" {
    try std.testing.expectError(error.UnknownIcon, rasterizeIcon(std.testing.allocator, "icons/nope.svg", 16));
}
