//! Headless Markdown block parse + TextView shell (gpui-component text/view).
//!
//! Intentionally small: CommonMark-ish block kinds used by apps (heading,
//! paragraph, list, fence, hr, blockquote). No HTML, tables, or syntax theme.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;
const Pixels = geometry.Pixels;
const Rgba = color.Rgba;

pub const BlockKind = enum {
    paragraph,
    heading,
    list_item,
    code_block,
    blockquote,
    horizontal_rule,
};

pub const Block = struct {
    kind: BlockKind,
    /// Heading level 1..6 when kind == .heading; otherwise unused.
    level: u8 = 0,
    /// Ordered list marker when kind == .list_item and ordered.
    ordered: bool = false,
    /// Source slice into the original markdown (not owned).
    text: []const u8 = "",
    /// Fenced code language tag (empty if none / not a fence).
    language: []const u8 = "",
};

fn trimRight(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[0..end];
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

fn isBlank(s: []const u8) bool {
    return trimLeft(trimRight(s)).len == 0;
}

fn headingLevel(line: []const u8) ?u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    if (i == 0 or i > 6) return null;
    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;
    return @intCast(i);
}

fn fenceInfo(line: []const u8) ?[]const u8 {
    const t = trimLeft(trimRight(line));
    if (t.len < 3) return null;
    if (!(std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~"))) return null;
    return trimLeft(t[3..]);
}

fn isFenceClose(line: []const u8) bool {
    const t = trimLeft(trimRight(line));
    if (t.len < 3) return false;
    if (!(std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~"))) return false;
    return trimLeft(t[3..]).len == 0;
}

fn listMarker(line: []const u8) ?struct { ordered: bool, rest: []const u8 } {
    const t = trimLeft(line);
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and (t[1] == ' ' or t[1] == '\t')) {
        return .{ .ordered = false, .rest = trimLeft(t[2..]) };
    }
    var i: usize = 0;
    while (i < t.len and t[i] >= '0' and t[i] <= '9') : (i += 1) {}
    if (i == 0 or i + 1 >= t.len) return null;
    if (t[i] != '.' and t[i] != ')') return null;
    if (t[i + 1] != ' ' and t[i + 1] != '\t') return null;
    return .{ .ordered = true, .rest = trimLeft(t[i + 2 ..]) };
}

fn isRule(line: []const u8) bool {
    const t = trimRight(trimLeft(line));
    return std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "***") or std.mem.eql(u8, t, "___");
}

/// Parse a minimal Markdown document into flat top-level blocks.
/// Block `text` slices alias `source` (caller keeps `source` alive).
pub fn parseBlocks(allocator: std.mem.Allocator, source: []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    errdefer out.deinit(allocator);

    var in_fence = false;
    var fence_lang: []const u8 = "";
    var fence_body_start: usize = 0;
    var pending_para_start: ?usize = null;
    var pending_para_end: usize = 0;
    var offset: usize = 0;

    const flush_pending = struct {
        fn call(
            list: *std.ArrayList(Block),
            alloc: std.mem.Allocator,
            src: []const u8,
            start: *?usize,
            end: usize,
        ) !void {
            if (start.*) |s| {
                const body = trimRight(src[s..end]);
                if (body.len > 0) try list.append(alloc, .{ .kind = .paragraph, .text = body });
            }
            start.* = null;
        }
    }.call;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const line_off = offset;
        // Advance past this line and its newline (except past EOF without nl).
        offset += raw_line.len;
        if (offset < source.len and source[offset] == '\n') offset += 1;

        if (in_fence) {
            if (isFenceClose(line)) {
                const body = if (line_off > fence_body_start)
                    source[fence_body_start..line_off]
                else
                    "";
                const text = if (body.len > 0 and body[body.len - 1] == '\n')
                    body[0 .. body.len - 1]
                else
                    body;
                try out.append(allocator, .{
                    .kind = .code_block,
                    .text = text,
                    .language = fence_lang,
                });
                in_fence = false;
            }
            continue;
        }

        if (fenceInfo(line)) |lang| {
            try flush_pending(&out, allocator, source, &pending_para_start, pending_para_end);
            in_fence = true;
            fence_lang = lang;
            fence_body_start = offset;
            continue;
        }

        if (isBlank(line)) {
            try flush_pending(&out, allocator, source, &pending_para_start, pending_para_end);
            continue;
        }

        const trimmed = trimLeft(line);
        if (isRule(trimmed)) {
            try flush_pending(&out, allocator, source, &pending_para_start, pending_para_end);
            try out.append(allocator, .{ .kind = .horizontal_rule, .text = trimRight(trimmed) });
            continue;
        }

        if (headingLevel(trimmed)) |level| {
            try flush_pending(&out, allocator, source, &pending_para_start, pending_para_end);
            try out.append(allocator, .{
                .kind = .heading,
                .level = level,
                .text = trimRight(trimLeft(trimmed[level..])),
            });
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, ">")) {
            try flush_pending(&out, allocator, source, &pending_para_start, pending_para_end);
            var rest = trimmed[1..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            try out.append(allocator, .{ .kind = .blockquote, .text = trimRight(rest) });
            continue;
        }

        if (listMarker(line)) |m| {
            try flush_pending(&out, allocator, source, &pending_para_start, pending_para_end);
            try out.append(allocator, .{
                .kind = .list_item,
                .ordered = m.ordered,
                .text = trimRight(m.rest),
            });
            continue;
        }

        if (pending_para_start == null) pending_para_start = line_off;
        pending_para_end = line_off + line.len;
    }

    try flush_pending(&out, allocator, source, &pending_para_start, pending_para_end);

    if (in_fence) {
        const text = if (fence_body_start < source.len) source[fence_body_start..] else "";
        try out.append(allocator, .{
            .kind = .code_block,
            .text = text,
            .language = fence_lang,
        });
    }

    return try out.toOwnedSlice(allocator);
}

pub fn freeBlocks(allocator: std.mem.Allocator, blocks: []Block) void {
    allocator.free(blocks);
}

// ---------------------------------------------------------------------------
// Inline spans (subset: strong / emphasis / code / link)
// ---------------------------------------------------------------------------

pub const SpanKind = enum { text, strong, emphasis, code, link };

pub const Span = struct {
    kind: SpanKind,
    /// Visible text (aliases source, or for links the label body).
    text: []const u8 = "",
    /// Link destination when kind == .link.
    href: []const u8 = "",
};

fn pushText(list: *std.ArrayList(Span), alloc: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    if (list.items.len > 0 and list.items[list.items.len - 1].kind == .text) {
        // Merge adjacent plain runs that are contiguous in source.
        const prev = list.items[list.items.len - 1];
        if (prev.text.ptr + prev.text.len == text.ptr) {
            list.items[list.items.len - 1].text = prev.text.ptr[0 .. prev.text.len + text.len];
            return;
        }
    }
    try list.append(alloc, .{ .kind = .text, .text = text });
}

/// Parse a single inline line into spans. Spans alias `source`.
pub fn parseInlines(allocator: std.mem.Allocator, source: []const u8) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var text_start: usize = 0;

    while (i < source.len) {
        // Inline code `...`
        if (source[i] == '`') {
            try pushText(&out, allocator, source[text_start..i]);
            var j = i + 1;
            while (j < source.len and source[j] != '`') : (j += 1) {}
            if (j < source.len) {
                try out.append(allocator, .{ .kind = .code, .text = source[i + 1 .. j] });
                i = j + 1;
                text_start = i;
                continue;
            }
            // Unclosed — treat as text.
            i += 1;
            continue;
        }

        // Link [label](href)
        if (source[i] == '[') {
            try pushText(&out, allocator, source[text_start..i]);
            var j = i + 1;
            while (j < source.len and source[j] != ']') : (j += 1) {}
            if (j + 1 < source.len and source[j] == ']' and source[j + 1] == '(') {
                var k = j + 2;
                while (k < source.len and source[k] != ')') : (k += 1) {}
                if (k < source.len) {
                    try out.append(allocator, .{
                        .kind = .link,
                        .text = source[i + 1 .. j],
                        .href = source[j + 2 .. k],
                    });
                    i = k + 1;
                    text_start = i;
                    continue;
                }
            }
            i += 1;
            continue;
        }

        // Strong **...** or __...__
        if (i + 1 < source.len and
            ((source[i] == '*' and source[i + 1] == '*') or (source[i] == '_' and source[i + 1] == '_')))
        {
            const marker = source[i];
            try pushText(&out, allocator, source[text_start..i]);
            var j = i + 2;
            while (j + 1 < source.len) : (j += 1) {
                if (source[j] == marker and source[j + 1] == marker) break;
            }
            if (j + 1 < source.len) {
                try out.append(allocator, .{ .kind = .strong, .text = source[i + 2 .. j] });
                i = j + 2;
                text_start = i;
                continue;
            }
            i += 1;
            continue;
        }

        // Emphasis *...* or _..._ (single)
        if (source[i] == '*' or source[i] == '_') {
            const marker = source[i];
            // Avoid eating the first of a ** pair already handled.
            try pushText(&out, allocator, source[text_start..i]);
            var j = i + 1;
            while (j < source.len and source[j] != marker) : (j += 1) {}
            if (j < source.len) {
                try out.append(allocator, .{ .kind = .emphasis, .text = source[i + 1 .. j] });
                i = j + 1;
                text_start = i;
                continue;
            }
            i += 1;
            continue;
        }

        i += 1;
    }

    try pushText(&out, allocator, source[text_start..]);
    return try out.toOwnedSlice(allocator);
}

