//! Flexbox layout engine (Yoga bindings).

const std = @import("std");
const yoga_c = @import("yoga_c");
const geometry = @import("../geometry.zig");

pub const Pixels = geometry.Pixels;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;

pub const Dimension = union(enum) {
    auto,
    points: Pixels,
    percent: Pixels,
};

pub const Margin = union(enum) {
    points: Pixels,
    percent: Pixels,
    auto,
};

pub const FlexDirection = enum {
    row,
    column,
    row_reverse,
    column_reverse,
};

pub const JustifyContent = enum {
    flex_start,
    center,
    flex_end,
    space_between,
    space_around,
    space_evenly,
};

pub const Align = enum {
    auto,
    flex_start,
    center,
    flex_end,
    stretch,
    baseline,
    space_between,
    space_around,
    space_evenly,
};

pub const PositionType = enum {
    relative,
    absolute,
};

pub const Display = enum {
    flex,
    none,
};

pub const Overflow = enum {
    visible,
    hidden,
    scroll,
};

pub const Edge = enum {
    left,
    top,
    right,
    bottom,
    start,
    end,
    horizontal,
    vertical,
    all,
};

pub const Gutter = enum {
    column,
    row,
    all,
};

pub const MeasureMode = enum {
    undefined,
    exactly,
    at_most,
};

pub const MeasureSize = struct {
    width: Pixels,
    height: Pixels,
};

pub const MeasureFn = *const fn (
    ctx: *anyopaque,
    width: Pixels,
    width_mode: MeasureMode,
    height: Pixels,
    height_mode: MeasureMode,
) MeasureSize;

const MeasureContext = struct {
    user_ctx: *anyopaque,
    measure_fn: MeasureFn,

    fn trampoline(
        node: yoga_c.YGNodeConstRef,
        width: f32,
        width_mode: yoga_c.YGMeasureMode,
        height: f32,
        height_mode: yoga_c.YGMeasureMode,
    ) callconv(.c) yoga_c.YGSize {
        const self: *MeasureContext = @ptrCast(@alignCast(yoga_c.YGNodeGetContext(@constCast(node))));
        const size = self.measure_fn(
            self.user_ctx,
            width,
            toMeasureMode(width_mode),
            height,
            toMeasureMode(height_mode),
        );
        return .{ .width = size.width, .height = size.height };
    }
};

pub const LayoutEngine = struct {
    config: yoga_c.YGConfigRef,

    pub fn init() LayoutEngine {
        const config = yoga_c.YGConfigNew();
        yoga_c.YGConfigSetPointScaleFactor(config, 1.0);
        return .{ .config = config };
    }

    pub fn deinit(self: *LayoutEngine) void {
        yoga_c.YGConfigFree(self.config);
        self.config = undefined;
    }

    pub fn newNode(self: *const LayoutEngine) Node {
        return Node.init(self.config);
    }

    pub fn computeLayout(
        self: *const LayoutEngine,
        root: *Node,
        available_width: ?Pixels,
        available_height: ?Pixels,
    ) void {
        _ = self;
        const width = available_width orelse yoga_c.YGUndefined;
        const height = available_height orelse yoga_c.YGUndefined;
        yoga_c.YGNodeCalculateLayout(root.handle, width, height, yoga_c.YGDirectionLTR);
    }
};

