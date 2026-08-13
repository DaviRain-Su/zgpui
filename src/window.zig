//! Window: the integration layer tying together the platform window, GPU
//! surface, scene renderer, element system and app state model.
//!
//! Frame flow per render:
//!   build elements (frame arena) → flex layout → prepaint (hitboxes/focus)
//!   → paint (scene primitives) → upload glyph atlas → GPU render → present
//!
//! Input events arrive via the platform event handler, are dispatched
//! against the current frame's hitboxes, and mark the window dirty when
//! consumed (or when entity state notifies).

const std = @import("std");
const c = @import("wgpu_c");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const platform_mod = @import("platform.zig");
const layout = @import("layout/layout.zig");
const element = @import("element.zig");
const a11y_mod = @import("a11y.zig");
const scene_mod = @import("scene.zig");
const app_mod = @import("app.zig");
const gpu = @import("renderer/gpu.zig");
const scene_renderer_mod = @import("renderer/scene_renderer.zig");
const text_element = @import("elements/text.zig");
const overlay_mod = @import("overlay.zig");
const clipboard_mod = @import("clipboard.zig");
const dirty_mod = @import("dirty.zig");
const animation_mod = @import("animation.zig");
const hotkey_mod = @import("hotkey.zig");
const debug_hud_mod = @import("debug_hud.zig");
const profile_mod = @import("profile.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Size = geometry.Size;
const Rgba = color.Rgba;

const log = std.log.scoped(.window);

pub const RenderFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, window: *Window) anyerror!element.Element;

