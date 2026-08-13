//! Text element: shapes a UTF-8 string with the text system, sizes itself
//! via a flexbox measure function, and paints glyphs as monochrome sprites
//! from the glyph atlas.

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const layout = @import("../layout/layout.zig");
const element = @import("../element.zig");
const scene_mod = @import("../scene.zig");
const text_mod = @import("../text/text.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Rgba = color.Rgba;
const Element = element.Element;

/// Shared text resources threaded through layout/paint passes. Owned by the
/// window (or test harness), not by elements.
pub const TextResources = struct {
    font_system: *text_mod.FontSystem,
    atlas: *text_mod.GlyphAtlas,
    default_font: text_mod.FontId,
};

pub fn textEl(arena: std.mem.Allocator, resources: *TextResources, content: []const u8) *Text {
    const t = arena.create(Text) catch @panic("frame arena OOM");
    t.* = .{
        .arena = arena,
        .resources = resources,
        .content = content,
    };
    return t;
}

pub const Text = struct {
    arena: std.mem.Allocator,
    resources: *TextResources,
    content: []const u8,
    font_size: Pixels = 14,
    text_color: Rgba = Rgba.black,
    font: ?text_mod.FontId = null,
    max_width: ?Pixels = null,

    // Frame state
    node: ?*layout.Node = null,
    bounds: Bounds(Pixels) = .{},
    shaped: ?text_mod.ShapedLine = null,
    wrapped: ?text_mod.WrappedText = null,

    const vtable = Element.VTable{
        .request_layout = requestLayoutErased,
        .prepaint = prepaintErased,
        .paint = paintErased,
    };

    pub fn any(self: *Text) Element {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn size(self: *Text, font_size: Pixels) *Text {
        self.font_size = font_size;
        return self;
    }

    pub fn withColor(self: *Text, text_color: Rgba) *Text {
        self.text_color = text_color;
        return self;
    }

    pub fn withFont(self: *Text, font: text_mod.FontId) *Text {
        self.font = font;
        return self;
    }

    pub fn withMaxWidth(self: *Text, max_width: ?Pixels) *Text {
        self.max_width = max_width;
        return self;
    }

    fn fontId(self: *const Text) text_mod.FontId {
        return self.font orelse self.resources.default_font;
    }

    /// Shape (and cache) text for this frame.
    fn shapedText(self: *Text) !*const text_mod.WrappedText {
        if (self.wrapped == null) {
            self.wrapped = try text_mod.shapeWrapped(
                self.resources.font_system,
                self.fontId(),
                self.font_size,
                self.content,
                self.max_width,
                self.arena,
            );
        }
        return &self.wrapped.?;
    }

    fn requestLayoutErased(ptr: *anyopaque, pass: *element.LayoutPass) anyerror!*layout.Node {
        const self: *Text = @ptrCast(@alignCast(ptr));
        const node = try pass.arena.create(layout.Node);
        node.* = pass.engine.newNode();
        self.node = node;
        try node.setMeasureFunc(pass.arena, self, measure);
        return node;
    }

    fn measure(
        ctx: *anyopaque,
        _: Pixels,
        _: layout.MeasureMode,
        _: Pixels,
        _: layout.MeasureMode,
    ) layout.MeasureSize {
        const self: *Text = @ptrCast(@alignCast(ctx));
        const wrapped = self.shapedText() catch return .{ .width = 0, .height = 0 };
        return .{
            .width = @ceil(wrapped.width),
            .height = @ceil(wrapped.height),
        };
    }

    fn prepaintErased(ptr: *anyopaque, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
        const self: *Text = @ptrCast(@alignCast(ptr));
        _ = pass;
        const node = self.node orelse return error.LayoutNotRequested;
        const relative = node.layoutBounds();
        self.bounds = .{
            .origin = parent_origin.add(relative.origin),
            .size = relative.size,
        };
    }

    fn paintErased(ptr: *anyopaque, pass: *element.PaintPass) anyerror!void {
        const self: *Text = @ptrCast(@alignCast(ptr));
        const wrapped = try self.shapedText();
        const clip_f = pass.clipF();
        const color_f = scene_mod.ColorF.from(self.text_color);

        var pen_y = self.bounds.origin.y;
        for (wrapped.lines) |line| {
            const baseline_y = pen_y + line.ascent;
            var pen_x = self.bounds.origin.x;

            for (line.glyphs) |glyph| {
                const key = text_mod.GlyphKey{
                    .font = glyph.font,
                    .glyph_id = glyph.glyph_id,
                    .size_px_q = text_mod.quantizeSize(self.font_size),
                };

                const atlas_glyph = self.resources.atlas.cache.get(key) orelse blk: {
                    var bitmap = text_mod.rasterizeGlyphFont(
                        self.resources.font_system,
                        glyph.font,
                        self.font_size,
                        glyph.glyph_id,
                        self.arena,
                    ) catch break :blk null;
                    defer bitmap.deinit(self.arena);
                    break :blk self.resources.atlas.getOrInsert(key, bitmap) catch null;
                };

                if (atlas_glyph) |ag| {
                    const w: f32 = @floatFromInt(ag.bounds.size.width);
                    const h: f32 = @floatFromInt(ag.bounds.size.height);
                    if (w > 0 and h > 0) {
                        const glyph_origin = Point(Pixels){
                            .x = pen_x + glyph.offset.x + @as(f32, @floatFromInt(ag.bearing_x)),
                            .y = baseline_y - glyph.offset.y - @as(f32, @floatFromInt(ag.bearing_y)),
                        };
                        try pass.scene.insertMonochromeSprite(.{
                            .bounds = .{
                                .origin_x = glyph_origin.x,
                                .origin_y = glyph_origin.y,
                                .size_w = w,
                                .size_h = h,
                            },
                            .clip_bounds = clip_f,
                            .uv_bounds = .{
                                .origin_x = @floatFromInt(ag.bounds.origin.x),
                                .origin_y = @floatFromInt(ag.bounds.origin.y),
                                .size_w = @floatFromInt(ag.bounds.size.width),
                                .size_h = @floatFromInt(ag.bounds.size.height),
                            },
                            .color = color_f,
                        });
                    }
                }

                pen_x += glyph.advance;
            }

            pen_y += line.ascent + line.descent;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn loadTestFont(fs: *text_mod.FontSystem) !text_mod.FontId {
    const candidates = [_][:0]const u8{
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Monaco.ttf",
    };
    for (candidates) |path| {
        return fs.loadFont(path, 0) catch continue;
    }
    return error.SkipZigTest;
}

test "text element measures, layouts and paints glyphs" {
    const allocator = std.testing.allocator;

    var font_system = text_mod.FontSystem.init(allocator) catch return error.SkipZigTest;
    defer font_system.deinit();
    const font = try loadTestFont(&font_system);

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

    const label = textEl(arena, &resources, "Hi zgpui").size(16).withColor(Rgba.white);

    var layout_pass = element.LayoutPass{ .arena = arena, .engine = &engine };
    const node = try label.any().requestLayout(&layout_pass);
    defer node.free();
    engine.computeLayout(node, null, null);

    var frame = element.FrameState.init(allocator);
    defer frame.deinit();
    var prepaint_pass = element.PrepaintPass{ .arena = arena, .frame = &frame };
    try label.any().prepaint(&prepaint_pass, .{});

    try std.testing.expect(label.bounds.size.width > 0);
    try std.testing.expect(label.bounds.size.height > 0);

    var scene = scene_mod.Scene.init(allocator);
    defer scene.deinit();
    var paint_pass = element.PaintPass{ .scene = &scene };
    try label.any().paint(&paint_pass);

    try std.testing.expect(scene.monochrome_sprites.items.len > 0);
    try std.testing.expect(atlas.dirty);
}

test "text element wraps to max_width" {
    const allocator = std.testing.allocator;

    var font_system = text_mod.FontSystem.init(allocator) catch return error.SkipZigTest;
    defer font_system.deinit();
    const font = try loadTestFont(&font_system);

    var atlas = try text_mod.GlyphAtlas.init(allocator, geometry.Size(i32).init(512, 512));
    defer atlas.deinit();

    var resources = TextResources{
        .font_system = &font_system,
        .atlas = &atlas,
        .default_font = font,
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var single = try text_mod.shape(&font_system, font, 16.0, "hello world", allocator);
    defer single.deinit(allocator);
    const max_width = single.width * 0.55;

    const label = textEl(arena, &resources, "hello world")
        .size(16)
        .withMaxWidth(max_width);

    var engine = layout.LayoutEngine.init();
    defer engine.deinit();

    var layout_pass = element.LayoutPass{ .arena = arena, .engine = &engine };
    const node = try label.any().requestLayout(&layout_pass);
    defer node.free();
    engine.computeLayout(node, null, null);

    const layout_size = node.layoutBounds().size;
    try std.testing.expect(layout_size.height > @ceil(single.ascent + single.descent));
    try std.testing.expect(layout_size.width <= max_width + 1);
}