pub const Node = struct {
    handle: yoga_c.YGNodeRef,
    measure_ctx: ?*MeasureContext = null,

    pub fn init(config: yoga_c.YGConfigRef) Node {
        return .{ .handle = yoga_c.YGNodeNewWithConfig(config) };
    }

    pub fn free(self: *Node) void {
        yoga_c.YGNodeFree(self.handle);
        self.handle = undefined;
    }

    pub fn freeRecursive(self: *Node) void {
        yoga_c.YGNodeFreeRecursive(self.handle);
        self.handle = undefined;
    }

    pub fn addChild(self: *Node, child: *Node) void {
        yoga_c.YGNodeInsertChild(self.handle, child.handle, yoga_c.YGNodeGetChildCount(self.handle));
    }

    pub fn insertChild(self: *Node, child: *Node, index: usize) void {
        yoga_c.YGNodeInsertChild(self.handle, child.handle, index);
    }

    pub fn removeChild(self: *Node, child: *Node) void {
        yoga_c.YGNodeRemoveChild(self.handle, child.handle);
    }

    pub fn childCount(self: *const Node) usize {
        return yoga_c.YGNodeGetChildCount(self.handle);
    }

    /// `allocator` must outlive the node (use the frame arena; the context
    /// is reclaimed when the arena resets).
    pub fn setMeasureFunc(self: *Node, allocator: std.mem.Allocator, ctx: *anyopaque, measure_fn: MeasureFn) !void {
        const mc = try allocator.create(MeasureContext);
        mc.* = .{ .user_ctx = ctx, .measure_fn = measure_fn };
        self.measure_ctx = mc;
        yoga_c.YGNodeSetContext(self.handle, mc);
        yoga_c.YGNodeSetMeasureFunc(self.handle, MeasureContext.trampoline);
    }

    pub fn setFlexDirection(self: *Node, direction: FlexDirection) void {
        yoga_c.YGNodeStyleSetFlexDirection(self.handle, toYogaFlexDirection(direction));
    }

    pub fn setFlexGrow(self: *Node, grow: f32) void {
        yoga_c.YGNodeStyleSetFlexGrow(self.handle, grow);
    }

    pub fn setFlexShrink(self: *Node, shrink: f32) void {
        yoga_c.YGNodeStyleSetFlexShrink(self.handle, shrink);
    }

    pub fn setFlexBasis(self: *Node, basis: Dimension) void {
        switch (basis) {
            .auto => yoga_c.YGNodeStyleSetFlexBasisAuto(self.handle),
            .points => |value| yoga_c.YGNodeStyleSetFlexBasis(self.handle, value),
            .percent => |value| yoga_c.YGNodeStyleSetFlexBasisPercent(self.handle, value),
        }
    }

    pub fn setWidth(self: *Node, width: Dimension) void {
        switch (width) {
            .auto => yoga_c.YGNodeStyleSetWidthAuto(self.handle),
            .points => |value| yoga_c.YGNodeStyleSetWidth(self.handle, value),
            .percent => |value| yoga_c.YGNodeStyleSetWidthPercent(self.handle, value),
        }
    }

    pub fn setHeight(self: *Node, height: Dimension) void {
        switch (height) {
            .auto => yoga_c.YGNodeStyleSetHeightAuto(self.handle),
            .points => |value| yoga_c.YGNodeStyleSetHeight(self.handle, value),
            .percent => |value| yoga_c.YGNodeStyleSetHeightPercent(self.handle, value),
        }
    }

    pub fn setMinWidth(self: *Node, width: Dimension) void {
        switch (width) {
            .auto => {},
            .points => |value| yoga_c.YGNodeStyleSetMinWidth(self.handle, value),
            .percent => |value| yoga_c.YGNodeStyleSetMinWidthPercent(self.handle, value),
        }
    }

    pub fn setMinHeight(self: *Node, height: Dimension) void {
        switch (height) {
            .auto => {},
            .points => |value| yoga_c.YGNodeStyleSetMinHeight(self.handle, value),
            .percent => |value| yoga_c.YGNodeStyleSetMinHeightPercent(self.handle, value),
        }
    }

    pub fn setMaxWidth(self: *Node, width: Dimension) void {
        switch (width) {
            .auto => {},
            .points => |value| yoga_c.YGNodeStyleSetMaxWidth(self.handle, value),
            .percent => |value| yoga_c.YGNodeStyleSetMaxWidthPercent(self.handle, value),
        }
    }

    pub fn setMaxHeight(self: *Node, height: Dimension) void {
        switch (height) {
            .auto => {},
            .points => |value| yoga_c.YGNodeStyleSetMaxHeight(self.handle, value),
            .percent => |value| yoga_c.YGNodeStyleSetMaxHeightPercent(self.handle, value),
        }
    }

    pub fn setPadding(self: *Node, edge: Edge, padding: Pixels) void {
        yoga_c.YGNodeStyleSetPadding(self.handle, toYogaEdge(edge), padding);
    }

    pub fn setPaddingPercent(self: *Node, edge: Edge, percent: f32) void {
        yoga_c.YGNodeStyleSetPaddingPercent(self.handle, toYogaEdge(edge), percent);
    }

    pub fn setPaddingAll(self: *Node, padding: Pixels) void {
        self.setPadding(.all, padding);
    }

    pub fn setMargin(self: *Node, edge: Edge, margin: Margin) void {
        switch (margin) {
            .points => |value| yoga_c.YGNodeStyleSetMargin(self.handle, toYogaEdge(edge), value),
            .percent => |value| yoga_c.YGNodeStyleSetMarginPercent(self.handle, toYogaEdge(edge), value),
            .auto => yoga_c.YGNodeStyleSetMarginAuto(self.handle, toYogaEdge(edge)),
        }
    }

    pub fn setMarginAll(self: *Node, margin: Margin) void {
        self.setMargin(.all, margin);
    }

    pub fn setGap(self: *Node, gutter: Gutter, gap: Pixels) void {
        yoga_c.YGNodeStyleSetGap(self.handle, toYogaGutter(gutter), gap);
    }

    pub fn setGapAll(self: *Node, gap: Pixels) void {
        self.setGap(.all, gap);
    }

    pub fn setJustifyContent(self: *Node, justify: JustifyContent) void {
        yoga_c.YGNodeStyleSetJustifyContent(self.handle, toYogaJustify(justify));
    }

    pub fn setAlignItems(self: *Node, alignment: Align) void {
        yoga_c.YGNodeStyleSetAlignItems(self.handle, toYogaAlign(alignment));
    }

    pub fn setAlignSelf(self: *Node, alignment: Align) void {
        yoga_c.YGNodeStyleSetAlignSelf(self.handle, toYogaAlign(alignment));
    }

    pub fn setAlignContent(self: *Node, alignment: Align) void {
        yoga_c.YGNodeStyleSetAlignContent(self.handle, toYogaAlign(alignment));
    }

    pub fn setPositionType(self: *Node, position_type: PositionType) void {
        yoga_c.YGNodeStyleSetPositionType(self.handle, toYogaPositionType(position_type));
    }

    pub fn setPosition(self: *Node, edge: Edge, value: Dimension) void {
        switch (value) {
            .auto => yoga_c.YGNodeStyleSetPositionAuto(self.handle, toYogaEdge(edge)),
            .points => |points| yoga_c.YGNodeStyleSetPosition(self.handle, toYogaEdge(edge), points),
            .percent => |percent| yoga_c.YGNodeStyleSetPositionPercent(self.handle, toYogaEdge(edge), percent),
        }
    }

    pub fn setDisplay(self: *Node, display: Display) void {
        yoga_c.YGNodeStyleSetDisplay(self.handle, toYogaDisplay(display));
    }

    pub fn setOverflow(self: *Node, overflow: Overflow) void {
        yoga_c.YGNodeStyleSetOverflow(self.handle, toYogaOverflow(overflow));
    }

    pub fn layoutBounds(self: *const Node) Bounds(Pixels) {
        return Bounds(Pixels).init(
            .{ .x = yoga_c.YGNodeLayoutGetLeft(self.handle), .y = yoga_c.YGNodeLayoutGetTop(self.handle) },
            .{
                .width = yoga_c.YGNodeLayoutGetWidth(self.handle),
                .height = yoga_c.YGNodeLayoutGetHeight(self.handle),
            },
        );
    }

    pub fn layoutPadding(self: *const Node) Edges(Pixels) {
        return .{
            .top = yoga_c.YGNodeLayoutGetPadding(self.handle, yoga_c.YGEdgeTop),
            .right = yoga_c.YGNodeLayoutGetPadding(self.handle, yoga_c.YGEdgeRight),
            .bottom = yoga_c.YGNodeLayoutGetPadding(self.handle, yoga_c.YGEdgeBottom),
            .left = yoga_c.YGNodeLayoutGetPadding(self.handle, yoga_c.YGEdgeLeft),
        };
    }
};

