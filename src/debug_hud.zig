//! Optional on-screen debug overlay for frame stats (FPS, dirty regions, overlays).
//!
//! Enable on a window with `window.debug_hud = true`. Apps can toggle at runtime;
//! bind a hotkey in your keymap, e.g. F3:
//! ```zig
//! .{ .chord = .{ .key = .f3 }, .action = actionId("toggle-debug-hud") },
//! ```
//! and flip `window.debug_hud` in the action handler.

const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const scene_mod = @import("scene.zig");
const dirty_mod = @import("dirty.zig");
const text_element = @import("elements/text.zig");
const text_mod = @import("text/text.zig");

const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;
const Rgba = color.Rgba;

/// Snapshot of values shown in the HUD for one frame.
pub const Stats = struct {
    frame_ms: f32,
    fps: f32,
    dirty_full: bool,
    dirty_union: ?Bounds(Pixels) = null,
    overlay_count: usize = 0,
    entity_notify: bool = false,
};

/// When `Window.profiler` is wired, pass its averaged total frame time here.
pub const ProfilerView = struct {
    avg_total_ms: f32,
};

pub fn resolveFrameMs(
    profiler: ?ProfilerView,
    avg_frame_ms: f32,
    anim_dt_ms: f32,
) f32 {
    if (profiler) |p| return p.avg_total_ms;
    if (avg_frame_ms > 0) return avg_frame_ms;
    return anim_dt_ms;
}

pub fn fpsFromMs(frame_ms: f32) f32 {
    if (frame_ms <= 0) return 0;
    return 1000.0 / frame_ms;
}

/// Primary HUD line: `frame 16.7ms (60 fps)`.
pub fn formatHudLine(stats: Stats, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "frame {d:.1}ms ({d:.0} fps)", .{ stats.frame_ms, stats.fps }) catch buf[0..0];
}

fn formatDirtyLine(stats: Stats, buf: []u8) []const u8 {
    if (stats.dirty_full) {
        return std.fmt.bufPrint(buf, "dirty: full", .{}) catch buf[0..0];
    }
    if (stats.dirty_union) |union_bounds| {
        return std.fmt.bufPrint(buf, "dirty: {d:.0}x{d:.0}", .{
            union_bounds.size.width,
            union_bounds.size.height,
        }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "dirty: clean", .{}) catch buf[0..0];
}

fn formatMetaLine(stats: Stats, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "overlays: {d}  notify: {s}", .{
        stats.overlay_count,
        if (stats.entity_notify) "yes" else "no",
    }) catch buf[0..0];
}

pub fn collectStats(
    dirty: *const dirty_mod.DirtyTracker,
    overlay_count: usize,
    entity_notify: bool,
    profiler: ?ProfilerView,
    avg_frame_ms: f32,
    anim_dt_ms: f32,
) Stats {
    const frame_ms = resolveFrameMs(profiler, avg_frame_ms, anim_dt_ms);
    return .{
        .frame_ms = frame_ms,
        .fps = fpsFromMs(frame_ms),
        .dirty_full = dirty.full,
        .dirty_union = dirty.unionBounds(),
        .overlay_count = overlay_count,
        .entity_notify = entity_notify,
    };
}

const panel_bg = Rgba.init(0.05, 0.05, 0.08, 0.82);
const hud_text = Rgba.white;
const font_size: Pixels = 12;
const padding: Pixels = 8;
const line_height: Pixels = 14;
const panel_width: Pixels = 230;

