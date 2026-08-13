//! Thin styled wrapper around the headless `TextInput` element.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const text_input_mod = @import("../elements/text_input.zig");
const text_el = @import("../elements/text.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const geometry = @import("../geometry.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;
const Pixels = geometry.Pixels;
const TextInputState = text_input_mod.TextInputState;
const TextResources = text_el.TextResources;

pub const Value = union(enum) {
    controlled: struct {
        text: []const u8,
        caret: usize = 0,
        selection_anchor: ?usize = null,
    },
    uncontrolled: app_mod.Entity(TextInputState),
};

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

pub const StyleState = struct {
    focused: bool = false,
    focus_visible: bool = false,
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
        .uncontrolled => |entity| app.read(TextInputState, entity).text(),
    };
}

/// Build a text field inside a sized div shell. Returns the outer container;
/// the editable input is its sole child.
pub fn textField(
    arena: std.mem.Allocator,
    input: *element.InputState,
    app: *app_mod.App,
    props: Props,
) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;

    const state = StyleState{
        .focused = input.isFocused(focus_id),
        .focus_visible = input.focus_visible and input.isFocused(focus_id),
        .hovered = input.isHovered(id),
        .disabled = props.disabled,
    };

    const shell_style = if (props.style_fn) |style_fn| style_fn(state) else style_mod.Style{};
    var shell = div_mod.div(arena).withStyle(shell_style);

    const field_width: Pixels = switch (shell_style.width) {
        .px => |w| w,
        else => 160,
    };
    const field_height: Pixels = switch (shell_style.height) {
        .px => |h| h,
        else => 32,
    };

    const entity = switch (props.value) {
        .uncontrolled => |e| e,
        .controlled => @panic("textField controlled mode: use textInput element directly"),
    };

    const input_el = text_input_mod.textInput(arena, props.resources, input, app, entity, .{
        .id = props.id,
        .a11y_name = props.a11y_name,
        .disabled = props.disabled,
        .placeholder = props.placeholder,
        .width = field_width,
        .height = field_height,
    });

    return shell.child(input_el.any());
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const TextFieldFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(TextInputState) = undefined,
    resources: TextResources = undefined,
    font_system: text_mod.FontSystem = undefined,
    atlas: text_mod.GlyphAtlas = undefined,

    fn initResources(self: *TextFieldFixture) !void {
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

    fn deinitResources(self: *TextFieldFixture) void {
        self.atlas.deinit();
        self.font_system.deinit();
    }

    fn text(self: *TextFieldFixture) []const u8 {
        return self.harness.app.read(TextInputState, self.state).text();
    }

    fn caret(self: *TextFieldFixture) usize {
        return self.harness.app.read(TextInputState, self.state).caret;
    }

    fn preedit(self: *TextFieldFixture) []const u8 {
        return self.harness.app.read(TextInputState, self.state).preeditText();
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *TextFieldFixture = @ptrCast(@alignCast(ctx.?));
        const root = div_mod.div(arena)
            .sizePx(300, 200)
            .padPx(20)
            .childDiv(textField(arena, &harness.input, &harness.app, .{
            .id = "the-field",
            .resources = &self.resources,
            .value = .{ .uncontrolled = self.state },
            .a11y_name = .{ .label = "Account name" },
            .style_fn = styleFor,
        }));
        return root.any();
    }

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 160 };
        s.height = .{ .px = 32 };
        s.background = if (state.focused)
            color.Rgba.fromHex(0xffffff)
        else
            color.Rgba.fromHex(0xf0f0f0);
        return s;
    }
};

const text_mod = @import("../text/text.zig");

test "text field exposes textbox role" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, try TextInputState.initWithText(harness.gpa, "hello"));
    try harness.setRoot(&fixture, TextFieldFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.textbox, harness.a11yRole("the-field").?);
    try std.testing.expectEqualStrings("Account name", harness.a11yName("the-field").?);
    try std.testing.expectEqualStrings("hello", harness.a11yNode("the-field").?.value_text.?);
    try std.testing.expectEqual(@as(?usize, 5), harness.a11yNode("the-field").?.caret);
}

test "text field a11y exposes caret and selection range" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, try TextInputState.initWithText(harness.gpa, "abcd"));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    try harness.keyDown(.left);
    try harness.keyDown(.left);
    try harness.keyDownWith(.right, .{ .shift = true });
    try harness.keyDownWith(.right, .{ .shift = true });

    const node = harness.a11yNode("the-field").?;
    try std.testing.expectEqual(@as(?usize, 4), node.caret);
    try std.testing.expectEqual(@as(?usize, 2), node.selection_start);
    try std.testing.expectEqual(@as(?usize, 4), node.selection_end);
    try std.testing.expectEqualStrings("cd", a11y_mod.selectedText(node).?);
}