fn toMeasureMode(mode: yoga_c.YGMeasureMode) MeasureMode {
    return switch (mode) {
        yoga_c.YGMeasureModeUndefined => .undefined,
        yoga_c.YGMeasureModeExactly => .exactly,
        yoga_c.YGMeasureModeAtMost => .at_most,
        else => .undefined,
    };
}

fn toYogaFlexDirection(direction: FlexDirection) yoga_c.YGFlexDirection {
    return switch (direction) {
        .row => yoga_c.YGFlexDirectionRow,
        .column => yoga_c.YGFlexDirectionColumn,
        .row_reverse => yoga_c.YGFlexDirectionRowReverse,
        .column_reverse => yoga_c.YGFlexDirectionColumnReverse,
    };
}

fn toYogaJustify(justify: JustifyContent) yoga_c.YGJustify {
    return switch (justify) {
        .flex_start => yoga_c.YGJustifyFlexStart,
        .center => yoga_c.YGJustifyCenter,
        .flex_end => yoga_c.YGJustifyFlexEnd,
        .space_between => yoga_c.YGJustifySpaceBetween,
        .space_around => yoga_c.YGJustifySpaceAround,
        .space_evenly => yoga_c.YGJustifySpaceEvenly,
    };
}

fn toYogaAlign(alignment: Align) yoga_c.YGAlign {
    return switch (alignment) {
        .auto => yoga_c.YGAlignAuto,
        .flex_start => yoga_c.YGAlignFlexStart,
        .center => yoga_c.YGAlignCenter,
        .flex_end => yoga_c.YGAlignFlexEnd,
        .stretch => yoga_c.YGAlignStretch,
        .baseline => yoga_c.YGAlignBaseline,
        .space_between => yoga_c.YGAlignSpaceBetween,
        .space_around => yoga_c.YGAlignSpaceAround,
        .space_evenly => yoga_c.YGAlignSpaceEvenly,
    };
}

