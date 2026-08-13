//! Thin styled wrapper around the headless `TextArea` element.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const text_area_mod = @import("../elements/text_area.zig");
const text_el = @import("../elements/text.zig");
const style_mod = @import("../style.zig");
const app_mod = @import("../app.zig");
const geometry = @import("../geometry.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;
const Pixels = geometry.Pixels;
const TextAreaState = text_area_mod.TextAreaState;
const TextResources = text_el.TextResources;

pub const Value = union(enum) {
    controlled: struct {
        text: []const u8,
        caret: usize = 0,
        selection_anchor: ?usize = null,
    },
    uncontrolled: app_mod.Entity(TextAreaState),
};

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

pub const StyleState = struct {
    focused: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    resources: *TextResources,
    value: Value,
    /// Direct or frame-local referenced accessible name.
    a11y_name: a11y_mod.NameSource = .none,
    disabled: bool = false,
    placeholder: []const u8 = "",
    on_change: ?ChangeHandler = null,
    style_fn: ?StyleFn = null,
};

pub fn readText(app: *app_mod.App, value: Value) []const u8 {
    return switch (value) {
        .controlled => |c| c.text,
        .uncontrolled => |entity| app.read(TextAreaState, entity).text(),
    };
}

/// Build a textarea inside a sized div shell. Returns the outer container;
/// the editable area is its sole child.
pub fn textarea(
    arena: std.mem.Allocator,
    input: *element.InputState,
    app: *app_mod.App,
    props: Props,
) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;

    const state = StyleState{
        .focused = input.isFocused(focus_id),
        .hovered = input.isHovered(id),
        .disabled = props.disabled,
    };

    const shell_style = if (props.style_fn) |style_fn| style_fn(state) else style_mod.Style{};
    var shell = div_mod.div(arena).withStyle(shell_style);

    const field_width: Pixels = switch (shell_style.width) {
        .px => |w| w,
        else => 200,
    };
    const field_height: Pixels = switch (shell_style.height) {
        .px => |h| h,
        else => 96,
    };

    const entity = switch (props.value) {
        .uncontrolled => |e| e,
        .controlled => @panic("textarea controlled mode: use textArea element directly"),
    };

    const area_el = text_area_mod.textArea(arena, props.resources, input, app, entity, .{
        .id = props.id,
        .a11y_name = props.a11y_name,
        .disabled = props.disabled,
        .placeholder = props.placeholder,
        .width = field_width,
        .height = field_height,
    });

    return shell.child(area_el.any());
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");
const text_mod = @import("../text/text.zig");

const TextAreaFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(TextAreaState) = undefined,
    resources: TextResources = undefined,
    font_system: text_mod.FontSystem = undefined,
    atlas: text_mod.GlyphAtlas = undefined,

    fn initResources(self: *TextAreaFixture) !void {
        self.font_system = text_mod.FontSystem.init(self.harness.gpa) catch return error.SkipZigTest;
        errdefer self.font_system.deinit();
        const font = try text_mod.loadTestFont(&self.font_system);
        self.atlas = try text_mod.GlyphAtlas.init(self.harness.gpa, geometry.Size(i32).init(512, 512));
        errdefer self.atlas.deinit();
        self.resources = .{
            .font_system = &self.font_system,
            .atlas = &self.atlas,
            .default_font = font,
        };
    }

    fn deinitResources(self: *TextAreaFixture) void {
        self.atlas.deinit();
        self.font_system.deinit();
    }

    fn text(self: *TextAreaFixture) []const u8 {
        return self.harness.app.read(TextAreaState, self.state).text();
    }

    fn caret(self: *TextAreaFixture) usize {
        return self.harness.app.read(TextAreaState, self.state).caret;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *TextAreaFixture = @ptrCast(@alignCast(ctx.?));
        const root = div_mod.div(arena)
            .sizePx(300, 200)
            .padPx(20)
            .childDiv(textarea(arena, &harness.input, &harness.app, .{
            .id = "the-area",
            .resources = &self.resources,
            .value = .{ .uncontrolled = self.state },
            .a11y_name = .{ .label = "Notes" },
            .style_fn = styleFor,
        }));
        return root.any();
    }

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 200 };
        s.height = .{ .px = 96 };
        s.background = if (state.focused)
            color.Rgba.fromHex(0xffffff)
        else
            color.Rgba.fromHex(0xf0f0f0);
        return s;
    }
};

test "textarea exposes named multiline text semantics" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextAreaFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextAreaState, try TextAreaState.initWithText(harness.gpa, "line1\nline2"));
    try harness.setRoot(&fixture, TextAreaFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.textarea, harness.a11yRole("the-area").?);
    try std.testing.expectEqualStrings("Notes", harness.a11yName("the-area").?);
    try std.testing.expectEqualStrings("line1\nline2", harness.a11yNode("the-area").?.value_text.?);
    try std.testing.expectEqual(@as(?usize, 11), harness.a11yNode("the-area").?.caret);
}

test "textarea types multiline text via text_input" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextAreaFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextAreaState, TextAreaState.init(harness.gpa));
    try harness.setRoot(&fixture, TextAreaFixture.render);

    try harness.focusById(element.elementId("the-area"));
    try harness.textInput("line1");
    try harness.keyDown(.enter);
    try harness.textInput("line2");
    try std.testing.expectEqualStrings("line1\nline2", fixture.text());
}

test "textarea enter inserts newline" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextAreaFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextAreaState, try TextAreaState.initWithText(harness.gpa, "a"));
    try harness.setRoot(&fixture, TextAreaFixture.render);
    try harness.focusById(element.elementId("the-area"));

    try harness.keyDown(.enter);
    try harness.textInput("b");
    try std.testing.expectEqualStrings("a\nb", fixture.text());
    try std.testing.expectEqual(@as(usize, 3), fixture.caret());
}

test "textarea backspace merges lines" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextAreaFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextAreaState, try TextAreaState.initWithText(harness.gpa, "ab\ncd"));
    try harness.setRoot(&fixture, TextAreaFixture.render);
    try harness.focusById(element.elementId("the-area"));

    try harness.keyDown(.left);
    try harness.keyDown(.left);
    try harness.keyDown(.backspace);
    try std.testing.expectEqualStrings("abcd", fixture.text());
    try std.testing.expectEqual(@as(usize, 2), fixture.caret());
}

test "textarea arrow up down move caret between lines" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextAreaFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextAreaState, try TextAreaState.initWithText(harness.gpa, "ab\ncd"));
    try harness.setRoot(&fixture, TextAreaFixture.render);
    try harness.focusById(element.elementId("the-area"));

    // Caret starts at end (offset 5). Move to column 1 on line 1.
    try harness.keyDown(.left);
    const line1_col1 = fixture.caret();

    try harness.keyDown(.up);
    try std.testing.expectEqual(@as(usize, 1), fixture.caret());

    try harness.keyDown(.down);
    try std.testing.expectEqual(line1_col1, fixture.caret());
}
