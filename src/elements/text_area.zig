//! Headless multi-line text area: editable buffer with caret/selection,
//! keyboard and `text_input` event handling, and multi-line painting.

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const layout = @import("../layout/layout.zig");
const element = @import("../element.zig");
const scene_mod = @import("../scene.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const a11y_mod = @import("../a11y.zig");
const text_el = @import("text.zig");
const text_input_mod = @import("text_input.zig");
const text_mod = @import("../text/text.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Rgba = color.Rgba;
const Element = element.Element;
const TextResources = text_el.TextResources;

pub const TextAreaState = text_input_mod.TextInputState;

// ---------------------------------------------------------------------------
// Element
// ---------------------------------------------------------------------------

pub const Props = struct {
    id: []const u8,
    /// Direct or frame-local referenced accessible name.
    a11y_name: a11y_mod.NameSource = .none,
    disabled: bool = false,
    placeholder: []const u8 = "",
    font_size: Pixels = 14,
    text_color: Rgba = Rgba.black,
    placeholder_color: Rgba = Rgba.fromHex(0x888888),
    selection_color: Rgba = Rgba.fromHex(0x336699).withAlpha(0.4),
    caret_color: Rgba = Rgba.black,
    background: Rgba = Rgba.white,
    border_color: ?Rgba = null,
    width: Pixels = 200,
    height: Pixels = 96,
    padding: Pixels = 8,
};

pub fn textArea(
    arena: std.mem.Allocator,
    resources: *TextResources,
    input: *element.InputState,
    app: *app_mod.App,
    state: app_mod.Entity(TextAreaState),
    props: Props,
) *TextArea {
    const t = arena.create(TextArea) catch @panic("frame arena OOM");
    t.* = .{
        .arena = arena,
        .resources = resources,
        .input = input,
        .app = app,
        .state = state,
        .props = props,
        .element_id = element.elementId(props.id),
        .focus_id = element.elementId(props.id),
    };
    return t;
}

pub const TextArea = struct {
    arena: std.mem.Allocator,
    resources: *TextResources,
    input: *element.InputState,
    app: *app_mod.App,
    state: app_mod.Entity(TextAreaState),
    props: Props,
    element_id: element.ElementId,
    focus_id: element.FocusId,

    node: ?*layout.Node = null,
    bounds: Bounds(Pixels) = .{},

    const vtable = Element.VTable{
        .request_layout = requestLayoutErased,
        .prepaint = prepaintErased,
        .paint = paintErased,
    };

    pub fn any(self: *TextArea) Element {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn requestLayoutErased(ptr: *anyopaque, pass: *element.LayoutPass) anyerror!*layout.Node {
        const self: *TextArea = @ptrCast(@alignCast(ptr));
        const node = try pass.arena.create(layout.Node);
        node.* = pass.engine.newNode();
        self.node = node;
        node.setWidth(.{ .points = self.props.width });
        node.setHeight(.{ .points = self.props.height });
        return node;
    }

    fn prepaintErased(ptr: *anyopaque, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
        const self: *TextArea = @ptrCast(@alignCast(ptr));
        const node = self.node orelse return error.LayoutNotRequested;
        const relative = node.layoutBounds();
        self.bounds = .{
            .origin = parent_origin.add(relative.origin),
            .size = relative.size,
        };

        if (!self.props.disabled) {
            const editor = self.arena.create(Editor) catch @panic("frame arena OOM");
            editor.* = .{
                .app = self.app,
                .state = self.state,
                .disabled = self.props.disabled,
            };

            const focus_click = self.arena.create(FocusClick) catch @panic("frame arena OOM");
            focus_click.* = .{
                .input = self.input,
                .focus_id = self.focus_id,
            };

            try pass.frame.addHitbox(.{
                .id = self.element_id,
                .bounds = self.bounds,
                .on_mouse_down = .{ .ctx = focus_click, .func = FocusClick.onMouseDown },
            });
            try pass.frame.addFocusable(.{
                .id = self.focus_id,
                .on_key = .{ .ctx = editor, .func = Editor.onKey },
                .on_text_input = .{ .ctx = editor, .func = Editor.onTextInput },
                .on_composition = .{ .ctx = editor, .func = Editor.onComposition },
            });
        } else {
            try pass.frame.addHitbox(.{
                .id = self.element_id,
                .bounds = self.bounds,
            });
        }

        const input_state = self.app.read(TextAreaState, self.state);
        const sel = input_state.selectionRange();
        try pass.frame.registerA11y(.{
            .id = self.element_id,
            .role = .textarea,
            .name = self.props.a11y_name,
            .value_text = input_state.text(),
            .disabled = self.props.disabled,
            .caret = input_state.caret,
            .selection_start = if (sel) |r| r.start else null,
            .selection_end = if (sel) |r| r.end else null,
            .parent_id = pass.a11y_parent,
            .bounds = self.bounds,
        });
    }

    fn paintErased(ptr: *anyopaque, pass: *element.PaintPass) anyerror!void {
        const self: *TextArea = @ptrCast(@alignCast(ptr));
        return self.paint(pass);
    }

    fn paint(self: *TextArea, pass: *element.PaintPass) !void {
        const clip_f = pass.clipF();
        const bounds_f = scene_mod.BoundsF.from(self.bounds);

        const border = self.props.border_color orelse Rgba.transparent;
        try pass.scene.insertQuad(.{
            .bounds = bounds_f,
            .clip_bounds = clip_f,
            .background = scene_mod.ColorF.from(self.props.background),
            .border_color = scene_mod.ColorF.from(border),
            .border_widths = if (self.props.border_color != null)
                scene_mod.EdgesF.from(geometry.Edges(Pixels).all(1))
            else
                .{},
        });

        const st = self.app.read(TextAreaState, self.state);
        const focused = self.input.isFocused(self.focus_id);
        const show_placeholder = st.buffer.items.len == 0 and !focused and self.props.placeholder.len > 0;
        const display_text: []const u8 = if (show_placeholder)
            self.props.placeholder
        else
            st.buffer.items;

        const text_origin = Point(Pixels){
            .x = self.bounds.origin.x + self.props.padding,
            .y = self.bounds.origin.y + self.props.padding,
        };

        const text_color = if (show_placeholder) self.props.placeholder_color else self.props.text_color;
        const lines = lineCount(display_text);
        var pen_y = text_origin.y;
        var caret_y: ?Pixels = null;
        var caret_x: Pixels = 0;
        var caret_h: Pixels = self.props.font_size;

        var line_idx: usize = 0;
        while (line_idx < lines) : (line_idx += 1) {
            const line_start = text_input_mod.lineStart(display_text, line_idx);
            const line_end = text_input_mod.lineEnd(display_text, line_idx);
            const line_text = display_text[line_start..line_end];

            const line = try text_mod.shape(
                self.resources.font_system,
                self.resources.default_font,
                self.props.font_size,
                line_text,
                self.arena,
            );
            caret_h = line.ascent + line.descent;

            if (!show_placeholder) {
                if (st.selectionRange()) |range| {
                    const sel_start = @max(range.start, line_start);
                    const sel_end = @min(range.end, line_end);
                    if (sel_start < sel_end) {
                        const sel_start_x = xAtByteOffset(line, sel_start - line_start);
                        const sel_end_x = xAtByteOffset(line, sel_end - line_start);
                        if (sel_end_x > sel_start_x) {
                            try pass.scene.insertQuad(.{
                                .bounds = .{
                                    .origin_x = text_origin.x + sel_start_x,
                                    .origin_y = pen_y,
                                    .size_w = sel_end_x - sel_start_x,
                                    .size_h = line.ascent + line.descent,
                                },
                                .clip_bounds = clip_f,
                                .background = scene_mod.ColorF.from(self.props.selection_color),
                            });
                        }
                    }
                }
            }

            try paintGlyphs(self, pass, line, .{
                .x = text_origin.x,
                .y = pen_y,
            }, text_color, clip_f);

            if (focused and !show_placeholder) {
                const pos = text_input_mod.lineColAtOffset(st.buffer.items, st.caret);
                if (pos.line == line_idx) {
                    caret_y = pen_y;
                    caret_x = xAtByteOffset(line, st.caret - line_start);
                }
            }

            pen_y += line.ascent + line.descent;
        }

        if (focused and !show_placeholder and caret_y != null) {
            try pass.scene.insertQuad(.{
                .bounds = .{
                    .origin_x = text_origin.x + caret_x,
                    .origin_y = caret_y.?,
                    .size_w = 1,
                    .size_h = caret_h,
                },
                .clip_bounds = clip_f,
                .background = scene_mod.ColorF.from(self.props.caret_color),
            });
        }
    }

    fn paintGlyphs(
        self: *TextArea,
        pass: *element.PaintPass,
        line: text_mod.ShapedLine,
        origin: Point(Pixels),
        text_color: Rgba,
        clip_f: scene_mod.BoundsF,
    ) !void {
        const color_f = scene_mod.ColorF.from(text_color);
        const baseline_y = origin.y + line.ascent;
        var pen_x = origin.x;

        for (line.glyphs) |glyph| {
            const key = text_mod.GlyphKey{
                .font = glyph.font,
                .glyph_id = glyph.glyph_id,
                .size_px_q = text_mod.quantizeSize(self.props.font_size),
            };

            const atlas_glyph = self.resources.atlas.cache.get(key) orelse blk: {
                var bitmap = text_mod.rasterizeGlyphFont(
                    self.resources.font_system,
                    glyph.font,
                    self.props.font_size,
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
    }
};

fn lineCount(text: []const u8) usize {
    return text_input_mod.lineCount(text);
}

fn xAtByteOffset(line: text_mod.ShapedLine, byte_offset: usize) Pixels {
    var x: Pixels = 0;
    for (line.glyphs) |glyph| {
        if (glyph.cluster >= byte_offset) break;
        x += glyph.advance;
    }
    return x;
}

const Editor = struct {
    app: *app_mod.App,
    state: app_mod.Entity(TextAreaState),
    disabled: bool,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *Editor = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return false;
        const st = self.app.read(TextAreaState, self.state);

        switch (event.key) {
            .backspace => {
                st.deleteBackward() catch return false;
                self.app.notify(self.state.id);
                return true;
            },
            .delete => {
                st.deleteForward() catch return false;
                self.app.notify(self.state.id);
                return true;
            },
            .left => {
                st.moveCaretLeft(event.modifiers.shift);
                self.app.notify(self.state.id);
                return true;
            },
            .right => {
                st.moveCaretRight(event.modifiers.shift);
                self.app.notify(self.state.id);
                return true;
            },
            .up => {
                st.moveCaretUp(event.modifiers.shift);
                self.app.notify(self.state.id);
                return true;
            },
            .down => {
                st.moveCaretDown(event.modifiers.shift);
                self.app.notify(self.state.id);
                return true;
            },
            .enter => {
                st.insertText("\n") catch return false;
                self.app.notify(self.state.id);
                return true;
            },
            .home => {
                st.moveCaretLineHome(event.modifiers.shift);
                self.app.notify(self.state.id);
                return true;
            },
            .end => {
                st.moveCaretLineEnd(event.modifiers.shift);
                self.app.notify(self.state.id);
                return true;
            },
            else => return false,
        }
    }

    fn onTextInput(ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool {
        const self: *Editor = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return false;
        if (event.text.len == 0) return false;
        const st = self.app.read(TextAreaState, self.state);
        st.compositionEnd();
        st.insertText(event.text) catch return false;
        self.app.notify(self.state.id);
        return true;
    }

    fn onComposition(ctx: ?*anyopaque, event: element.CompositionHandler.CompositionDispatchEvent) bool {
        const self: *Editor = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return false;
        const st = self.app.read(TextAreaState, self.state);
        switch (event) {
            .start => st.compositionStart(),
            .update => |update| st.compositionUpdate(update.text, update.cursor) catch return false,
            .end => st.compositionEnd(),
        }
        self.app.notify(self.state.id);
        return true;
    }
};

const FocusClick = struct {
    input: *element.InputState,
    focus_id: element.FocusId,

    fn onMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *FocusClick = @ptrCast(@alignCast(ctx.?));
        self.input.focus(self.focus_id);
    }
};

// ---------------------------------------------------------------------------
// Unit tests (multiline state logic)
// ---------------------------------------------------------------------------

test "TextAreaState enter inserts newline and up/down move by line" {
    const allocator = std.testing.allocator;
    var state = try TextAreaState.initWithText(allocator, "ab\ncd");
    defer state.deinit();

    state.caret = state.text().len;
    try state.insertText("\n");
    try std.testing.expectEqualStrings("ab\ncd\n", state.text());

    state.caret = text_input_mod.offsetAtLineCol(state.text(), 1, 1);
    state.moveCaretUp(false);
    try std.testing.expectEqual(
        text_input_mod.offsetAtLineCol(state.text(), 0, 1),
        state.caret,
    );

    state.moveCaretDown(false);
    try std.testing.expectEqual(
        text_input_mod.offsetAtLineCol(state.text(), 1, 1),
        state.caret,
    );
}

test "TextAreaState backspace merges lines" {
    const allocator = std.testing.allocator;
    var state = try TextAreaState.initWithText(allocator, "ab\ncd");
    defer state.deinit();

    state.caret = text_input_mod.lineStart(state.text(), 1);
    try state.deleteBackward();
    try std.testing.expectEqualStrings("abcd", state.text());
    try std.testing.expectEqual(@as(usize, 2), state.caret);
}

test "TextAreaState home and end move within line" {
    const allocator = std.testing.allocator;
    var state = try TextAreaState.initWithText(allocator, "hello\nworld");
    defer state.deinit();

    state.caret = text_input_mod.offsetAtLineCol(state.text(), 1, 3);
    state.moveCaretLineHome(false);
    try std.testing.expectEqual(text_input_mod.lineStart(state.text(), 1), state.caret);

    state.moveCaretLineEnd(false);
    try std.testing.expectEqual(text_input_mod.lineEnd(state.text(), 1), state.caret);
}