fn toYogaPositionType(position_type: PositionType) yoga_c.YGPositionType {
    return switch (position_type) {
        .relative => yoga_c.YGPositionTypeRelative,
        .absolute => yoga_c.YGPositionTypeAbsolute,
    };
}

fn toYogaDisplay(display: Display) yoga_c.YGDisplay {
    return switch (display) {
        .flex => yoga_c.YGDisplayFlex,
        .none => yoga_c.YGDisplayNone,
    };
}

fn toYogaOverflow(overflow: Overflow) yoga_c.YGOverflow {
    return switch (overflow) {
        .visible => yoga_c.YGOverflowVisible,
        .hidden => yoga_c.YGOverflowHidden,
        .scroll => yoga_c.YGOverflowScroll,
    };
}

fn toYogaEdge(edge: Edge) yoga_c.YGEdge {
    return switch (edge) {
        .left => yoga_c.YGEdgeLeft,
        .top => yoga_c.YGEdgeTop,
        .right => yoga_c.YGEdgeRight,
        .bottom => yoga_c.YGEdgeBottom,
        .start => yoga_c.YGEdgeStart,
        .end => yoga_c.YGEdgeEnd,
        .horizontal => yoga_c.YGEdgeHorizontal,
        .vertical => yoga_c.YGEdgeVertical,
        .all => yoga_c.YGEdgeAll,
    };
}

