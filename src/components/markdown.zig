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
