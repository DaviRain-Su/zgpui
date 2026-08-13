//! wgpu device/surface management. Implemented in Phase 1;
//! scene rendering pipelines are added in Phase 2.
//!
//! Targets wgpu-native v29 (new webgpu.h API: `WGPUStringView` strings,
//! callback-info based async requests). Adapter/device requests are made
//! synchronous by using `WGPUCallbackMode_AllowProcessEvents` and pumping
//! `wgpuInstanceProcessEvents` until the callback fires.

const std = @import("std");
const c = @import("wgpu_c");
const platform = @import("../platform.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;

const log = std.log.scoped(.wgpu);

fn sv(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

fn svSlice(view: c.WGPUStringView) []const u8 {
    if (view.data == null or view.length == 0) return "";
    return view.data[0..view.length];
}

fn colorToWgpu(rgba: color.Rgba) c.WGPUColor {
    return .{ .r = rgba.r, .g = rgba.g, .b = rgba.b, .a = rgba.a };
}

// ---------------------------------------------------------------------------
// GpuContext
// ---------------------------------------------------------------------------

pub const GpuContext = struct {
    allocator: std.mem.Allocator,
    instance: c.WGPUInstance,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    pub fn init(allocator: std.mem.Allocator) !*GpuContext {
        const self = try allocator.create(GpuContext);
        errdefer allocator.destroy(self);

        const instance = c.wgpuCreateInstance(null) orelse return error.InstanceCreationFailed;
        errdefer c.wgpuInstanceRelease(instance);

        const adapter = try requestAdapter(instance);
        errdefer c.wgpuAdapterRelease(adapter);
        logAdapterInfo(adapter);

        const device = try requestDevice(instance, adapter);
        errdefer c.wgpuDeviceRelease(device);

        const queue = c.wgpuDeviceGetQueue(device) orelse return error.NoQueue;

        self.* = .{
            .allocator = allocator,
            .instance = instance,
            .adapter = adapter,
            .device = device,
            .queue = queue,
        };
        return self;
    }

    pub fn deinit(self: *GpuContext) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuInstanceRelease(self.instance);
        self.allocator.destroy(self);
    }

    /// Encodes and submits a render pass that clears `frame` to `clear_color`.
    pub fn encodeClearPass(self: *GpuContext, frame: *const Frame, clear_color: color.Rgba) void {
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &.{
            .label = sv("zgpui.clear-encoder"),
        });
        const attachment = c.WGPURenderPassColorAttachment{
            .view = frame.view,
            .depthSlice = std.math.maxInt(u32), // WGPU_DEPTH_SLICE_UNDEFINED
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = colorToWgpu(clear_color),
        };
        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &.{
            .label = sv("zgpui.clear-pass"),
            .colorAttachmentCount = 1,
            .colorAttachments = &attachment,
        });
        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);

        const command_buffer = c.wgpuCommandEncoderFinish(encoder, &.{
            .label = sv("zgpui.clear-commands"),
        });
        c.wgpuCommandEncoderRelease(encoder);
        c.wgpuQueueSubmit(self.queue, 1, &command_buffer);
        c.wgpuCommandBufferRelease(command_buffer);
    }

    // -- synchronous adapter/device acquisition ------------------------------

    const AdapterResult = struct {
        status: c.WGPURequestAdapterStatus = 0,
        adapter: c.WGPUAdapter = null,
        done: bool = false,
    };

    fn onAdapter(
        status: c.WGPURequestAdapterStatus,
        adapter: c.WGPUAdapter,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = userdata2;
        const result: *AdapterResult = @ptrCast(@alignCast(userdata1.?));
        if (status != c.WGPURequestAdapterStatus_Success) {
            log.err("adapter request failed (status {d}): {s}", .{ status, svSlice(message) });
        }
        result.status = status;
        result.adapter = adapter;
        result.done = true;
    }

    fn requestAdapter(instance: c.WGPUInstance) !c.WGPUAdapter {
        var result = AdapterResult{};
        const options = c.WGPURequestAdapterOptions{
            .powerPreference = c.WGPUPowerPreference_HighPerformance,
        };
        _ = c.wgpuInstanceRequestAdapter(instance, &options, .{
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = onAdapter,
            .userdata1 = &result,
        });
        while (!result.done) c.wgpuInstanceProcessEvents(instance);
        if (result.status != c.WGPURequestAdapterStatus_Success or result.adapter == null) {
            return error.AdapterRequestFailed;
        }
        return result.adapter;
    }

    const DeviceResult = struct {
        status: c.WGPURequestDeviceStatus = 0,
        device: c.WGPUDevice = null,
        done: bool = false,
    };

    fn onDevice(
        status: c.WGPURequestDeviceStatus,
        device: c.WGPUDevice,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = userdata2;
        const result: *DeviceResult = @ptrCast(@alignCast(userdata1.?));
        if (status != c.WGPURequestDeviceStatus_Success) {
            log.err("device request failed (status {d}): {s}", .{ status, svSlice(message) });
        }
        result.status = status;
        result.device = device;
        result.done = true;
    }

    fn onUncapturedError(
        device: [*c]const c.WGPUDevice,
        error_type: c.WGPUErrorType,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = device;
        _ = userdata1;
        _ = userdata2;
        log.err("uncaptured device error (type {d}): {s}", .{ error_type, svSlice(message) });
    }

    fn onDeviceLost(
        device: [*c]const c.WGPUDevice,
        reason: c.WGPUDeviceLostReason,
        message: c.WGPUStringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void {
        _ = device;
        _ = userdata1;
        _ = userdata2;
        log.warn("device lost (reason {d}): {s}", .{ reason, svSlice(message) });
    }

    fn requestDevice(instance: c.WGPUInstance, adapter: c.WGPUAdapter) !c.WGPUDevice {
        var result = DeviceResult{};
        const descriptor = c.WGPUDeviceDescriptor{
            .label = sv("zgpui.device"),
            .deviceLostCallbackInfo = .{
                .mode = c.WGPUCallbackMode_AllowSpontaneous,
                .callback = onDeviceLost,
            },
            .uncapturedErrorCallbackInfo = .{
                .callback = onUncapturedError,
            },
        };
        _ = c.wgpuAdapterRequestDevice(adapter, &descriptor, .{
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = onDevice,
            .userdata1 = &result,
        });
        while (!result.done) c.wgpuInstanceProcessEvents(instance);
        if (result.status != c.WGPURequestDeviceStatus_Success or result.device == null) {
            return error.DeviceRequestFailed;
        }
        return result.device;
    }

    fn logAdapterInfo(adapter: c.WGPUAdapter) void {
        var info = c.WGPUAdapterInfo{};
        if (c.wgpuAdapterGetInfo(adapter, &info) != c.WGPUStatus_Success) return;
        defer c.wgpuAdapterInfoFreeMembers(info);
        log.info("adapter: {s} ({s}, backend {d})", .{
            svSlice(info.device),
            svSlice(info.description),
            info.backendType,
        });
    }
};