fn toYogaGutter(gutter: Gutter) yoga_c.YGGutter {
    return switch (gutter) {
        .column => yoga_c.YGGutterColumn,
        .row => yoga_c.YGGutterRow,
        .all => yoga_c.YGGutterAll,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "row flexGrow splits width evenly" {
    var engine = LayoutEngine.init();
    defer engine.deinit();

    var root = engine.newNode();
    defer root.freeRecursive();
    root.setFlexDirection(.row);
    root.setWidth(.{ .points = 200 });
    root.setHeight(.{ .points = 100 });

    var child_a = engine.newNode();
    var child_b = engine.newNode();
    root.addChild(&child_a);
    root.addChild(&child_b);
    child_a.setFlexGrow(1);
    child_b.setFlexGrow(1);

    engine.computeLayout(&root, 200, 100);

    const bounds_a = child_a.layoutBounds();
    const bounds_b = child_b.layoutBounds();
    try std.testing.expectEqual(@as(Pixels, 100), bounds_a.size.width);
    try std.testing.expectEqual(@as(Pixels, 100), bounds_a.size.height);
    try std.testing.expectEqual(@as(Pixels, 100), bounds_b.size.width);
    try std.testing.expectEqual(@as(Pixels, 100), bounds_b.size.height);
}

test "padding insets child layout bounds" {
    var engine = LayoutEngine.init();
    defer engine.deinit();

    var root = engine.newNode();
    defer root.freeRecursive();
    root.setWidth(.{ .points = 100 });
    root.setHeight(.{ .points = 100 });
    root.setPaddingAll(10);

    var child = engine.newNode();
    root.addChild(&child);
    child.setFlexGrow(1);

    engine.computeLayout(&root, 100, 100);

    const bounds = child.layoutBounds();
    try std.testing.expectEqual(@as(Pixels, 10), bounds.origin.x);
    try std.testing.expectEqual(@as(Pixels, 10), bounds.origin.y);
    try std.testing.expectEqual(@as(Pixels, 80), bounds.size.width);
    try std.testing.expectEqual(@as(Pixels, 80), bounds.size.height);
}

test "column gap offsets second child" {
    var engine = LayoutEngine.init();
    defer engine.deinit();

    var root = engine.newNode();
    defer root.freeRecursive();
    root.setFlexDirection(.column);
    root.setGapAll(10);

    var first = engine.newNode();
    var second = engine.newNode();
    root.addChild(&first);
    root.addChild(&second);
    first.setHeight(.{ .points = 40 });
    second.setHeight(.{ .points = 40 });

    engine.computeLayout(&root, null, null);

    try std.testing.expectEqual(@as(Pixels, 50), second.layoutBounds().origin.y);
}

test "absolute child positioned by insets" {
    var engine = LayoutEngine.init();
    defer engine.deinit();

    var root = engine.newNode();
    defer root.freeRecursive();
    root.setWidth(.{ .points = 100 });
    root.setHeight(.{ .points = 100 });

    var child = engine.newNode();
    root.addChild(&child);
    child.setPositionType(.absolute);
    child.setPosition(.left, .{ .points = 5 });
    child.setPosition(.top, .{ .points = 5 });
    child.setWidth(.{ .points = 20 });
    child.setHeight(.{ .points = 20 });

    engine.computeLayout(&root, 100, 100);

    const bounds = child.layoutBounds();
    try std.testing.expectEqual(@as(Pixels, 5), bounds.origin.x);
    try std.testing.expectEqual(@as(Pixels, 5), bounds.origin.y);
    try std.testing.expectEqual(@as(Pixels, 20), bounds.size.width);
    try std.testing.expectEqual(@as(Pixels, 20), bounds.size.height);
}

const MeasureTestCtx = struct {
    fn measure(_: *anyopaque, _: Pixels, _: MeasureMode, _: Pixels, _: MeasureMode) MeasureSize {
        return .{ .width = 37, .height = 13 };
    }
};

test "measure func sizes auto column leaf" {
    var engine = LayoutEngine.init();
    defer engine.deinit();

    var root = engine.newNode();
    defer root.freeRecursive();
    root.setFlexDirection(.column);

    var leaf = engine.newNode();
    root.addChild(&leaf);
    var ctx: u8 = 0;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try leaf.setMeasureFunc(arena_state.allocator(), &ctx, MeasureTestCtx.measure);

    engine.computeLayout(&root, null, null);

    const bounds = leaf.layoutBounds();
    try std.testing.expectEqual(@as(Pixels, 37), bounds.size.width);
    try std.testing.expectEqual(@as(Pixels, 13), bounds.size.height);
}