pub const Window = struct {
    gpa: std.mem.Allocator,
    app: *app_mod.App,
    platform: platform_mod.Platform,
    platform_window: platform_mod.PlatformWindow,
    gpu_ctx: *gpu.GpuContext,
    surface: gpu.WindowSurface,
    renderer: scene_renderer_mod.SceneRenderer,

    engine: layout.LayoutEngine,
    arena_state: std.heap.ArenaAllocator,
    frame_state: element.FrameState,
    input: element.InputState,
    scene: scene_mod.Scene,
    overlays: overlay_mod.OverlayStack,
    hotkeys: hotkey_mod.HotkeyRouter = .{},
    root_node: ?*layout.Node = null,

    /// Optional text resources; set with `setTextResources` to enable text
    /// elements (atlas uploads happen automatically).
    text_resources: ?*text_element.TextResources = null,

    render_ctx: ?*anyopaque = null,
    render_fn: ?RenderFn = null,
    background: Rgba = Rgba.white,
    dirty: dirty_mod.DirtyTracker = .{},
    /// When true, partial dirty regions use Load + scissor instead of full Clear.
    partial_present: bool = false,
    needs_render: bool = true,
    anim_clock: animation_mod.AnimationClock = .{},
    timeline: animation_mod.Timeline = animation_mod.Timeline.init(),

    /// When true, draws an on-screen stats panel after the main scene each frame.
    /// Toggle at runtime, e.g. `window.debug_hud = true`, or bind F3 in your keymap.
    debug_hud: bool = false,
    /// Exponential moving average of measured frame time (ms).
    avg_frame_ms: f32 = 0,
    /// Most recent measured frame time (ms).
    last_frame_ms: f32 = 0,
    /// Set when this frame was scheduled due to entity notification.
    frame_entity_notify: bool = false,
    profiler: profile_mod.Profiler = .{},

    pub fn init(
        gpa: std.mem.Allocator,
        app: *app_mod.App,
        platform: platform_mod.Platform,
        gpu_ctx: *gpu.GpuContext,
        options: platform_mod.WindowOptions,
    ) !*Window {
        const platform_window = try platform.openWindow(options);
        errdefer platform_window.deinit();

        var surface = try gpu.WindowSurface.init(
            gpu_ctx,
            platform_window.nativeSurface(),
            platform_window.framebufferSize(),
        );
        errdefer surface.deinit();

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .app = app,
            .platform = platform,
            .platform_window = platform_window,
            .gpu_ctx = gpu_ctx,
            .surface = surface,
            .renderer = scene_renderer_mod.SceneRenderer.init(gpu_ctx.device, gpu_ctx.queue, surface.format),
            .engine = layout.LayoutEngine.init(),
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .frame_state = element.FrameState.init(gpa),
            .input = .{},
            .scene = scene_mod.Scene.init(gpa),
            .overlays = overlay_mod.OverlayStack.init(gpa),
        };

        self.platform_window.setEventHandler(.{ .ctx = self, .func = onWindowEvent });
        app.clipboard_bridge = clipboard_mod.Clipboard.bridgeFromPlatform(&self.platform);
        return self;
    }

    pub fn deinit(self: *Window) void {
        if (self.root_node) |node| node.freeRecursive();
        self.overlays.deinit();
        self.scene.deinit();
        self.frame_state.deinit();
        self.arena_state.deinit();
        self.engine.deinit();
        self.renderer.deinit();
        self.surface.deinit();
        self.platform_window.deinit();
        self.gpa.destroy(self);
    }

    pub fn setRoot(self: *Window, ctx: ?*anyopaque, render_fn: RenderFn) void {
        self.render_ctx = ctx;
        self.render_fn = render_fn;
        self.markDirty();
    }

    pub fn setTextResources(self: *Window, resources: *text_element.TextResources) void {
        self.text_resources = resources;
        self.markDirty();
    }

    pub fn enableProfiler(self: *Window, enable: bool) void {
        self.profiler.enabled = enable;
        if (enable) self.profiler.beginFrame();
    }

    /// Mark the entire window dirty (entity notify, input, resize, etc.).
    pub fn markDirty(self: *Window) void {
        self.dirty.markFull();
    }

    /// Mark a logical-pixel region dirty when bounds are known.
    pub fn markDirtyBounds(self: *Window, bounds: Bounds(Pixels)) void {
        self.dirty.markBounds(bounds);
    }

    fn markHoverRegion(self: *Window, id: ?element.ElementId) void {
        const target = id orelse return;
        for (self.frame_state.hitboxes.items) |hitbox| {
            if (hitbox.id != null and hitbox.id.? == target) {
                self.markDirtyBounds(hitbox.bounds);
                return;
            }
        }
    }

    pub fn shouldClose(self: *Window) bool {
        return self.platform_window.shouldClose();
    }

    /// Render if input, resize, or entity notifications made the frame
    /// dirty. Call once per event-loop iteration.
    pub fn renderIfNeeded(self: *Window) !void {
        self.frame_entity_notify = self.app.needs_redraw;
        if (self.app.needs_redraw) {
            const region = self.app.takeDirtyRegion();
            switch (region) {
                .none, .full => self.markDirty(),
                .regional => |bounds| {
                    if (self.partial_present) {
                        self.markDirtyBounds(bounds);
                        if (!self.dirty.needsRedraw()) self.markDirty();
                    } else {
                        self.markDirty();
                    }
                },
            }
        }
        if (self.anim_clock.tick(&self.timeline)) {
            self.markDirty();
        }
        if (!self.dirty.needsRedraw() and !self.needs_render) {
            return;
        }
        try self.renderFrame();
    }

    pub fn renderFrame(self: *Window) !void {
        const hud_frame_start_ns = animation_mod.monotonicNowNs();
        const render_fn = self.render_fn orelse {
            self.dirty.clear();
            self.needs_render = false;
            return;
        };

        const profile_enabled = self.profiler.enabled;
        const profile_frame_start_ns: u128 = if (profile_enabled) profile_mod.nowNs() else 0;
        if (profile_enabled) self.profiler.beginFrame();

        // --- Build & layout (CPU) ---------------------------------------
        const root = root_blk: {
            var scope = self.profiler.scope(.build_layout);
            defer scope.end();

            if (self.root_node) |node| {
                node.freeRecursive();
                self.root_node = null;
            }
            self.overlays.discardBuiltLayers();
            _ = self.arena_state.reset(.retain_capacity);
            self.frame_state.clear();
            self.scene.clear();
            self.overlays.beginFrame();

            const arena = self.arena_state.allocator();
            const built_root = try render_fn(self.render_ctx, arena, self);

            const logical = self.platform_window.logicalSize();
            var layout_pass = element.LayoutPass{ .arena = arena, .engine = &self.engine };
            const root_node = try built_root.requestLayout(&layout_pass);
            self.root_node = root_node;
            self.engine.computeLayout(root_node, logical.width, logical.height);
            break :root_blk built_root;
        };

        const arena = self.arena_state.allocator();

        {
            var scope = self.profiler.scope(.prepaint);
            defer scope.end();

            var prepaint_pass = element.PrepaintPass{ .arena = arena, .frame = &self.frame_state };
            try root.prepaint(&prepaint_pass, .{});
        }

        var ime_position: Point(Pixels) = .{ .x = 0, .y = 0 };
        const paint_clip = dirty_mod.planPaintClip(self.partial_present, &self.dirty, 16);
        self.scene.paint_clip = paint_clip;
        {
            var scope = self.profiler.scope(.paint);
            defer scope.end();

            var paint_pass = element.PaintPass{
                .scene = &self.scene,
                .ime_position = &ime_position,
                .dirty_clip = paint_clip,
            };
            try root.paint(&paint_pass);
        }
        self.platform_window.setImePosition(ime_position);

        var hover_changed = false;
        {
            var scope = self.profiler.scope(.overlays);
            defer scope.end();

            const logical = self.platform_window.logicalSize();
            try self.overlays.build(arena, &self.engine, logical);
            try self.overlays.paint(&self.scene);

            if (self.debug_hud) {
                const stats = debug_hud_mod.collectStats(
                    &self.dirty,
                    self.overlays.layers.items.len,
                    self.frame_entity_notify,
                    self.hudProfilerView(),
                    self.avg_frame_ms,
                    self.anim_clock.last_dt_ms,
                );
                try debug_hud_mod.paint(&self.scene, arena, stats, self.text_resources);
            }

            var accessibility_nodes: std.ArrayList(a11y_mod.Node) = .empty;
            try self.overlays.appendAccessibilityNodes(
                self.frame_state.a11y.items,
                &accessibility_nodes,
                arena,
            );
            self.platform_window.syncAccessibility(
                accessibility_nodes.items,
                self.platform_window.scaleFactor(),
                self.input.focused,
            );

            const prev_hover = self.input.hovered;
            hover_changed = self.input.updateHover(&self.frame_state);
            if (hover_changed) {
                if (self.partial_present) {
                    self.markHoverRegion(prev_hover);
                    self.markHoverRegion(self.input.hovered);
                    if (!self.dirty.needsRedraw()) self.markDirty();
                } else {
                    self.markDirty();
                }
            }
        }

        {
            var scope = self.profiler.scope(.atlas);
            defer scope.end();

            if (self.text_resources) |resources| {
                if (resources.atlas.dirty) {
                    self.renderer.updateAtlas(
                        resources.atlas.data,
                        @intCast(resources.atlas.size.width),
                        @intCast(resources.atlas.size.height),
                    );
                    resources.atlas.dirty = false;
                }
            }
        }

        // --- GPU render ---------------------------------------------------
        {
            var scope = self.profiler.scope(.gpu);
            defer scope.end();

            self.surface.resize(self.platform_window.framebufferSize());

            var frame = self.surface.beginFrame() catch |err| switch (err) {
                error.SurfaceUnavailable => return, // occluded; skip frame
                else => return err,
            };
            defer self.surface.endFrame(&frame);

            const fb_size = self.platform_window.framebufferSize();
            const scale = self.platform_window.scaleFactor();
            const present_plan = dirty_mod.planPartialPresent(
                self.partial_present,
                &self.dirty,
                fb_size,
                scale,
            );

            const encoder = c.wgpuDeviceCreateCommandEncoder(self.gpu_ctx.device, &.{
                .label = .{ .data = "zgpui.frame", .length = 11 },
            });
            const attachment = c.WGPURenderPassColorAttachment{
                .view = frame.view,
                .depthSlice = std.math.maxInt(u32), // WGPU_DEPTH_SLICE_UNDEFINED
                .loadOp = if (present_plan.use_load) c.WGPULoadOp_Load else c.WGPULoadOp_Clear,
                .storeOp = c.WGPUStoreOp_Store,
                .clearValue = .{
                    .r = self.background.r,
                    .g = self.background.g,
                    .b = self.background.b,
                    .a = self.background.a,
                },
            };
            const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &.{
                .label = .{ .data = "zgpui.pass", .length = 10 },
                .colorAttachmentCount = 1,
                .colorAttachments = &attachment,
            });

            if (present_plan.scissor) |scissor| {
                c.wgpuRenderPassEncoderSetScissorRect(
                    pass,
                    scissor.x,
                    scissor.y,
                    scissor.width,
                    scissor.height,
                );
            }

            self.renderer.render(
                pass,
                &self.scene,
                fb_size,
                scale,
                present_plan.scissor,
            );

            c.wgpuRenderPassEncoderEnd(pass);
            c.wgpuRenderPassEncoderRelease(pass);

            const commands = c.wgpuCommandEncoderFinish(encoder, &.{
                .label = .{ .data = "zgpui.commands", .length = 14 },
            });
            c.wgpuCommandEncoderRelease(encoder);
            c.wgpuQueueSubmit(self.gpu_ctx.queue, 1, &commands);
            c.wgpuCommandBufferRelease(commands);
        }

        if (profile_enabled) {
            const total_ns = @as(u64, @intCast(profile_mod.nowNs() - profile_frame_start_ns));
            self.profiler.recordTotal(total_ns);
        }

        if (hover_changed) {
            self.needs_render = true;
        } else {
            self.dirty.clear();
            self.needs_render = false;
        }

        const frame_end_ns = animation_mod.monotonicNowNs();
        const measured_ms =
            @as(f32, @floatFromInt(frame_end_ns - hud_frame_start_ns)) /
            @as(f32, @floatFromInt(std.time.ns_per_ms));
        self.last_frame_ms = measured_ms;
        if (self.avg_frame_ms <= 0) {
            self.avg_frame_ms = measured_ms;
        } else {
            self.avg_frame_ms = self.avg_frame_ms * 0.9 + measured_ms * 0.1;
        }
    }

    fn hudProfilerView(self: *Window) ?debug_hud_mod.ProfilerView {
        if (!self.profiler.enabled or self.profiler.ring_filled == 0) return null;
        return .{ .avg_total_ms = @floatCast(self.profiler.avgTotalMs()) };
    }

    fn onWindowEvent(ctx: ?*anyopaque, event: platform_mod.WindowEvent) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .input => |input_event| {
                const prev_hover = self.input.hovered;
                const overlay_handled = self.overlays.dispatch(&self.input, input_event);
                var consumed = overlay_handled;
                if (!consumed and input_event == .key_down) {
                    consumed = self.hotkeys.dispatch(input_event.key_down);
                }
                if (!consumed) {
                    consumed = self.input.dispatch(&self.frame_state, input_event);
                }

                const is_mouse_moved = input_event == .mouse_moved;
                const is_mouse_exited = input_event == .mouse_exited;
                const kind = dirty_mod.classifyInputDirty(
                    self.partial_present,
                    is_mouse_moved,
                    is_mouse_exited,
                    overlay_handled,
                    consumed,
                );
                switch (kind) {
                    .none => {},
                    .regional_hover => {
                        self.markHoverRegion(prev_hover);
                        self.markHoverRegion(self.input.hovered);
                        if (!self.dirty.needsRedraw()) self.markDirty();
                    },
                    .full => self.markDirty(),
                }
            },
            .resized, .framebuffer_resized, .scale_factor_changed => self.markDirty(),
            .focus_changed => |focused| {
                if (focused) self.app.pullClipboardFromOs();
            },
            .a11y_press => |id| {
                if (self.overlays.performAccessibilityPress(&self.input, &self.frame_state, id)) {
                    self.markDirty();
                }
            },
            .a11y_adjust => |adj| {
                if (self.overlays.performAccessibilityAdjust(
                    &self.input,
                    &self.frame_state,
                    adj.id,
                    adj.increment,
                )) {
                    self.markDirty();
                }
            },
            .a11y_set_value => |set| {
                if (self.overlays.performAccessibilitySetValue(
                    &self.input,
                    &self.frame_state,
                    set.id,
                    set.text,
                )) {
                    self.markDirty();
                }
            },
            .a11y_replace_selected_text => |rep| {
                if (self.overlays.performAccessibilityReplaceSelectedText(
                    &self.input,
                    &self.frame_state,
                    rep.id,
                    rep.text,
                )) {
                    self.markDirty();
                }
            },
            .a11y_set_selected_range => |range| {
                if (self.overlays.performAccessibilitySetSelectedRange(
                    &self.input,
                    &self.frame_state,
                    range.id,
                    range.start,
                    range.end,
                )) {
                    self.markDirty();
                }
            },
            .close_requested => {},
        }
    }
};