pub fn freeSpans(allocator: std.mem.Allocator, spans: []Span) void {
    allocator.free(spans);
}

/// Flatten span text for a11y / plain extraction.
pub fn plainText(allocator: std.mem.Allocator, spans: []const Span) ![]u8 {
    var total: usize = 0;
    for (spans) |s| total += s.text.len;
    var buf = try allocator.alloc(u8, total);
    var o: usize = 0;
    for (spans) |s| {
        @memcpy(buf[o .. o + s.text.len], s.text);
        o += s.text.len;
    }
    return buf;
}

pub const BlockStyleFn = *const fn (block: Block, index: usize) style_mod.Style;

pub const TextViewProps = struct {
    id: []const u8,
    blocks: []const Block,
    block_style_fn: ?BlockStyleFn = null,
    /// Default block height hint for layout tests.
    block_height: Pixels = 24,
};

/// Render parsed blocks as a vertical TextView column (headless shell).
pub fn textView(arena: std.mem.Allocator, props: TextViewProps) *Div {
    var root = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .flexCol()
        .wFull()
        .role(.generic);

    for (props.blocks, 0..) |block, i| {
        const bid = std.fmt.allocPrint(arena, "{s}-block-{d}", .{ props.id, i }) catch @panic("frame arena OOM");
        var row = div_mod.div(arena).withId(bid).wFull().interactive();
        row = switch (block.kind) {
            .heading => row.role(.heading).a11yHeadingLevel(block.level).a11yName(block.text),
            .paragraph, .list_item, .blockquote => row.role(.generic).a11yName(block.text),
            else => row.role(.generic),
        };
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = switch (block.kind) {
            .horizontal_rule => 8,
            .heading => props.block_height + 8,
            .code_block => props.block_height * 2,
            else => props.block_height,
        } };
        s.background = switch (block.kind) {
            .code_block => Rgba.fromHex(0xf1f5f9),
            .blockquote => Rgba.fromHex(0xf8fafc),
            else => Rgba.fromHex(0xffffff),
        };
        if (props.block_style_fn) |style_fn| {
            row = row.withStyle(style_fn(block, i));
        } else {
            row = row.withStyle(s);
        }
        root = root.childDiv(row);
    }
    return root;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