test "text field types characters via text_input" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, TextInputState.init(harness.gpa));
    try harness.setRoot(&fixture, TextFieldFixture.render);

    try harness.focusById(element.elementId("the-field"));
    try harness.textInput("ab");
    try std.testing.expectEqualStrings("ab", fixture.text());
    try std.testing.expectEqual(@as(usize, 2), fixture.caret());
}

test "text field backspace deletes character" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, try TextInputState.initWithText(harness.gpa, "abc"));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    try harness.keyDown(.backspace);
    try std.testing.expectEqualStrings("ab", fixture.text());
    try std.testing.expectEqual(@as(usize, 2), fixture.caret());
}

test "text field arrow keys move caret" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, try TextInputState.initWithText(harness.gpa, "abc"));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    try harness.keyDown(.left);
    try std.testing.expectEqual(@as(usize, 2), fixture.caret());

    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 3), fixture.caret());
}

test "text field selection replace on type" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, try TextInputState.initWithText(harness.gpa, "abc"));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    // Select "bc" with shift+left twice from end.
    try harness.keyDownWith(.left, .{ .shift = true });
    try harness.keyDownWith(.left, .{ .shift = true });
    try harness.textInput("z");
    try std.testing.expectEqualStrings("az", fixture.text());
}

test "text field focuses on click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, TextInputState.init(harness.gpa));
    try harness.setRoot(&fixture, TextFieldFixture.render);

    try harness.clickOn("the-field");
    try std.testing.expect(harness.input.isFocused(element.elementId("the-field")));
}

test "text field composition update sets preedit without changing buffer" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, try TextInputState.initWithText(harness.gpa, "ab"));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    try harness.compositionStart();
    try harness.compositionUpdate("ni");
    try std.testing.expectEqualStrings("ab", fixture.text());
    try std.testing.expectEqualStrings("ni", fixture.preedit());

    try harness.compositionEnd();
    try std.testing.expectEqual(@as(usize, 0), fixture.preedit().len);
    try std.testing.expectEqualStrings("ab", fixture.text());
}

test "text field text_input during composition commits and clears preedit" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, TextInputState.init(harness.gpa));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    try harness.compositionUpdate("x");
    try std.testing.expectEqualStrings("x", fixture.preedit());
    try harness.textInput("z");
    try std.testing.expectEqualStrings("z", fixture.text());
    try std.testing.expectEqual(@as(usize, 0), fixture.preedit().len);
}

test "text field ASCII text_input still works alongside composition" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, TextInputState.init(harness.gpa));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    try harness.textInput("hello");
    try std.testing.expectEqualStrings("hello", fixture.text());

    try harness.compositionUpdate("你");
    try std.testing.expectEqualStrings("hello", fixture.text());
    try harness.compositionEnd();
    try harness.textInput("!");
    try std.testing.expectEqualStrings("hello!", fixture.text());
}

const edit_mod = platform.Modifiers{ .control = true };

test "text field copy paste cut select all shortcuts" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, try TextInputState.initWithText(harness.gpa, "abcd"));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    // Select "bc": caret at 'b', extend through 'c'.
    try harness.keyDown(.left);
    try harness.keyDown(.left);
    try harness.keyDown(.left);
    try harness.keyDownWith(.right, .{ .shift = true });
    try harness.keyDownWith(.right, .{ .shift = true });

    try harness.keyDownWith(.c, edit_mod);
    try std.testing.expectEqualStrings("bc", harness.clipboardText());

    try harness.keyDownWith(.x, edit_mod);
    try std.testing.expectEqualStrings("bc", harness.clipboardText());
    try std.testing.expectEqualStrings("ad", fixture.text());

    try harness.setClipboard("XY");
    try harness.keyDownWith(.v, edit_mod);
    try std.testing.expectEqualStrings("aXYd", fixture.text());

    try harness.keyDownWith(.a, edit_mod);
    try harness.keyDownWith(.c, edit_mod);
    try std.testing.expectEqualStrings("aXYd", harness.clipboardText());
}

test "text field undo redo shortcuts" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TextFieldFixture{ .harness = &harness };
    try fixture.initResources();
    defer fixture.deinitResources();

    fixture.state = try harness.app.new(TextInputState, try TextInputState.initWithText(harness.gpa, "ab"));
    try harness.setRoot(&fixture, TextFieldFixture.render);
    try harness.focusById(element.elementId("the-field"));

    try harness.textInput("c");
    try std.testing.expectEqualStrings("abc", fixture.text());

    try harness.keyDownWith(.z, edit_mod);
    try std.testing.expectEqualStrings("ab", fixture.text());

    try harness.keyDownWith(.z, .{ .control = true, .shift = true });
    try std.testing.expectEqualStrings("abc", fixture.text());

    try harness.textInput("d");
    try std.testing.expectEqualStrings("abcd", fixture.text());

    try harness.keyDownWith(.z, edit_mod);
    try std.testing.expectEqualStrings("abc", fixture.text());

    try harness.keyDownWith(.y, edit_mod);
    try std.testing.expectEqualStrings("abcd", fixture.text());
}
