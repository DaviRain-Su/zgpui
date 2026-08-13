//! Headless code input: line map, caret point mapping, and LSP-ready diagnostics
//! decoration slots (gpui-component editor contracts without an LSP client).

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;
const Pixels = geometry.Pixels;
const Rgba = color.Rgba;
const a11y_mod = @import("../a11y.zig");

/// Zero-based line/column in UTF-8 byte offsets within the line.
pub const Point = struct {
    line: usize = 0,
    column: usize = 0,
};

pub const Severity = enum { error_, warning, information, hint };

/// LSP-shaped diagnostic range over byte offsets in the buffer.
pub const Diagnostic = struct {
    start: usize,
    end: usize,
    severity: Severity = .error_,
    message: []const u8 = "",
};

pub const Options = struct {
    language: []const u8 = "",
    line_number: bool = true,
    tab_size: u8 = 4,
    show_diagnostics: bool = true,
};

pub const State = struct {
    /// Owned buffer (caller manages via Entity or local storage).
    text: []const u8 = "",
    caret: usize = 0,
    selection_anchor: ?usize = null,
    options: Options = .{},
    /// Host-provided diagnostics (not owned; typically frame-local or Entity).
    diagnostics: []const Diagnostic = &.{},

    pub fn setText(self: *State, text: []const u8) void {
        self.text = text;
        self.caret = @min(self.caret, text.len);
        if (self.selection_anchor) |a| {
            self.selection_anchor = @min(a, text.len);
        }
    }

    pub fn setDiagnostics(self: *State, diagnostics: []const Diagnostic) void {
        self.diagnostics = diagnostics;
    }
};

/// Byte offsets of each line start, including 0 for the first line.
/// Allocates `line_count` entries; free with `allocator.free`.
pub fn lineStarts(allocator: std.mem.Allocator, text: []const u8) ![]usize {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(allocator);
    try starts.append(allocator, 0);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try starts.append(allocator, i + 1);
        }
    }
    return try starts.toOwnedSlice(allocator);
}

pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 1;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Convert a UTF-8 byte offset to a zero-based line/column point.
pub fn offsetToPoint(text: []const u8, offset: usize) Point {
    const off = @min(offset, text.len);
    var line: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    while (i < off) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

/// Convert a line/column point to a UTF-8 byte offset (clamped).
pub fn pointToOffset(text: []const u8, point: Point) usize {
    var line: usize = 0;
    var i: usize = 0;
    while (i < text.len and line < point.line) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    if (line < point.line) return text.len;
    const col_target = point.column;
    var col: usize = 0;
    while (i < text.len and col < col_target and text[i] != '\n') : (i += 1) {
        col += 1;
    }
    return i;
}

/// Slice for line `line` without the trailing newline.
pub fn lineSlice(text: []const u8, line: usize) []const u8 {
    const start = pointToOffset(text, .{ .line = line, .column = 0 });
    var end = start;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    return text[start..end];
}

/// Diagnostics overlapping the half-open range [start, end).
pub fn diagnosticsInRange(
    diagnostics: []const Diagnostic,
    start: usize,
    end: usize,
    out: []usize,
) usize {
    var n: usize = 0;
    for (diagnostics, 0..) |d, i| {
        if (d.end <= start or d.start >= end) continue;
        if (n < out.len) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

/// Highest-severity diagnostic overlapping a line (error > warning > …).
pub fn lineSeverity(text: []const u8, diagnostics: []const Diagnostic, line: usize) ?Severity {
    const start = pointToOffset(text, .{ .line = line, .column = 0 });
    var end = start;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    if (end < text.len) end += 1; // include newline so EOL diagnostics stick

    var best: ?Severity = null;
    for (diagnostics) |d| {
        if (d.end <= start or d.start >= end) continue;
        if (best == null or @intFromEnum(d.severity) < @intFromEnum(best.?)) {
            best = d.severity;
        }
    }
    return best;
}

pub const GutterStyleFn = *const fn (line: usize, severity: ?Severity) style_mod.Style;
pub const RowStyleFn = *const fn (line: usize, severity: ?Severity) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    state: *const State,
    row_height: Pixels = 20,
    gutter_width: Pixels = 40,
    gutter_style_fn: ?GutterStyleFn = null,
    row_style_fn: ?RowStyleFn = null,
    /// Accessible name for the editor shell (defaults to "Code").
    a11y_name: ?[]const u8 = null,
};

fn hasErrorDiagnostic(diagnostics: []const Diagnostic) bool {
    for (diagnostics) |d| {
        if (d.severity == .error_) return true;
    }
    return false;
}

fn firstLineDiagnostic(text: []const u8, diagnostics: []const Diagnostic, line: usize) ?Diagnostic {
    const slice = lineSlice(text, line);
    const start = pointToOffset(text, .{ .line = line, .column = 0 });
    const end = start + slice.len;
    var best: ?Diagnostic = null;
    for (diagnostics) |d| {
        if (d.end <= start or d.start >= end) continue;
        if (best == null or @intFromEnum(d.severity) < @intFromEnum(best.?.severity)) {
            best = d;
        }
    }
    return best;
}

/// Render a read-only line list with optional gutter + diagnostic tint.
/// Editing stays on TextArea / host; this shell visualizes structure + diagnostics.
pub fn codeInput(arena: std.mem.Allocator, props: Props) *Div {
    const text = props.state.text;
    const lines = lineCount(text);
    const show_diags = props.state.options.show_diagnostics;
    const diagnostics = props.state.diagnostics;

    var root = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .flexRow()
        .overflowHidden()
        .role(.textarea)
        .a11yName(props.a11y_name orelse "Code")
        .a11yValueText(text);

    if (show_diags and diagnostics.len > 0) {
        const desc = std.fmt.allocPrint(
            arena,
            "{d} diagnostic{s}",
            .{ diagnostics.len, if (diagnostics.len == 1) "" else "s" },
        ) catch @panic("frame arena OOM");
        root = root.a11yDescription(desc);
        if (hasErrorDiagnostic(diagnostics)) {
            root = root.a11yInvalid(true);
        }
    }

    if (props.state.options.line_number) {
        var gutter = div_mod.div(arena)
            .withId(std.fmt.allocPrint(arena, "{s}-gutter", .{props.id}) catch @panic("frame arena OOM"))
            .flexCol()
            .wPx(props.gutter_width)
            .interactive()
            .role(.group)
            .a11yName("Line numbers");
        for (0..lines) |line| {
            const sev = if (show_diags)
                lineSeverity(text, diagnostics, line)
            else
                null;
            const gid = std.fmt.allocPrint(arena, "{s}-gutter-{d}", .{ props.id, line }) catch @panic("frame arena OOM");
            var cell = div_mod.div(arena).withId(gid).wFull().hPx(props.row_height).interactive();
            var s = style_mod.Style{};
            s.width = .{ .percent = 100 };
            s.height = .{ .px = props.row_height };
            s.background = Rgba.fromHex(0xf1f5f9);
            if (props.gutter_style_fn) |style_fn| {
                cell = cell.withStyle(style_fn(line, sev));
            } else {
                cell = cell.withStyle(s);
            }
            gutter = gutter.childDiv(cell);
        }
        root = root.childDiv(gutter);
    }

    var body = div_mod.div(arena)
        .withId(std.fmt.allocPrint(arena, "{s}-body", .{props.id}) catch @panic("frame arena OOM"))
        .flexCol()
        .wFull()
        .interactive()
        .role(.group)
        .a11yName("Source");

    for (0..lines) |line| {
        const sev = if (show_diags)
            lineSeverity(text, diagnostics, line)
        else
            null;
        const rid = std.fmt.allocPrint(arena, "{s}-line-{d}", .{ props.id, line }) catch @panic("frame arena OOM");
        var row = div_mod.div(arena).withId(rid).wFull().hPx(props.row_height).interactive();
        if (show_diags) {
            if (firstLineDiagnostic(text, diagnostics, line)) |diag| {
                row = row.role(.group).a11yName(diag.message);
                if (diag.severity == .error_) {
                    row = row.a11yInvalid(true);
                }
            }
        }
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = props.row_height };
        s.background = switch (sev orelse .hint) {
            .error_ => if (sev != null) Rgba.fromHex(0xfef2f2) else Rgba.fromHex(0xffffff),
            .warning => Rgba.fromHex(0xfffbeb),
            .information => Rgba.fromHex(0xeff6ff),
            .hint => Rgba.fromHex(0xffffff),
        };
        if (sev == null) s.background = Rgba.fromHex(0xffffff);
        if (props.row_style_fn) |style_fn| {
            row = row.withStyle(style_fn(line, sev));
        } else {
            row = row.withStyle(s);
        }
        body = body.childDiv(row);
    }

    return root.childDiv(body);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

test "offsetToPoint and pointToOffset round-trip" {
    const text = "ab\ncde\n\nf";
    try std.testing.expectEqual(Point{ .line = 0, .column = 2 }, offsetToPoint(text, 2));
    try std.testing.expectEqual(Point{ .line = 1, .column = 0 }, offsetToPoint(text, 3));
    try std.testing.expectEqual(Point{ .line = 1, .column = 3 }, offsetToPoint(text, 6));
    try std.testing.expectEqual(@as(usize, 3), pointToOffset(text, .{ .line = 1, .column = 0 }));
    try std.testing.expectEqual(@as(usize, 5), pointToOffset(text, .{ .line = 1, .column = 2 }));
    try std.testing.expectEqualStrings("cde", lineSlice(text, 1));
    try std.testing.expectEqual(@as(usize, 4), lineCount(text));
}

test "diagnosticsInRange and lineSeverity" {
    const text = "fn main() {\n  bad\n}\n";
    const diags = [_]Diagnostic{
        .{ .start = 14, .end = 17, .severity = .error_, .message = "unknown" },
        .{ .start = 0, .end = 2, .severity = .hint, .message = "fn" },
    };
    var buf: [8]usize = undefined;
    const n = diagnosticsInRange(&diags, 14, 18, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 0), buf[0]);
    try std.testing.expectEqual(Severity.error_, lineSeverity(text, &diags, 1).?);
    try std.testing.expectEqual(Severity.hint, lineSeverity(text, &diags, 0).?);
    try std.testing.expect(lineSeverity(text, &diags, 2) == null);
}

test "codeInput gutter and diagnostic rows" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 200 });
    defer harness.deinit();

    const Fixture = struct {
        state: State = .{},

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return codeInput(arena, .{
                .id = "editor",
                .state = &self.state,
            }).any();
        }
    };

    const diags = [_]Diagnostic{
        .{ .start = 4, .end = 7, .severity = .error_, .message = "bad" },
    };
    var fixture: Fixture = .{
        .state = .{
            .text = "ok\nbad\nok\n",
            .diagnostics = &diags,
            .options = .{ .line_number = true, .show_diagnostics = true },
        },
    };
    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expect(harness.hitboxBounds(element.elementId("editor-gutter-1")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("editor-line-1")) != null);
    try std.testing.expectEqual(Severity.error_, lineSeverity(fixture.state.text, fixture.state.diagnostics, 1).?);
    try std.testing.expectEqual(a11y_mod.Role.textarea, harness.a11yRole("editor").?);
    try std.testing.expectEqualStrings("Code", harness.a11yName("editor").?);
    try std.testing.expectEqualStrings("1 diagnostic", harness.a11yNode("editor").?.description.?);
    try std.testing.expect(harness.a11yNode("editor").?.invalid == true);
    try std.testing.expectEqual(a11y_mod.Role.group, harness.a11yRole("editor-gutter").?);
    try std.testing.expectEqualStrings("bad", harness.a11yName("editor-line-1").?);
    try std.testing.expect(harness.a11yNode("editor-line-1").?.invalid == true);
}
