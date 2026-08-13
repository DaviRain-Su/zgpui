//! Single-channel glyph atlas with shelf packing.

const std = @import("std");
const geometry = @import("../geometry.zig");
const font = @import("font.zig");

pub const FontId = font.FontId;
pub const Bounds = geometry.Bounds;
pub const Size = geometry.Size;
pub const GlyphBitmap = font.GlyphBitmap;

pub const default_atlas_size = Size(i32).init(1024, 1024);
const shelf_padding: i32 = 1;

pub const GlyphKey = struct {
    font: FontId,
    glyph_id: u32,
    size_px_q: u32,

    pub fn fromSize(id: FontId, glyph_id: u32, size_px: f32) GlyphKey {
        return .{
            .font = id,
            .glyph_id = glyph_id,
            .size_px_q = quantizeSize(size_px),
        };
    }
};

pub fn quantizeSize(size_px: f32) u32 {
    return @intFromFloat(@round(size_px * 4.0));
}

pub const AtlasGlyph = struct {
    bounds: Bounds(i32),
    bearing_x: i32,
    bearing_y: i32,
};

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    size: Size(i32),
    dirty: bool,
    cache: std.AutoHashMap(GlyphKey, AtlasGlyph),
    shelf_x: i32,
    shelf_y: i32,
    shelf_height: i32,

    pub fn init(allocator: std.mem.Allocator, atlas_size: Size(i32)) !GlyphAtlas {
        const byte_len = @as(usize, @intCast(atlas_size.width)) * @as(usize, @intCast(atlas_size.height));
        const data = try allocator.alloc(u8, byte_len);
        @memset(data, 0);
        return .{
            .allocator = allocator,
            .data = data,
            .size = atlas_size,
            .dirty = false,
            .cache = std.AutoHashMap(GlyphKey, AtlasGlyph).init(allocator),
            .shelf_x = 0,
            .shelf_y = 0,
            .shelf_height = 0,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.cache.deinit();
        self.allocator.free(self.data);
    }

    pub fn getOrInsert(self: *GlyphAtlas, key: GlyphKey, bitmap: GlyphBitmap) !AtlasGlyph {
        if (self.cache.get(key)) |existing| return existing;

        const padded_w = @as(i32, @intCast(bitmap.width)) + shelf_padding * 2;
        const padded_h = @as(i32, @intCast(bitmap.height)) + shelf_padding * 2;

        if (self.shelf_x + padded_w > self.size.width) {
            self.shelf_y += self.shelf_height;
            self.shelf_x = 0;
            self.shelf_height = 0;
        }
        if (self.shelf_y + padded_h > self.size.height) return error.AtlasFull;

        const origin_x = self.shelf_x;
        const origin_y = self.shelf_y;
        try self.blit(origin_x + shelf_padding, origin_y + shelf_padding, bitmap);

        self.shelf_x += padded_w;
        self.shelf_height = @max(self.shelf_height, padded_h);
        self.dirty = true;

        const atlas_glyph = AtlasGlyph{
            .bounds = .{
                .origin = .{
                    .x = origin_x + shelf_padding,
                    .y = origin_y + shelf_padding,
                },
                .size = .{
                    .width = @intCast(bitmap.width),
                    .height = @intCast(bitmap.height),
                },
            },
            .bearing_x = bitmap.bearing_x,
            .bearing_y = bitmap.bearing_y,
        };
        try self.cache.put(key, atlas_glyph);
        return atlas_glyph;
    }

    fn blit(self: *GlyphAtlas, dst_x: i32, dst_y: i32, bitmap: GlyphBitmap) !void {
        if (bitmap.width == 0 or bitmap.height == 0) return;
        const atlas_w: usize = @intCast(self.size.width);

        var row: u32 = 0;
        while (row < bitmap.height) : (row += 1) {
            const dst_row = @as(usize, @intCast(dst_y + @as(i32, @intCast(row)))) * atlas_w +
                @as(usize, @intCast(dst_x));
            const src_row = @as(usize, row) * bitmap.width;
            @memcpy(
                self.data[dst_row .. dst_row + bitmap.width],
                bitmap.data[src_row .. src_row + bitmap.width],
            );
        }
    }
};