// ---------------------------------------------------------------------------
// WindowSurface
// ---------------------------------------------------------------------------

/// One acquired swapchain image; valid between `beginFrame` and `endFrame`.
pub const Frame = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
};

pub const WindowSurface = struct {
    ctx: *GpuContext,
    surface: c.WGPUSurface,
    format: c.WGPUTextureFormat,
    alpha_mode: c.WGPUCompositeAlphaMode,
    size: Size(DevicePixels),

    pub fn init(
        ctx: *GpuContext,
        native: platform.NativeSurface,
        size: Size(DevicePixels),
    ) !WindowSurface {
        const surface = switch (native) {
            .metal_layer => |layer| blk: {
                var source = c.WGPUSurfaceSourceMetalLayer{
                    .chain = .{ .sType = c.WGPUSType_SurfaceSourceMetalLayer },
                    .layer = layer,
                };
                const descriptor = c.WGPUSurfaceDescriptor{
                    .nextInChain = &source.chain,
                    .label = sv("zgpui.window-surface"),
                };
                break :blk c.wgpuInstanceCreateSurface(ctx.instance, &descriptor) orelse
                    return error.SurfaceCreationFailed;
            },
            .xlib_window => |x| blk: {
                var source = c.WGPUSurfaceSourceXlibWindow{
                    .chain = .{ .sType = c.WGPUSType_SurfaceSourceXlibWindow },
                    .display = x.display,
                    .window = x.window,
                };
                const descriptor = c.WGPUSurfaceDescriptor{
                    .nextInChain = &source.chain,
                    .label = sv("zgpui.window-surface"),
                };
                break :blk c.wgpuInstanceCreateSurface(ctx.instance, &descriptor) orelse
                    return error.SurfaceCreationFailed;
            },
            .win32_hwnd => |w| blk: {
                var source = c.WGPUSurfaceSourceWindowsHWND{
                    .chain = .{ .sType = c.WGPUSType_SurfaceSourceWindowsHWND },
                    .hinstance = w.hinstance,
                    .hwnd = w.hwnd,
                };
                const descriptor = c.WGPUSurfaceDescriptor{
                    .nextInChain = &source.chain,
                    .label = sv("zgpui.window-surface"),
                };
                break :blk c.wgpuInstanceCreateSurface(ctx.instance, &descriptor) orelse
                    return error.SurfaceCreationFailed;
            },
        };
        errdefer c.wgpuSurfaceRelease(surface);

        var caps = c.WGPUSurfaceCapabilities{};
        if (c.wgpuSurfaceGetCapabilities(surface, ctx.adapter, &caps) != c.WGPUStatus_Success) {
            return error.SurfaceCapabilitiesFailed;
        }
        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);
        if (caps.formatCount == 0) return error.NoSurfaceFormat;

        // caps.formats is sorted by preference; take the first, but prefer
        // BGRA8Unorm (the canonical macOS swapchain format) when offered.
        var format = caps.formats[0];
        for (caps.formats[0..caps.formatCount]) |candidate| {
            if (candidate == c.WGPUTextureFormat_BGRA8Unorm) {
                format = candidate;
                break;
            }
        }
        var alpha_mode: c.WGPUCompositeAlphaMode = @intCast(c.WGPUCompositeAlphaMode_Auto);
        if (caps.alphaModeCount > 0) alpha_mode = caps.alphaModes[0];

        var self = WindowSurface{
            .ctx = ctx,
            .surface = surface,
            .format = format,
            .alpha_mode = alpha_mode,
            .size = size,
        };
        self.configure();
        log.info("surface configured: {d}x{d}, format {d}", .{
            size.width, size.height, format,
        });
        return self;
    }

    pub fn deinit(self: *WindowSurface) void {
        c.wgpuSurfaceUnconfigure(self.surface);
        c.wgpuSurfaceRelease(self.surface);
        self.* = undefined;
    }

    /// Reconfigures the surface for a new framebuffer size (device pixels).
    pub fn resize(self: *WindowSurface, size: Size(DevicePixels)) void {
        if (size.width == self.size.width and size.height == self.size.height) return;
        self.size = size;
        self.configure();
    }

    fn configure(self: *WindowSurface) void {
        const config = c.WGPUSurfaceConfiguration{
            .device = self.ctx.device,
            .format = self.format,
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .width = @intCast(@max(self.size.width, 1)),
            .height = @intCast(@max(self.size.height, 1)),
            .alphaMode = self.alpha_mode,
            .presentMode = c.WGPUPresentMode_Fifo,
        };
        c.wgpuSurfaceConfigure(self.surface, &config);
    }

    /// Acquires the next surface texture and creates a render-target view.
    /// Outdated/Lost/Timeout surfaces are reconfigured and retried once.
    /// Returns `error.SurfaceUnavailable` for frames that should be skipped
    /// (e.g. occluded window) — the caller should continue its loop.
    pub fn beginFrame(self: *WindowSurface) !Frame {
        var attempt: u2 = 0;
        while (attempt < 2) : (attempt += 1) {
            var surface_texture = c.WGPUSurfaceTexture{};
            c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
            switch (surface_texture.status) {
                c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal,
                c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal,
                => {
                    const texture = surface_texture.texture orelse return error.NoSurfaceTexture;
                    const view = c.wgpuTextureCreateView(texture, null) orelse {
                        c.wgpuTextureRelease(texture);
                        return error.TextureViewCreationFailed;
                    };
                    return .{ .texture = texture, .view = view };
                },
                c.WGPUSurfaceGetCurrentTextureStatus_Timeout,
                c.WGPUSurfaceGetCurrentTextureStatus_Outdated,
                c.WGPUSurfaceGetCurrentTextureStatus_Lost,
                => {
                    if (surface_texture.texture) |texture| c.wgpuTextureRelease(texture);
                    self.configure();
                    continue;
                },
                // wgpu-native extension: window is fully occluded; skip frame.
                c.WGPUSurfaceGetCurrentTextureStatus_Occluded => {
                    if (surface_texture.texture) |texture| c.wgpuTextureRelease(texture);
                    return error.SurfaceUnavailable;
                },
                else => {
                    log.err("surface texture acquisition failed (status {d})", .{surface_texture.status});
                    return error.SurfaceError;
                },
            }
        }
        return error.SurfaceUnavailable;
    }

    /// Presents the frame and releases its resources.
    pub fn endFrame(self: *WindowSurface, frame: *Frame) void {
        const status = c.wgpuSurfacePresent(self.surface);
        if (status != c.WGPUStatus_Success) {
            log.warn("present failed (status {d})", .{status});
        }
        c.wgpuTextureViewRelease(frame.view);
        c.wgpuTextureRelease(frame.texture);
        frame.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Tests (logic only — no GPU access)
// ---------------------------------------------------------------------------

test "color conversion widens to f64" {
    const rgba = color.Rgba.init(0.25, 0.5, 0.75, 1.0);
    const wgpu_color = colorToWgpu(rgba);
    try std.testing.expectEqual(@as(f64, 0.25), wgpu_color.r);
    try std.testing.expectEqual(@as(f64, 0.5), wgpu_color.g);
    try std.testing.expectEqual(@as(f64, 0.75), wgpu_color.b);
    try std.testing.expectEqual(@as(f64, 1.0), wgpu_color.a);
}

test "string view round trip" {
    const view = sv("zgpui");
    try std.testing.expectEqual(@as(usize, 5), view.length);
    try std.testing.expectEqualStrings("zgpui", svSlice(view));

    const empty = c.WGPUStringView{};
    try std.testing.expectEqualStrings("", svSlice(empty));
}
