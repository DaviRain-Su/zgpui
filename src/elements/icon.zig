//! Icon element: rasterizes an embedded SVG (via NanoSVG) into the glyph atlas
//! and paints a tinted monochrome sprite.

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const layout = @import("../layout/layout.zig");
const element = @import("../element.zig");
const scene_mod = @import("../scene.zig");
const text_mod = @import("../text/text.zig");
const text_element = @import("text.zig");
const svg = @import("../svg.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Rgba = color.Rgba;
const Element = element.Element;
const TextResources = text_element.TextResources;

/// Reserved atlas font id for SVG icons (never a FreeType face).
pub const atlas_font_id: text_mod.FontId = std.math.maxInt(text_mod.FontId);

pub fn iconEl(arena: std.mem.Allocator, resources: *TextResources, path: []const u8) *Icon {
    const ic = arena.create(Icon) catch @panic("frame arena OOM");
    ic.* = .{
        .arena = arena,
        .resources = resources,
        .path = path,
    };
    return ic;
}

pub const Icon = struct {
    arena: std.mem.Allocator,
    resources: *TextResources,
    path: []const u8,
    size_px: Pixels = 16,
    tint: Rgba = Rgba.white,
    a11y_name: ?[]const u8 = null,

    node: ?*layout.Node = null,
    bounds: Bounds(Pixels) = .{},

    const vtable = Element.VTable{
        .request_layout = requestLayoutErased,
        .prepaint = prepaintErased,
        .paint = paintErased,
    };

    pub fn any(self: *Icon) Element {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn size(self: *Icon, size_px: Pixels) *Icon {
        self.size_px = size_px;
        return self;
    }

    pub fn withColor(self: *Icon, tint: Rgba) *Icon {
        self.tint = tint;
        return self;
    }

    pub fn withName(self: *Icon, name: []const u8) *Icon {
        self.a11y_name = name;
        return self;
    }

    fn requestLayout(self: *Icon, pass: *element.LayoutPass) !*layout.Node {
        const node = try pass.arena.create(layout.Node);
        node.* = pass.engine.newNode();
        node.setWidth(.{ .points = self.size_px });
        node.setHeight(.{ .points = self.size_px });
        node.setFlexGrow(0);
        node.setFlexShrink(0);
        self.node = node;
        return node;
    }

    fn prepaint(self: *Icon, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) !void {
        const node = self.node orelse return;
        const local = node.layoutBounds();
        self.bounds = .{
            .origin = .{
                .x = parent_origin.x + local.origin.x,
                .y = parent_origin.y + local.origin.y,
            },
            .size = local.size,
        };
        if (self.a11y_name) |name| {
            try pass.frame.registerA11y(.{
                .id = element.elementId(self.path),
                .role = .img,
                .name = .{ .label = name },
                .bounds = self.bounds,
            });
        }
    }

    fn paint(self: *Icon, pass: *element.PaintPass) !void {
        const px: u32 = @intFromFloat(@round(@max(self.size_px, 1)));
        const key = text_mod.GlyphKey{
            .font = atlas_font_id,
            .glyph_id = pathHash(self.path),
            .size_px_q = text_mod.quantizeSize(self.size_px),
        };

        const atlas_glyph = self.resources.atlas.cache.get(key) orelse blk: {
            var alpha = svg.rasterizeIcon(self.arena, self.path, px) catch break :blk null;
            defer alpha.deinit(self.arena);
            const bitmap = text_mod.GlyphBitmap{
                .width = alpha.width,
                .height = alpha.height,
                .bearing_x = 0,
                .bearing_y = @intCast(alpha.height),
                .data = alpha.data,
            };
            break :blk self.resources.atlas.getOrInsert(key, bitmap) catch null;
        };

        const ag = atlas_glyph orelse return;
        const w: f32 = @floatFromInt(ag.bounds.size.width);
        const h: f32 = @floatFromInt(ag.bounds.size.height);
        if (w <= 0 or h <= 0) return;

        const ox = self.bounds.origin.x + (self.bounds.size.width - w) * 0.5;
        const oy = self.bounds.origin.y + (self.bounds.size.height - h) * 0.5;

        try pass.scene.insertMonochromeSprite(.{
            .bounds = .{
                .origin_x = ox,
                .origin_y = oy,
                .size_w = w,
                .size_h = h,
            },
            .clip_bounds = scene_mod.BoundsF.from(self.bounds),
            .uv_bounds = .{
                .origin_x = @floatFromInt(ag.bounds.origin.x),
                .origin_y = @floatFromInt(ag.bounds.origin.y),
                .size_w = @floatFromInt(ag.bounds.size.width),
                .size_h = @floatFromInt(ag.bounds.size.height),
            },
            .color = scene_mod.ColorF.from(self.tint),
        });
    }

    fn requestLayoutErased(ptr: *anyopaque, pass: *element.LayoutPass) anyerror!*layout.Node {
        return @as(*Icon, @ptrCast(@alignCast(ptr))).requestLayout(pass);
    }
    fn prepaintErased(ptr: *anyopaque, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
        return @as(*Icon, @ptrCast(@alignCast(ptr))).prepaint(pass, parent_origin);
    }
    fn paintErased(ptr: *anyopaque, pass: *element.PaintPass) anyerror!void {
        return @as(*Icon, @ptrCast(@alignCast(ptr))).paint(pass);
    }
};

fn pathHash(path: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, path));
}

test "icon element layouts to size" {
    const allocator = std.testing.allocator;
    var font_system = text_mod.FontSystem.init(allocator) catch return error.SkipZigTest;
    defer font_system.deinit();
    const font = text_mod.loadTestFont(&font_system) catch return error.SkipZigTest;

    var atlas = try text_mod.GlyphAtlas.init(allocator, geometry.Size(i32).init(256, 256));
    defer atlas.deinit();
    var resources = TextResources{
        .font_system = &font_system,
        .atlas = &atlas,
        .default_font = font,
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var engine = layout.LayoutEngine.init();
    defer engine.deinit();

    const icons = @import("../icons.zig");
    const ic = iconEl(arena, &resources, icons.check).size(20).withColor(Rgba.white);

    var layout_pass = element.LayoutPass{ .arena = arena, .engine = &engine };
    const node = try ic.any().requestLayout(&layout_pass);
    engine.computeLayout(node, null, null);

    var frame = element.FrameState.init(allocator);
    defer frame.deinit();
    var prepaint_pass = element.PrepaintPass{ .arena = arena, .scratch = arena, .frame = &frame };
    try ic.any().prepaint(&prepaint_pass, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 20), ic.bounds.size.width, 0.01);

    var scene = scene_mod.Scene.init(allocator);
    defer scene.deinit();
    var paint_pass = element.PaintPass{ .scratch = arena, .scene = &scene };
    try ic.any().paint(&paint_pass);
    try std.testing.expect(scene.monochrome_sprites.items.len >= 1);
}