fn paintLine(
    scene: *scene_mod.Scene,
    resources: *text_element.TextResources,
    text: []const u8,
    origin: geometry.Point(Pixels),
    arena: std.mem.Allocator,
) !void {
    const wrapped = try text_mod.shapeWrapped(
        resources.font_system,
        resources.default_font,
        font_size,
        text,
        null,
        arena,
    );
    const clip_f = scene_mod.BoundsF.from(Bounds(Pixels).init(.{}, Size(Pixels).init(100000, 100000)));
    const color_f = scene_mod.ColorF.from(hud_text);

    var pen_y = origin.y;
    for (wrapped.lines) |line| {
        const baseline_y = pen_y + line.ascent;
        var pen_x = origin.x;

        for (line.glyphs) |glyph| {
            const key = text_mod.GlyphKey{
                .font = glyph.font,
                .glyph_id = glyph.glyph_id,
                .size_px_q = text_mod.quantizeSize(font_size),
            };

            const atlas_glyph = resources.atlas.cache.get(key) orelse blk: {
                var bitmap = text_mod.rasterizeGlyphFont(
                    resources.font_system,
                    glyph.font,
                    font_size,
                    glyph.glyph_id,
                    arena,
                ) catch break :blk null;
                defer bitmap.deinit(arena);
                break :blk resources.atlas.getOrInsert(key, bitmap) catch null;
            };

            if (atlas_glyph) |ag| {
                const w: f32 = @floatFromInt(ag.bounds.size.width);
                const h: f32 = @floatFromInt(ag.bounds.size.height);
                if (w > 0 and h > 0) {
                    const glyph_origin = geometry.Point(Pixels){
                        .x = pen_x + glyph.offset.x + @as(f32, @floatFromInt(ag.bearing_x)),
                        .y = baseline_y - glyph.offset.y - @as(f32, @floatFromInt(ag.bearing_y)),
                    };
                    try scene.insertMonochromeSprite(.{
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

/// Draw the HUD panel as the last overlay in the scene. Caller must skip when
/// `Window.debug_hud` is false so the scene stays unchanged.
pub fn paint(
    scene: *scene_mod.Scene,
    arena: std.mem.Allocator,
    stats: Stats,
    text_resources: ?*text_element.TextResources,
) !void {
    const line_count: Pixels = 3;
    const panel_h = padding * 2 + line_height * line_count;
    const panel_bounds = Bounds(Pixels).init(.{ .x = padding, .y = padding }, .{
        .width = panel_width,
        .height = panel_h,
    });

    try scene.insertQuad(.{
        .bounds = scene_mod.BoundsF.from(panel_bounds),
        .clip_bounds = scene_mod.BoundsF.from(panel_bounds),
        .background = scene_mod.ColorF.from(panel_bg),
        .corner_radii = scene_mod.CornersF.from(.{ .top_left = 4, .top_right = 4, .bottom_right = 4, .bottom_left = 4 }),
    });

    if (text_resources) |resources| {
        var line_buf: [96]u8 = undefined;
        const text_origin = panel_bounds.origin.add(.{ .x = padding, .y = padding });

        const line0 = formatHudLine(stats, &line_buf);
        try paintLine(scene, resources, line0, text_origin, arena);

        const line1 = formatDirtyLine(stats, &line_buf);
        try paintLine(
            scene,
            resources,
            line1,
            text_origin.add(.{ .x = 0, .y = line_height }),
            arena,
        );

        const line2 = formatMetaLine(stats, &line_buf);
        try paintLine(
            scene,
            resources,
            line2,
            text_origin.add(.{ .x = 0, .y = line_height * 2 }),
            arena,
        );
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "formatHudLine" {
    var buf: [64]u8 = undefined;
    const line = formatHudLine(.{
        .frame_ms = 16.666,
        .fps = 60,
        .dirty_full = true,
    }, &buf);
    try std.testing.expectEqualStrings("frame 16.7ms (60 fps)", line);
}

test "resolveFrameMs prefers profiler then avg then anim dt" {
    try std.testing.expectEqual(@as(f32, 10), resolveFrameMs(.{ .avg_total_ms = 10 }, 20, 30));
    try std.testing.expectEqual(@as(f32, 20), resolveFrameMs(null, 20, 30));
    try std.testing.expectEqual(@as(f32, 30), resolveFrameMs(null, 0, 30));
}

test "collectStats dirty union size" {
    var dirty: dirty_mod.DirtyTracker = .{ .full = false };
    dirty.markBounds(Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 120, .height = 40 }));

    const stats = collectStats(&dirty, 2, true, null, 8.5, 0);
    try std.testing.expect(!stats.dirty_full);
    try std.testing.expectEqual(@as(f32, 8.5), stats.frame_ms);
    try std.testing.expectEqual(@as(usize, 2), stats.overlay_count);
    try std.testing.expect(stats.entity_notify);
    const union_bounds = stats.dirty_union.?;
    try std.testing.expectEqual(@as(Pixels, 120), union_bounds.size.width);
    try std.testing.expectEqual(@as(Pixels, 40), union_bounds.size.height);
}

test "paint inserts panel quad" {
    var scene = scene_mod.Scene.init(std.testing.allocator);
    defer scene.deinit();

    const before = scene.quads.items.len;
    try paint(&scene, std.testing.allocator, .{
        .frame_ms = 10,
        .fps = 100,
        .dirty_full = false,
    }, null);
    try std.testing.expectEqual(before + 1, scene.quads.items.len);
    try std.testing.expectEqual(@as(usize, 0), scene.monochrome_sprites.items.len);
}

test "disabled hud adds no scene primitives" {
    var scene = scene_mod.Scene.init(std.testing.allocator);
    defer scene.deinit();

    const before = scene.quads.items.len;
    const debug_hud_enabled = false;
    if (debug_hud_enabled) {
        try paint(&scene, std.testing.allocator, .{
            .frame_ms = 10,
            .fps = 100,
            .dirty_full = false,
        }, null);
    }
    try std.testing.expectEqual(before, scene.quads.items.len);
}
