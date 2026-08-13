//! Headless single-line text input: editable buffer with caret/selection,
//! keyboard and `text_input` event handling, and simple caret/selection
//! painting via scene quads + shaped glyphs.

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
const text_mod = @import("../text/text.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Rgba = color.Rgba;
const Element = element.Element;
const TextResources = text_el.TextResources;

// ---------------------------------------------------------------------------
// Persistent editing state (owned by App entity, not frame arena)
// ---------------------------------------------------------------------------

const MAX_UNDO = 64;

const UndoSnapshot = struct {
    text: []u8,
    caret: usize,
    selection_anchor: ?usize,
};

pub const TextInputState = struct {
    gpa: std.mem.Allocator = undefined,
    buffer: std.ArrayList(u8) = .empty,
    /// Byte offset of the caret in `buffer`.
    caret: usize = 0,
    /// When set, the selection spans `[min(anchor, caret), max(anchor, caret))`.
    selection_anchor: ?usize = null,
    /// IME preedit (marked text), not yet committed to `buffer`.
    preedit: std.ArrayList(u8) = .empty,
    /// Caret within `preedit`, byte offset, or -1 when unknown.
    preedit_cursor: i32 = -1,
    composing: bool = false,
    undo_stack: std.ArrayList(UndoSnapshot) = .empty,
    redo_stack: std.ArrayList(UndoSnapshot) = .empty,
    /// Last prepainted field bounds; used for regional redraw on edits.
    last_bounds: Bounds(Pixels) = .{},

    pub fn init(gpa: std.mem.Allocator) TextInputState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TextInputState) void {
        self.clearUndoHistory();
        self.buffer.deinit(self.gpa);
        self.preedit.deinit(self.gpa);
    }

    fn clearUndoHistory(self: *TextInputState) void {
        for (self.undo_stack.items) |snap| self.gpa.free(snap.text);
        self.undo_stack.deinit(self.gpa);
        for (self.redo_stack.items) |snap| self.gpa.free(snap.text);
        self.redo_stack.deinit(self.gpa);
    }

    fn pushSnapshot(self: *TextInputState, stack: *std.ArrayList(UndoSnapshot)) !void {
        const snapshot_text = try self.gpa.dupe(u8, self.buffer.items);
        try stack.append(self.gpa, .{
            .text = snapshot_text,
            .caret = self.caret,
            .selection_anchor = self.selection_anchor,
        });
    }

    fn applySnapshot(self: *TextInputState, snap: UndoSnapshot) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.gpa, snap.text);
        self.gpa.free(snap.text);
        self.caret = snap.caret;
        self.selection_anchor = snap.selection_anchor;
    }

    /// Record the current buffer state before a mutating edit. Skips when
    /// identical to the top undo entry. Clears the redo stack.
    pub fn recordUndo(self: *TextInputState) !void {
        if (self.undo_stack.items.len > 0) {
            const top = self.undo_stack.items[self.undo_stack.items.len - 1];
            if (top.caret == self.caret and
                top.selection_anchor == self.selection_anchor and
                std.mem.eql(u8, top.text, self.buffer.items))
            {
                return;
            }
        }

        try self.pushSnapshot(&self.undo_stack);
        if (self.undo_stack.items.len > MAX_UNDO) {
            const removed = self.undo_stack.orderedRemove(0);
            self.gpa.free(removed.text);
        }

        for (self.redo_stack.items) |snap| self.gpa.free(snap.text);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *TextInputState) !bool {
        if (self.undo_stack.items.len == 0) return false;
        try self.pushSnapshot(&self.redo_stack);
        const snap = self.undo_stack.pop() orelse return false;
        try self.applySnapshot(snap);
        return true;
    }

    pub fn redo(self: *TextInputState) !bool {
        if (self.redo_stack.items.len == 0) return false;
        try self.pushSnapshot(&self.undo_stack);
        const snap = self.redo_stack.pop() orelse return false;
        try self.applySnapshot(snap);
        return true;
    }

    pub fn initWithText(gpa: std.mem.Allocator, initial: []const u8) !TextInputState {
        var state = init(gpa);
        try state.buffer.appendSlice(gpa, initial);
        state.caret = initial.len;
        return state;
    }

    pub fn text(self: *const TextInputState) []const u8 {
        return self.buffer.items;
    }

    pub fn preeditText(self: *const TextInputState) []const u8 {
        return self.preedit.items;
    }

    pub fn isComposing(self: *const TextInputState) bool {
        return self.composing;
    }

    pub fn compositionStart(self: *TextInputState) void {
        self.composing = true;
    }

    pub fn compositionUpdate(self: *TextInputState, preedit_text: []const u8, cursor: i32) !void {
        self.composing = true;
        self.preedit.clearRetainingCapacity();
        try self.preedit.appendSlice(self.gpa, preedit_text);
        self.preedit_cursor = cursor;
    }

    pub fn compositionEnd(self: *TextInputState) void {
        self.composing = false;
        self.preedit.clearRetainingCapacity();
        self.preedit_cursor = -1;
    }

    pub fn selectionRange(self: *const TextInputState) ?struct { start: usize, end: usize } {
        const anchor = self.selection_anchor orelse return null;
        const start = @min(anchor, self.caret);
        const end = @max(anchor, self.caret);
        if (start == end) return null;
        return .{ .start = start, .end = end };
    }

    pub fn clearSelection(self: *TextInputState) void {
        self.selection_anchor = null;
    }

    pub fn selectAll(self: *TextInputState) void {
        self.selection_anchor = 0;
        self.caret = self.buffer.items.len;
    }

    /// Set the UTF-8 selection to `[start, end)` (collapsed clears the selection).
    /// Invalid or non-codepoint-boundary ranges are rejected without mutation.
    pub fn setSelectionRange(self: *TextInputState, start: usize, end: usize) bool {
        const buffer_text = self.buffer.items;
        if (start > end or end > buffer_text.len) return false;
        if (!isByteBoundary(buffer_text, start) or !isByteBoundary(buffer_text, end)) return false;

        self.compositionEnd();
        if (start == end) {
            self.caret = start;
            self.selection_anchor = null;
        } else {
            self.selection_anchor = start;
            self.caret = end;
        }
        return true;
    }

    /// Copy the active selection to `clipboard`. Returns false when empty.
    pub fn copySelection(self: *const TextInputState, app: *app_mod.App) !bool {
        const range = self.selectionRange() orelse return false;
        try app.setClipboardText(self.buffer.items[range.start..range.end]);
        return true;
    }

    /// Cut the active selection into `clipboard`. Returns false when empty.
    pub fn cutSelection(self: *TextInputState, app: *app_mod.App) !bool {
        if (self.selectionRange() == null) return false;
        try self.recordUndo();
        _ = try self.copySelection(app);
        _ = try self.deleteSelection();
        return true;
    }

    /// Paste `text` at the caret, replacing any active selection.
    pub fn pasteText(self: *TextInputState, slice: []const u8) !void {
        if (slice.len == 0) return;
        try self.recordUndo();
        _ = try self.deleteSelection();
        try self.buffer.insertSlice(self.gpa, self.caret, slice);
        self.caret += slice.len;
    }

    /// Delete the active selection if any. Returns true when text was removed.
    pub fn deleteSelection(self: *TextInputState) !bool {
        if (self.selectionRange()) |range| {
            try self.buffer.replaceRange(self.gpa, range.start, range.end - range.start, &.{});
            self.caret = range.start;
            self.selection_anchor = null;
            return true;
        }
        return false;
    }

    pub fn insertText(self: *TextInputState, slice: []const u8) !void {
        if (slice.len == 0) return;
        try self.recordUndo();
        _ = try self.deleteSelection();
        try self.buffer.insertSlice(self.gpa, self.caret, slice);
        self.caret += slice.len;
    }

    pub fn deleteBackward(self: *TextInputState) !void {
        if (self.selectionRange() != null) {
            try self.recordUndo();
            _ = try self.deleteSelection();
            return;
        }
        if (self.caret == 0) return;
        try self.recordUndo();
        const prev = prevCodepointBoundary(self.buffer.items, self.caret);
        try self.buffer.replaceRange(self.gpa, prev, self.caret - prev, &.{});
        self.caret = prev;
    }

    pub fn deleteForward(self: *TextInputState) !void {
        if (self.selectionRange() != null) {
            try self.recordUndo();
            _ = try self.deleteSelection();
            return;
        }
        if (self.caret >= self.buffer.items.len) return;
        try self.recordUndo();
        const next = nextCodepointBoundary(self.buffer.items, self.caret);
        try self.buffer.replaceRange(self.gpa, self.caret, next - self.caret, &.{});
    }

    pub fn moveCaretLeft(self: *TextInputState, extend_selection: bool) void {
        if (self.caret == 0) return;
        const prev = prevCodepointBoundary(self.buffer.items, self.caret);
        if (extend_selection) {
            if (self.selection_anchor == null) self.selection_anchor = self.caret;
        } else {
            self.clearSelection();
        }
        self.caret = prev;
    }

    pub fn moveCaretRight(self: *TextInputState, extend_selection: bool) void {
        if (self.caret >= self.buffer.items.len) return;
        const next = nextCodepointBoundary(self.buffer.items, self.caret);
        if (extend_selection) {
            if (self.selection_anchor == null) self.selection_anchor = self.caret;
        } else {
            self.clearSelection();
        }
        self.caret = next;
    }

    /// Move to the same column on the previous line (byte lines split on `\n`).
    pub fn moveCaretUp(self: *TextInputState, extend_selection: bool) void {
        const buf = self.buffer.items;
        const pos = lineColAtOffset(buf, self.caret);
        if (pos.line == 0) return;
        const new_caret = offsetAtLineCol(buf, pos.line - 1, pos.col);
        if (extend_selection) {
            if (self.selection_anchor == null) self.selection_anchor = self.caret;
        } else {
            self.clearSelection();
        }
        self.caret = new_caret;
    }

    /// Move to the same column on the next line (byte lines split on `\n`).
    pub fn moveCaretDown(self: *TextInputState, extend_selection: bool) void {
        const buf = self.buffer.items;
        const pos = lineColAtOffset(buf, self.caret);
        if (pos.line + 1 >= lineCount(buf)) return;
        const new_caret = offsetAtLineCol(buf, pos.line + 1, pos.col);
        if (extend_selection) {
            if (self.selection_anchor == null) self.selection_anchor = self.caret;
        } else {
            self.clearSelection();
        }
        self.caret = new_caret;
    }

    /// Move to the start of the current line.
    pub fn moveCaretLineHome(self: *TextInputState, extend_selection: bool) void {
        const pos = lineColAtOffset(self.buffer.items, self.caret);
        const new_caret = lineStart(self.buffer.items, pos.line);
        if (new_caret == self.caret) return;
        if (extend_selection) {
            if (self.selection_anchor == null) self.selection_anchor = self.caret;
        } else {
            self.clearSelection();
        }
        self.caret = new_caret;
    }

    /// Move to the end of the current line (before `\n`, or EOF).
    pub fn moveCaretLineEnd(self: *TextInputState, extend_selection: bool) void {
        const pos = lineColAtOffset(self.buffer.items, self.caret);
        const new_caret = lineEnd(self.buffer.items, pos.line);
        if (new_caret == self.caret) return;
        if (extend_selection) {
            if (self.selection_anchor == null) self.selection_anchor = self.caret;
        } else {
            self.clearSelection();
        }
        self.caret = new_caret;
    }
};

pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

pub fn lineStart(text: []const u8, line_index: usize) usize {
    var line: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (line == line_index) return i;
        if (text[i] == '\n') line += 1;
        i += 1;
    }
    if (line == line_index) return text.len;
    return text.len;
}

pub fn lineEnd(text: []const u8, line_index: usize) usize {
    const start = lineStart(text, line_index);
    if (start >= text.len) return text.len;
    const rel = std.mem.indexOfScalar(u8, text[start..], '\n');
    return if (rel) |r| start + r else text.len;
}

pub fn lineColAtOffset(text: []const u8, offset: usize) struct { line: usize, col: usize } {
    var line: usize = 0;
    var line_start: usize = 0;
    const off = @min(offset, text.len);
    var i: usize = 0;
    while (i < off) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = off - line_start };
}

pub fn offsetAtLineCol(text: []const u8, line: usize, col: usize) usize {
    const start = lineStart(text, line);
    const end = lineEnd(text, line);
    return start + @min(col, end - start);
}

fn prevCodepointBoundary(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var i = offset - 1;
    while (i > 0 and (text[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

fn nextCodepointBoundary(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    var i = offset + 1;
    while (i < text.len and (text[i] & 0xc0) == 0x80) i += 1;
    return i;
}

fn isByteBoundary(text: []const u8, offset: usize) bool {
    return offset <= text.len and
        (offset == 0 or offset == text.len or (text[offset] & 0xc0) != 0x80);
}

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
    preedit_color: Rgba = Rgba.fromHex(0x2255aa),
    background: Rgba = Rgba.white,
    border_color: ?Rgba = null,
    width: Pixels = 200,
    height: Pixels = 32,
    padding: Pixels = 8,
};

pub fn textInput(
    arena: std.mem.Allocator,
    resources: *TextResources,
    input: *element.InputState,
    app: *app_mod.App,
    state: app_mod.Entity(TextInputState),
    props: Props,
) *TextInput {
    const t = arena.create(TextInput) catch @panic("frame arena OOM");
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

pub const TextInput = struct {
    arena: std.mem.Allocator,
    resources: *TextResources,
    input: *element.InputState,
    app: *app_mod.App,
    state: app_mod.Entity(TextInputState),
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

    pub fn any(self: *TextInput) Element {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn requestLayoutErased(ptr: *anyopaque, pass: *element.LayoutPass) anyerror!*layout.Node {
        const self: *TextInput = @ptrCast(@alignCast(ptr));
        const node = try pass.arena.create(layout.Node);
        node.* = pass.engine.newNode();
        self.node = node;
        node.setWidth(.{ .points = self.props.width });
        node.setHeight(.{ .points = self.props.height });
        return node;
    }

    fn prepaintErased(ptr: *anyopaque, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
        const self: *TextInput = @ptrCast(@alignCast(ptr));
        const node = self.node orelse return error.LayoutNotRequested;
        const relative = node.layoutBounds();
        self.bounds = .{
            .origin = parent_origin.add(relative.origin),
            .size = relative.size,
        };
        self.app.read(TextInputState, self.state).last_bounds = self.bounds;

        if (!self.props.disabled) {
            const editor = pass.scratch.create(Editor) catch @panic("frame arena OOM");
            editor.* = .{
                .app = self.app,
                .state = self.state,
                .disabled = self.props.disabled,
            };

            const focus_click = pass.scratch.create(FocusClick) catch @panic("frame arena OOM");
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
                .on_a11y_set_selection = .{ .ctx = editor, .func = Editor.onA11ySetSelection },
            });
        } else {
            try pass.frame.addHitbox(.{
                .id = self.element_id,
                .bounds = self.bounds,
            });
        }

        const input_state = self.app.read(TextInputState, self.state);
        const sel = input_state.selectionRange();
        try pass.frame.registerA11y(.{
            .id = self.element_id,
            .role = .textbox,
            .name = self.props.a11y_name,
            .value_text = input_state.text(),
            .disabled = self.props.disabled,
            .editable = !self.props.disabled,
            .caret = input_state.caret,
            .selection_start = if (sel) |r| r.start else null,
            .selection_end = if (sel) |r| r.end else null,
            .parent_id = pass.a11y_parent,
            .bounds = self.bounds,
        });
    }

    fn paintErased(ptr: *anyopaque, pass: *element.PaintPass) anyerror!void {
        const self: *TextInput = @ptrCast(@alignCast(ptr));
        return self.paint(pass);
    }

    fn paint(self: *TextInput, pass: *element.PaintPass) !void {
        if (!pass.shouldPaint(self.bounds)) return;
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

        const st = self.app.read(TextInputState, self.state);
        const focused = self.input.isFocused(self.focus_id);
        const has_preedit = st.preedit.items.len > 0;
        const show_placeholder = st.buffer.items.len == 0 and !focused and !has_preedit and self.props.placeholder.len > 0;

        const text_origin = Point(Pixels){
            .x = self.bounds.origin.x + self.props.padding,
            .y = self.bounds.origin.y + self.props.padding,
        };

        if (show_placeholder) {
            const shaped = try text_mod.shape(
                self.resources.font_system,
                self.resources.default_font,
                self.props.font_size,
                self.props.placeholder,
                pass.scratch,
            );
            try paintGlyphs(self, pass, shaped, text_origin, self.props.placeholder_color, clip_f);
            return;
        }

        const before = st.buffer.items[0..st.caret];
        const after = st.buffer.items[st.caret..];
        var pen_x = text_origin.x;
        var line_height: Pixels = self.props.font_size;
        var preedit_width: Pixels = 0;

        if (before.len > 0) {
            const shaped_before = try text_mod.shape(
                self.resources.font_system,
                self.resources.default_font,
                self.props.font_size,
                before,
                pass.scratch,
            );
            line_height = shaped_before.ascent + shaped_before.descent;

            if (st.selectionRange()) |range| {
                const sel_start = @min(range.start, st.caret);
                const sel_end = @min(range.end, st.caret);
                if (sel_end > sel_start) {
                    const sel_start_x = xAtByteOffset(shaped_before, sel_start);
                    const sel_end_x = xAtByteOffset(shaped_before, sel_end);
                    if (sel_end_x > sel_start_x) {
                        try pass.scene.insertQuad(.{
                            .bounds = .{
                                .origin_x = text_origin.x + sel_start_x,
                                .origin_y = text_origin.y,
                                .size_w = sel_end_x - sel_start_x,
                                .size_h = line_height,
                            },
                            .clip_bounds = clip_f,
                            .background = scene_mod.ColorF.from(self.props.selection_color),
                        });
                    }
                }
            }

            try paintGlyphs(self, pass, shaped_before, text_origin, self.props.text_color, clip_f);
            pen_x += xAtByteOffset(shaped_before, before.len);
        }

        if (has_preedit) {
            const shaped_preedit = try text_mod.shape(
                self.resources.font_system,
                self.resources.default_font,
                self.props.font_size,
                st.preedit.items,
                pass.scratch,
            );
            line_height = @max(line_height, shaped_preedit.ascent + shaped_preedit.descent);
            preedit_width = xAtByteOffset(shaped_preedit, st.preedit.items.len);

            const preedit_origin = Point(Pixels){ .x = pen_x, .y = text_origin.y };
            try paintGlyphs(self, pass, shaped_preedit, preedit_origin, self.props.preedit_color, clip_f);
            try pass.scene.insertQuad(.{
                .bounds = .{
                    .origin_x = pen_x,
                    .origin_y = text_origin.y + shaped_preedit.ascent + 1,
                    .size_w = preedit_width,
                    .size_h = 1,
                },
                .clip_bounds = clip_f,
                .background = scene_mod.ColorF.from(self.props.preedit_color),
            });
        }

        if (after.len > 0) {
            const shaped_after = try text_mod.shape(
                self.resources.font_system,
                self.resources.default_font,
                self.props.font_size,
                after,
                pass.scratch,
            );
            line_height = @max(line_height, shaped_after.ascent + shaped_after.descent);

            if (st.selectionRange()) |range| {
                const sel_start = if (range.start > st.caret) range.start - st.caret else 0;
                const sel_end = if (range.end > st.caret) range.end - st.caret else 0;
                if (sel_end > sel_start) {
                    const sel_start_x = xAtByteOffset(shaped_after, sel_start);
                    const sel_end_x = xAtByteOffset(shaped_after, sel_end);
                    if (sel_end_x > sel_start_x) {
                        try pass.scene.insertQuad(.{
                            .bounds = .{
                                .origin_x = pen_x + sel_start_x,
                                .origin_y = text_origin.y,
                                .size_w = sel_end_x - sel_start_x,
                                .size_h = shaped_after.ascent + shaped_after.descent,
                            },
                            .clip_bounds = clip_f,
                            .background = scene_mod.ColorF.from(self.props.selection_color),
                        });
                    }
                }
            }

            const after_origin = Point(Pixels){ .x = pen_x, .y = text_origin.y };
            try paintGlyphs(self, pass, shaped_after, after_origin, self.props.text_color, clip_f);
        }

        if (focused) {
            const caret_x = if (has_preedit) blk: {
                const cursor: usize = if (st.preedit_cursor >= 0)
                    @min(@as(usize, @intCast(st.preedit_cursor)), st.preedit.items.len)
                else
                    st.preedit.items.len;
                if (cursor == 0) break :blk pen_x;
                const shaped_cursor = try text_mod.shape(
                    self.resources.font_system,
                    self.resources.default_font,
                    self.props.font_size,
                    st.preedit.items[0..cursor],
                    pass.scratch,
                );
                break :blk pen_x + xAtByteOffset(shaped_cursor, cursor);
            } else if (before.len > 0) blk: {
                const shaped_before = try text_mod.shape(
                    self.resources.font_system,
                    self.resources.default_font,
                    self.props.font_size,
                    before,
                    pass.scratch,
                );
                break :blk text_origin.x + xAtByteOffset(shaped_before, st.caret);
            } else text_origin.x;

            try pass.scene.insertQuad(.{
                .bounds = .{
                    .origin_x = caret_x,
                    .origin_y = text_origin.y,
                    .size_w = 1,
                    .size_h = line_height,
                },
                .clip_bounds = clip_f,
                .background = scene_mod.ColorF.from(self.props.caret_color),
            });

            if (pass.ime_position) |out| {
                out.* = .{ .x = caret_x, .y = text_origin.y + line_height };
            }
        }
    }

    fn paintGlyphs(
        self: *TextInput,
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
                    pass.scratch,
                ) catch break :blk null;
                defer bitmap.deinit(pass.scratch);
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

fn xAtByteOffset(line: text_mod.ShapedLine, byte_offset: usize) Pixels {
    var x: Pixels = 0;
    for (line.glyphs) |glyph| {
        if (glyph.cluster >= byte_offset) break;
        x += glyph.advance;
    }
    return x;
}

/// Notify observers and request a regional redraw of the field's last bounds.
pub fn notifyTextEdit(app: *app_mod.App, state: app_mod.Entity(TextInputState)) void {
    const st = app.read(TextInputState, state);
    app.notifyBounds(state.id, st.last_bounds);
}

const Editor = struct {
    app: *app_mod.App,
    state: app_mod.Entity(TextInputState),
    disabled: bool,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *Editor = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return false;
        const st = self.app.read(TextInputState, self.state);

        const cmd_or_ctrl = event.modifiers.command or event.modifiers.control;
        if (cmd_or_ctrl) {
            switch (event.key) {
                .c => {
                    _ = st.copySelection(self.app) catch return false;
                    return true;
                },
                .x => {
                    _ = st.cutSelection(self.app) catch return false;
                    notifyTextEdit(self.app, self.state);
                    return true;
                },
                .v => {
                    const text = self.app.clipboardTextForPaste();
                    if (text.len == 0) return true;
                    st.pasteText(text) catch return false;
                    notifyTextEdit(self.app, self.state);
                    return true;
                },
                .a => {
                    st.selectAll();
                    notifyTextEdit(self.app, self.state);
                    return true;
                },
                .z => {
                    if (event.modifiers.shift) {
                        _ = st.redo() catch return false;
                    } else {
                        _ = st.undo() catch return false;
                    }
                    notifyTextEdit(self.app, self.state);
                    return true;
                },
                .y => {
                    _ = st.redo() catch return false;
                    notifyTextEdit(self.app, self.state);
                    return true;
                },
                else => {},
            }
        }

        switch (event.key) {
            .backspace => {
                st.deleteBackward() catch return false;
                notifyTextEdit(self.app, self.state);
                return true;
            },
            .delete => {
                st.deleteForward() catch return false;
                notifyTextEdit(self.app, self.state);
                return true;
            },
            .left => {
                st.moveCaretLeft(event.modifiers.shift);
                notifyTextEdit(self.app, self.state);
                return true;
            },
            .right => {
                st.moveCaretRight(event.modifiers.shift);
                notifyTextEdit(self.app, self.state);
                return true;
            },
            else => return false,
        }
    }

    fn onTextInput(ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool {
        const self: *Editor = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return false;
        if (event.text.len == 0) return false;
        const st = self.app.read(TextInputState, self.state);
        st.compositionEnd();
        st.insertText(event.text) catch return false;
        notifyTextEdit(self.app, self.state);
        return true;
    }

    fn onComposition(ctx: ?*anyopaque, event: element.CompositionHandler.CompositionDispatchEvent) bool {
        const self: *Editor = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return false;
        const st = self.app.read(TextInputState, self.state);
        switch (event) {
            .start => st.compositionStart(),
            .update => |update| st.compositionUpdate(update.text, update.cursor) catch return false,
            .end => st.compositionEnd(),
        }
        notifyTextEdit(self.app, self.state);
        return true;
    }

    fn onA11ySetSelection(ctx: ?*anyopaque, start: usize, end: usize) bool {
        const self: *Editor = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return false;
        const st = self.app.read(TextInputState, self.state);
        if (!st.setSelectionRange(start, end)) return false;
        notifyTextEdit(self.app, self.state);
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
// Unit tests (state logic)
// ---------------------------------------------------------------------------

test "TextInputState insert, backspace, caret move, selection replace" {
    const allocator = std.testing.allocator;
    var state = try TextInputState.initWithText(allocator, "hi");
    defer state.deinit();

    try state.insertText("!");
    try std.testing.expectEqualStrings("hi!", state.text());
    try std.testing.expectEqual(@as(usize, 3), state.caret);

    try state.deleteBackward();
    try std.testing.expectEqualStrings("hi", state.text());

    state.moveCaretLeft(false);
    try std.testing.expectEqual(@as(usize, 1), state.caret);

    state.moveCaretRight(true);
    try std.testing.expectEqual(@as(?usize, 1), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 2), state.caret);

    try state.insertText("X");
    try std.testing.expectEqualStrings("hX", state.text());
    try std.testing.expectEqual(@as(usize, 2), state.caret);
}

test "TextInputState selection range validates UTF-8 boundaries and ends composition" {
    const allocator = std.testing.allocator;
    var state = try TextInputState.initWithText(allocator, "a😀b");
    defer state.deinit();

    state.compositionStart();
    try state.compositionUpdate("x", 1);
    try std.testing.expect(state.setSelectionRange(1, 5));
    try std.testing.expect(!state.isComposing());
    try std.testing.expectEqual(@as(?usize, 1), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 5), state.caret);

    // Invalid ranges must leave the valid selection untouched.
    try std.testing.expect(!state.setSelectionRange(2, 5));
    try std.testing.expect(!state.setSelectionRange(5, 1));
    try std.testing.expect(!state.setSelectionRange(1, 7));
    try std.testing.expectEqual(@as(?usize, 1), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 5), state.caret);
}

test "TextInputState composition preedit does not commit until text_input" {
    const allocator = std.testing.allocator;
    var state = try TextInputState.initWithText(allocator, "ab");
    defer state.deinit();

    state.compositionStart();
    try state.compositionUpdate("ni", 2);
    try std.testing.expect(state.isComposing());
    try std.testing.expectEqualStrings("ab", state.text());
    try std.testing.expectEqualStrings("ni", state.preeditText());
    try std.testing.expectEqual(@as(i32, 2), state.preedit_cursor);

    try state.compositionUpdate("你", -1);
    try std.testing.expectEqualStrings("你", state.preeditText());
    try std.testing.expectEqualStrings("ab", state.text());

    state.compositionEnd();
    try std.testing.expect(!state.isComposing());
    try std.testing.expectEqual(@as(usize, 0), state.preeditText().len);

    try state.insertText("你");
    try std.testing.expectEqualStrings("ab你", state.text());
    try std.testing.expectEqual(@as(usize, 5), state.caret);
}

test "TextInputState copy cut paste selectAll" {
    const allocator = std.testing.allocator;
    var app = app_mod.App.init(allocator);
    defer app.deinit();

    var state = try TextInputState.initWithText(allocator, "hello");
    defer state.deinit();

    state.selection_anchor = 1;
    state.caret = 4;
    try std.testing.expect(try state.copySelection(&app));
    try std.testing.expectEqualStrings("ell", app.clipboard.getText());

    _ = try state.cutSelection(&app);
    try std.testing.expectEqualStrings("ho", state.text());
    try std.testing.expectEqualStrings("ell", app.clipboard.getText());

    try state.pasteText("X");
    try std.testing.expectEqualStrings("hXo", state.text());

    state.selectAll();
    try std.testing.expectEqual(@as(?usize, 0), state.selection_anchor);
    try std.testing.expectEqual(@as(usize, 3), state.caret);
}

test "TextInputState copy pushes through app clipboard bridge" {
    const Fake = struct {
        var last_push: ?[]const u8 = null;

        fn pull(ctx: ?*anyopaque, gpa: std.mem.Allocator) !?[]u8 {
            _ = ctx;
            _ = gpa;
            return null;
        }

        fn push(ctx: ?*anyopaque, text: []const u8) !void {
            _ = ctx;
            last_push = text;
        }
    };

    const allocator = std.testing.allocator;
    var app = app_mod.App.init(allocator);
    defer app.deinit();
    app.clipboard_bridge = .{ .pull = Fake.pull, .push = Fake.push };

    var state = try TextInputState.initWithText(allocator, "hello");
    defer state.deinit();

    state.selection_anchor = 1;
    state.caret = 4;
    try std.testing.expect(try state.copySelection(&app));
    try std.testing.expectEqualStrings("ell", app.clipboard.getText());
    try std.testing.expectEqualStrings("ell", Fake.last_push.?);
}

test "TextInputState undo redo roundtrip" {
    const allocator = std.testing.allocator;
    var state = try TextInputState.initWithText(allocator, "ab");
    defer state.deinit();

    try state.insertText("c");
    try std.testing.expectEqualStrings("abc", state.text());

    try state.insertText("d");
    try std.testing.expectEqualStrings("abcd", state.text());

    try std.testing.expect(try state.undo());
    try std.testing.expectEqualStrings("abc", state.text());

    try std.testing.expect(try state.undo());
    try std.testing.expectEqualStrings("ab", state.text());

    try std.testing.expect(try state.redo());
    try std.testing.expectEqualStrings("abc", state.text());

    try state.insertText("!");
    try std.testing.expectEqualStrings("abc!", state.text());

    // New edit clears redo branch.
    try std.testing.expect(!try state.redo());
}

test "TextInputState undo coalesces identical consecutive snapshots" {
    const allocator = std.testing.allocator;
    var state = try TextInputState.initWithText(allocator, "x");
    defer state.deinit();

    try state.recordUndo();
    try state.recordUndo();
    try state.insertText("y");
    try std.testing.expectEqualStrings("xy", state.text());

    try std.testing.expect(try state.undo());
    try std.testing.expectEqualStrings("x", state.text());
    try std.testing.expect(!try state.undo());
}