test "parseBlocks headings lists fences" {
    const src =
        \\# Title
        \\
        \\Hello **world**
        \\
        \\- one
        \\- two
        \\
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\> quote
        \\
        \\---
    ;
    const blocks = try parseBlocks(std.testing.allocator, src);
    defer freeBlocks(std.testing.allocator, blocks);

    try std.testing.expectEqual(@as(usize, 7), blocks.len);
    try std.testing.expectEqual(BlockKind.heading, blocks[0].kind);
    try std.testing.expectEqual(@as(u8, 1), blocks[0].level);
    try std.testing.expectEqualStrings("Title", blocks[0].text);
    try std.testing.expectEqual(BlockKind.paragraph, blocks[1].kind);
    try std.testing.expectEqual(BlockKind.list_item, blocks[2].kind);
    try std.testing.expectEqual(BlockKind.list_item, blocks[3].kind);
    try std.testing.expectEqual(BlockKind.code_block, blocks[4].kind);
    try std.testing.expectEqualStrings("zig", blocks[4].language);
    try std.testing.expect(std.mem.indexOf(u8, blocks[4].text, "const x = 1;") != null);
    try std.testing.expectEqual(BlockKind.blockquote, blocks[5].kind);
    try std.testing.expectEqual(BlockKind.horizontal_rule, blocks[6].kind);
}

test "textView exposes block hitboxes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    const Fixture = struct {
        blocks: []Block = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return textView(arena, .{
                .id = "doc",
                .blocks = self.blocks,
            }).any();
        }
    };

    const src = "# A\n\npara\n";
    var fixture: Fixture = .{
        .blocks = try parseBlocks(std.testing.allocator, src),
    };
    defer freeBlocks(std.testing.allocator, fixture.blocks);

    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expect(harness.hitboxBounds(element.elementId("doc-block-0")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("doc-block-1")) != null);
}

test "parseInlines strong emphasis code link" {
    const spans = try parseInlines(std.testing.allocator, "Hi **bold** and *em* plus `code` and [z](https://z.dev)");
    defer freeSpans(std.testing.allocator, spans);

    try std.testing.expectEqual(@as(usize, 8), spans.len);
    try std.testing.expectEqual(SpanKind.text, spans[0].kind);
    try std.testing.expectEqual(SpanKind.strong, spans[1].kind);
    try std.testing.expectEqualStrings("bold", spans[1].text);
    try std.testing.expectEqual(SpanKind.emphasis, spans[3].kind);
    try std.testing.expectEqualStrings("em", spans[3].text);
    try std.testing.expectEqual(SpanKind.code, spans[5].kind);
    try std.testing.expectEqualStrings("code", spans[5].text);
    try std.testing.expectEqual(SpanKind.link, spans[7].kind);
    try std.testing.expectEqualStrings("z", spans[7].text);
    try std.testing.expectEqualStrings("https://z.dev", spans[7].href);

    const plain = try plainText(std.testing.allocator, spans);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("Hi bold and em plus code and z", plain);
}
