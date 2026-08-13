//! SceneRenderer: draws `scene.Scene` primitives with wgpu, batching by
//! primitive kind while preserving draw order (Phase 2).
//!
//! Pipelines: quads and shadows are analytic SDF shaders; monochrome
//! sprites sample the R8 glyph atlas; polychrome sprites sample an RGBA
//! texture. All blending is premultiplied alpha.

const std = @import("std");
const c = @import("wgpu_c");
const scene_mod = @import("../scene.zig");
const geometry = @import("../geometry.zig");
const dirty_mod = @import("../dirty.zig");

const Scene = scene_mod.Scene;

fn stringView(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

const common_src = @embedFile("shaders/common.wgsl");
const quad_src = common_src ++ @embedFile("shaders/quad.wgsl");
const shadow_src = common_src ++ @embedFile("shaders/shadow.wgsl");
const mono_src = common_src ++ @embedFile("shaders/mono_sprite.wgsl");
const poly_src = common_src ++ @embedFile("shaders/poly_sprite.wgsl");
const path_src = common_src ++ @embedFile("shaders/path.wgsl");

const Globals = extern struct {
    viewport_w: f32,
    viewport_h: f32,
    scale: f32,
    _pad: f32 = 0,
};

/// A growable GPU storage buffer plus the bind group that exposes it
/// together with the globals uniform.
const PrimitiveBuffer = struct {
    buffer: c.WGPUBuffer = null,
    capacity: u64 = 0,
    bind_group: c.WGPUBindGroup = null,

    fn deinit(self: *PrimitiveBuffer) void {
        if (self.bind_group) |bg| c.wgpuBindGroupRelease(bg);
        if (self.buffer) |buf| c.wgpuBufferRelease(buf);
        self.* = .{};
    }

    /// Upload `bytes`, growing the buffer (and recreating the bind group)
    /// if needed. Safe to call with empty input (no-op).
    fn upload(
        self: *PrimitiveBuffer,
        renderer: *SceneRenderer,
        label: []const u8,
        bytes: []const u8,
    ) void {
        if (bytes.len == 0) return;

        if (self.buffer == null or self.capacity < bytes.len) {
            if (self.bind_group) |bg| c.wgpuBindGroupRelease(bg);
            if (self.buffer) |buf| c.wgpuBufferRelease(buf);

            var capacity: u64 = @max(self.capacity * 2, 4096);
            while (capacity < bytes.len) capacity *= 2;

            self.buffer = c.wgpuDeviceCreateBuffer(renderer.device, &.{
                .label = stringView(label),
                .usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
                .size = capacity,
            });
            self.capacity = capacity;

            const entries = [_]c.WGPUBindGroupEntry{
                .{ .binding = 0, .buffer = renderer.globals_buffer, .size = @sizeOf(Globals) },
                .{ .binding = 1, .buffer = self.buffer, .size = capacity },
            };
            self.bind_group = c.wgpuDeviceCreateBindGroup(renderer.device, &.{
                .label = stringView(label),
                .layout = renderer.primitive_bgl,
                .entryCount = entries.len,
                .entries = &entries,
            });
        }

        c.wgpuQueueWriteBuffer(renderer.queue, self.buffer, 0, bytes.ptr, bytes.len);
    }
};

pub const SceneRenderer = struct {
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    globals_buffer: c.WGPUBuffer,
    primitive_bgl: c.WGPUBindGroupLayout,
    texture_bgl: c.WGPUBindGroupLayout,

    quad_pipeline: c.WGPURenderPipeline,
    shadow_pipeline: c.WGPURenderPipeline,
    mono_pipeline: c.WGPURenderPipeline,
    poly_pipeline: c.WGPURenderPipeline,
    path_pipeline: c.WGPURenderPipeline,

    quads: PrimitiveBuffer = .{},
    shadows: PrimitiveBuffer = .{},
    mono_sprites: PrimitiveBuffer = .{},
    poly_sprites: PrimitiveBuffer = .{},

    path_bgl: c.WGPUBindGroupLayout,
    path_bind_group: c.WGPUBindGroup,
    path_vertex_buffer: c.WGPUBuffer = null,
    path_vertex_capacity: u64 = 0,

    sampler: c.WGPUSampler,

    /// R8 glyph atlas texture; starts as a 1x1 placeholder until
    /// `updateAtlas` uploads real data.
    atlas_texture: c.WGPUTexture,
    atlas_view: c.WGPUTextureView,
    atlas_size: geometry.Size(u32),
    atlas_bind_group: c.WGPUBindGroup,

    /// RGBA texture used by polychrome sprites (single texture for now;
    /// a real image atlas comes later).
    image_texture: c.WGPUTexture,
    image_view: c.WGPUTextureView,
    image_bind_group: c.WGPUBindGroup,

    pub fn init(
        device: c.WGPUDevice,
        queue: c.WGPUQueue,
        target_format: c.WGPUTextureFormat,
    ) SceneRenderer {
        const globals_buffer = c.wgpuDeviceCreateBuffer(device, &.{
            .label = stringView("zgpui globals"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = @sizeOf(Globals),
        });

        // Bind group layout 0: globals uniform + read-only primitive storage.
        const primitive_entries = [_]c.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
                .buffer = .{ .type = c.WGPUBufferBindingType_Uniform },
            },
            .{
                .binding = 1,
                .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
                .buffer = .{ .type = c.WGPUBufferBindingType_ReadOnlyStorage },
            },
        };
        const primitive_bgl = c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = stringView("zgpui primitives"),
            .entryCount = primitive_entries.len,
            .entries = &primitive_entries,
        });

        // Bind group layout 1: texture + sampler (sprite pipelines).
        const texture_entries = [_]c.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
                .texture = .{
                    .sampleType = c.WGPUTextureSampleType_Float,
                    .viewDimension = c.WGPUTextureViewDimension_2D,
                },
            },
            .{
                .binding = 1,
                .visibility = c.WGPUShaderStage_Fragment,
                .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering },
            },
        };
        const texture_bgl = c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = stringView("zgpui textures"),
            .entryCount = texture_entries.len,
            .entries = &texture_entries,
        });

        const path_entries = [_]c.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
                .buffer = .{ .type = c.WGPUBufferBindingType_Uniform },
            },
        };
        const path_bgl = c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = stringView("zgpui path"),
            .entryCount = path_entries.len,
            .entries = &path_entries,
        });
        const path_bg_entries = [_]c.WGPUBindGroupEntry{
            .{ .binding = 0, .buffer = globals_buffer, .size = @sizeOf(Globals) },
        };
        const path_bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
            .label = stringView("zgpui path"),
            .layout = path_bgl,
            .entryCount = path_bg_entries.len,
            .entries = &path_bg_entries,
        });

        const sampler = c.wgpuDeviceCreateSampler(device, &.{
            .label = stringView("zgpui sampler"),
            .addressModeU = c.WGPUAddressMode_ClampToEdge,
            .addressModeV = c.WGPUAddressMode_ClampToEdge,
            .addressModeW = c.WGPUAddressMode_ClampToEdge,
            .magFilter = c.WGPUFilterMode_Linear,
            .minFilter = c.WGPUFilterMode_Linear,
            .mipmapFilter = c.WGPUMipmapFilterMode_Nearest,
            .lodMaxClamp = 32,
            .maxAnisotropy = 1,
        });

        var self = SceneRenderer{
            .device = device,
            .queue = queue,
            .globals_buffer = globals_buffer,
            .primitive_bgl = primitive_bgl,
            .texture_bgl = texture_bgl,
            .quad_pipeline = null,
            .shadow_pipeline = null,
            .mono_pipeline = null,
            .poly_pipeline = null,
            .path_pipeline = null,
            .path_bgl = path_bgl,
            .path_bind_group = path_bind_group,
            .sampler = sampler,
            .atlas_texture = null,
            .atlas_view = null,
            .atlas_size = .{ .width = 1, .height = 1 },
            .atlas_bind_group = null,
            .image_texture = null,
            .image_view = null,
            .image_bind_group = null,
        };

        self.quad_pipeline = self.createPipeline("zgpui quad", quad_src, "vs_quad", "fs_quad", false, target_format);
        self.shadow_pipeline = self.createPipeline("zgpui shadow", shadow_src, "vs_shadow", "fs_shadow", false, target_format);
        self.mono_pipeline = self.createPipeline("zgpui mono sprite", mono_src, "vs_mono_sprite", "fs_mono_sprite", true, target_format);
        self.poly_pipeline = self.createPipeline("zgpui poly sprite", poly_src, "vs_poly_sprite", "fs_poly_sprite", true, target_format);
        self.path_pipeline = self.createPathPipeline(target_format);

        // 1x1 placeholder textures so sprite bind groups are always valid.
        self.createAtlasTexture(1, 1);
        const white: [1]u8 = .{255};
        self.writeAtlas(&white, 1, 1);
        self.createImageTexture(1, 1);
        const white_rgba: [4]u8 = .{ 255, 255, 255, 255 };
        self.writeImage(&white_rgba, 1, 1);

        return self;
    }

    pub fn deinit(self: *SceneRenderer) void {
        self.quads.deinit();
        self.shadows.deinit();
        self.mono_sprites.deinit();
        self.poly_sprites.deinit();
        if (self.path_vertex_buffer) |buf| c.wgpuBufferRelease(buf);

        if (self.atlas_bind_group) |bg| c.wgpuBindGroupRelease(bg);
        if (self.atlas_view) |view| c.wgpuTextureViewRelease(view);
        if (self.atlas_texture) |tex| c.wgpuTextureRelease(tex);
        if (self.image_bind_group) |bg| c.wgpuBindGroupRelease(bg);
        if (self.image_view) |view| c.wgpuTextureViewRelease(view);
        if (self.image_texture) |tex| c.wgpuTextureRelease(tex);

        c.wgpuSamplerRelease(self.sampler);
        c.wgpuRenderPipelineRelease(self.quad_pipeline);
        c.wgpuRenderPipelineRelease(self.shadow_pipeline);
        c.wgpuRenderPipelineRelease(self.mono_pipeline);
        c.wgpuRenderPipelineRelease(self.poly_pipeline);
        c.wgpuRenderPipelineRelease(self.path_pipeline);
        c.wgpuBindGroupRelease(self.path_bind_group);
        c.wgpuBindGroupLayoutRelease(self.path_bgl);
        c.wgpuBindGroupLayoutRelease(self.primitive_bgl);
        c.wgpuBindGroupLayoutRelease(self.texture_bgl);
        c.wgpuBufferRelease(self.globals_buffer);
    }

    fn createPipeline(
        self: *SceneRenderer,
        label: []const u8,
        source: []const u8,
        vs_entry: []const u8,
        fs_entry: []const u8,
        with_texture: bool,
        target_format: c.WGPUTextureFormat,
    ) c.WGPURenderPipeline {
        var wgsl = c.WGPUShaderSourceWGSL{
            .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = stringView(source),
        };
        const module = c.wgpuDeviceCreateShaderModule(self.device, &.{
            .nextInChain = @ptrCast(&wgsl.chain),
            .label = stringView(label),
        });
        defer c.wgpuShaderModuleRelease(module);

        const bgls = [_]c.WGPUBindGroupLayout{ self.primitive_bgl, self.texture_bgl };
        const layout = c.wgpuDeviceCreatePipelineLayout(self.device, &.{
            .label = stringView(label),
            .bindGroupLayoutCount = if (with_texture) 2 else 1,
            .bindGroupLayouts = &bgls,
        });
        defer c.wgpuPipelineLayoutRelease(layout);

        // Premultiplied alpha blending.
        const blend = c.WGPUBlendState{
            .color = .{
                .operation = c.WGPUBlendOperation_Add,
                .srcFactor = c.WGPUBlendFactor_One,
                .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
            },
            .alpha = .{
                .operation = c.WGPUBlendOperation_Add,
                .srcFactor = c.WGPUBlendFactor_One,
                .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
            },
        };
        const target = c.WGPUColorTargetState{
            .format = target_format,
            .blend = &blend,
            .writeMask = c.WGPUColorWriteMask_All,
        };
        const fragment = c.WGPUFragmentState{
            .module = module,
            .entryPoint = stringView(fs_entry),
            .targetCount = 1,
            .targets = &target,
        };

        return c.wgpuDeviceCreateRenderPipeline(self.device, &.{
            .label = stringView(label),
            .layout = layout,
            .vertex = .{
                .module = module,
                .entryPoint = stringView(vs_entry),
            },
            .primitive = .{
                .topology = c.WGPUPrimitiveTopology_TriangleStrip,
                .frontFace = c.WGPUFrontFace_CCW,
                .cullMode = c.WGPUCullMode_None,
            },
            .multisample = .{
                .count = 1,
                .mask = 0xFFFF_FFFF,
            },
            .fragment = &fragment,
        });
    }

    fn createPathPipeline(self: *SceneRenderer, target_format: c.WGPUTextureFormat) c.WGPURenderPipeline {
        var wgsl = c.WGPUShaderSourceWGSL{
            .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = stringView(path_src),
        };
        const module = c.wgpuDeviceCreateShaderModule(self.device, &.{
            .nextInChain = @ptrCast(&wgsl.chain),
            .label = stringView("zgpui path"),
        });
        defer c.wgpuShaderModuleRelease(module);

        const layout = c.wgpuDeviceCreatePipelineLayout(self.device, &.{
            .label = stringView("zgpui path"),
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &[_]c.WGPUBindGroupLayout{self.path_bgl},
        });
        defer c.wgpuPipelineLayoutRelease(layout);

        const blend = c.WGPUBlendState{
            .color = .{
                .operation = c.WGPUBlendOperation_Add,
                .srcFactor = c.WGPUBlendFactor_One,
                .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
            },
            .alpha = .{
                .operation = c.WGPUBlendOperation_Add,
                .srcFactor = c.WGPUBlendFactor_One,
                .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
            },
        };
        const target = c.WGPUColorTargetState{
            .format = target_format,
            .blend = &blend,
            .writeMask = c.WGPUColorWriteMask_All,
        };
        const fragment = c.WGPUFragmentState{
            .module = module,
            .entryPoint = stringView("fs_path"),
            .targetCount = 1,
            .targets = &target,
        };

        const attributes = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 8, .shaderLocation = 1 },
        };
        const vertex_layout = c.WGPUVertexBufferLayout{
            .stepMode = c.WGPUVertexStepMode_Vertex,
            .arrayStride = @sizeOf(scene_mod.PathVertex),
            .attributeCount = attributes.len,
            .attributes = &attributes,
        };

        return c.wgpuDeviceCreateRenderPipeline(self.device, &.{
            .label = stringView("zgpui path"),
            .layout = layout,
            .vertex = .{
                .module = module,
                .entryPoint = stringView("vs_path"),
                .bufferCount = 1,
                .buffers = &vertex_layout,
            },
            .primitive = .{
                .topology = c.WGPUPrimitiveTopology_TriangleList,
                .frontFace = c.WGPUFrontFace_CCW,
                .cullMode = c.WGPUCullMode_None,
            },
            .multisample = .{
                .count = 1,
                .mask = 0xFFFF_FFFF,
            },
            .fragment = &fragment,
        });
    }

    // ------------------------------------------------------------------
    // Atlas / image textures
    // ------------------------------------------------------------------

    fn createAtlasTexture(self: *SceneRenderer, width: u32, height: u32) void {
        if (self.atlas_bind_group) |bg| c.wgpuBindGroupRelease(bg);
        if (self.atlas_view) |view| c.wgpuTextureViewRelease(view);
        if (self.atlas_texture) |tex| c.wgpuTextureRelease(tex);

        self.atlas_texture = c.wgpuDeviceCreateTexture(self.device, &.{
            .label = stringView("zgpui glyph atlas"),
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_R8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        self.atlas_view = c.wgpuTextureCreateView(self.atlas_texture, null);
        self.atlas_size = .{ .width = width, .height = height };

        const entries = [_]c.WGPUBindGroupEntry{
            .{ .binding = 0, .textureView = self.atlas_view },
            .{ .binding = 1, .sampler = self.sampler },
        };
        self.atlas_bind_group = c.wgpuDeviceCreateBindGroup(self.device, &.{
            .label = stringView("zgpui glyph atlas"),
            .layout = self.texture_bgl,
            .entryCount = entries.len,
            .entries = &entries,
        });
    }

    fn writeAtlas(self: *SceneRenderer, data: []const u8, width: u32, height: u32) void {
        c.wgpuQueueWriteTexture(
            self.queue,
            &.{ .texture = self.atlas_texture, .aspect = c.WGPUTextureAspect_All },
            data.ptr,
            data.len,
            &.{ .bytesPerRow = width, .rowsPerImage = height },
            &.{ .width = width, .height = height, .depthOrArrayLayers = 1 },
        );
    }

    /// Upload the CPU glyph atlas (single-channel alpha). Recreates the GPU
    /// texture if the size changed.
    pub fn updateAtlas(self: *SceneRenderer, data: []const u8, width: u32, height: u32) void {
        std.debug.assert(data.len == @as(usize, width) * height);
        if (self.atlas_size.width != width or self.atlas_size.height != height) {
            self.createAtlasTexture(width, height);
        }
        self.writeAtlas(data, width, height);
    }

    fn createImageTexture(self: *SceneRenderer, width: u32, height: u32) void {
        if (self.image_bind_group) |bg| c.wgpuBindGroupRelease(bg);
        if (self.image_view) |view| c.wgpuTextureViewRelease(view);
        if (self.image_texture) |tex| c.wgpuTextureRelease(tex);

        self.image_texture = c.wgpuDeviceCreateTexture(self.device, &.{
            .label = stringView("zgpui image"),
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        self.image_view = c.wgpuTextureCreateView(self.image_texture, null);

        const entries = [_]c.WGPUBindGroupEntry{
            .{ .binding = 0, .textureView = self.image_view },
            .{ .binding = 1, .sampler = self.sampler },
        };
        self.image_bind_group = c.wgpuDeviceCreateBindGroup(self.device, &.{
            .label = stringView("zgpui image"),
            .layout = self.texture_bgl,
            .entryCount = entries.len,
            .entries = &entries,
        });
    }

    /// Upload an RGBA8 image used by polychrome sprites.
    pub fn updateImage(self: *SceneRenderer, data: []const u8, width: u32, height: u32) void {
        std.debug.assert(data.len == @as(usize, width) * height * 4);
        self.createImageTexture(width, height);
        self.writeImage(data, width, height);
    }

    fn writeImage(self: *SceneRenderer, data: []const u8, width: u32, height: u32) void {
        c.wgpuQueueWriteTexture(
            self.queue,
            &.{ .texture = self.image_texture, .aspect = c.WGPUTextureAspect_All },
            data.ptr,
            data.len,
            &.{ .bytesPerRow = width * 4, .rowsPerImage = height },
            &.{ .width = width, .height = height, .depthOrArrayLayers = 1 },
        );
    }

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------

    /// Upload scene primitives and record draw calls into `pass`.
    /// `viewport` is the framebuffer size in device pixels; `scale` is the
    /// window scale factor. When `pass_scissor` is set (partial present), path
    /// draws restore that rect instead of the full viewport after clipping.
    pub fn render(
        self: *SceneRenderer,
        pass: c.WGPURenderPassEncoder,
        scene: *const Scene,
        viewport: geometry.Size(geometry.DevicePixels),
        scale: f32,
        pass_scissor: ?dirty_mod.ScissorRect,
    ) void {
        if (scene.isEmpty()) return;

        const globals = Globals{
            .viewport_w = @floatFromInt(viewport.width),
            .viewport_h = @floatFromInt(viewport.height),
            .scale = scale,
        };
        c.wgpuQueueWriteBuffer(self.queue, self.globals_buffer, 0, &globals, @sizeOf(Globals));

        self.quads.upload(self, "zgpui quads", std.mem.sliceAsBytes(scene.quads.items));
        self.shadows.upload(self, "zgpui shadows", std.mem.sliceAsBytes(scene.shadows.items));
        self.mono_sprites.upload(self, "zgpui mono sprites", std.mem.sliceAsBytes(scene.monochrome_sprites.items));
        self.poly_sprites.upload(self, "zgpui poly sprites", std.mem.sliceAsBytes(scene.polychrome_sprites.items));
        self.uploadPathVertices(scene.path_vertices.items);

        var it = scene.batches();
        while (it.next()) |batch| {
            switch (batch.kind) {
                .shadow => {
                    const count: u32 = @intCast(batch.end - batch.start);
                    const first: u32 = @intCast(batch.start);
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.shadow_pipeline);
                    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.shadows.bind_group, 0, null);
                    c.wgpuRenderPassEncoderDraw(pass, 4, count, 0, first);
                },
                .quad => {
                    const count: u32 = @intCast(batch.end - batch.start);
                    const first: u32 = @intCast(batch.start);
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.quad_pipeline);
                    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.quads.bind_group, 0, null);
                    c.wgpuRenderPassEncoderDraw(pass, 4, count, 0, first);
                },
                .monochrome_sprite => {
                    const count: u32 = @intCast(batch.end - batch.start);
                    const first: u32 = @intCast(batch.start);
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.mono_pipeline);
                    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.mono_sprites.bind_group, 0, null);
                    c.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.atlas_bind_group, 0, null);
                    c.wgpuRenderPassEncoderDraw(pass, 4, count, 0, first);
                },
                .polychrome_sprite => {
                    const count: u32 = @intCast(batch.end - batch.start);
                    const first: u32 = @intCast(batch.start);
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.poly_pipeline);
                    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.poly_sprites.bind_group, 0, null);
                    c.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.image_bind_group, 0, null);
                    c.wgpuRenderPassEncoderDraw(pass, 4, count, 0, first);
                },
                .path => {
                    if (self.path_vertex_buffer == null) continue;
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.path_pipeline);
                    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.path_bind_group, 0, null);
                    c.wgpuRenderPassEncoderSetVertexBuffer(
                        pass,
                        0,
                        self.path_vertex_buffer,
                        0,
                        self.path_vertex_capacity,
                    );
                    var range_i = batch.start;
                    while (range_i < batch.end) : (range_i += 1) {
                        const range = scene.path_ranges.items[range_i];
                        self.setScissor(pass, range.clip_bounds, viewport, scale);
                        c.wgpuRenderPassEncoderDraw(pass, range.count, 1, range.start, 0);
                    }
                    // Restore scissor to pass clip or full viewport.
                    self.resetScissor(pass, viewport, pass_scissor);
                },
            }
        }
    }

    fn resetScissor(
        self: *SceneRenderer,
        pass: c.WGPURenderPassEncoder,
        viewport: geometry.Size(geometry.DevicePixels),
        pass_scissor: ?dirty_mod.ScissorRect,
    ) void {
        _ = self;
        if (pass_scissor) |s| {
            c.wgpuRenderPassEncoderSetScissorRect(pass, s.x, s.y, s.width, s.height);
            return;
        }
        const vw: u32 = @intCast(@max(viewport.width, 1));
        const vh: u32 = @intCast(@max(viewport.height, 1));
        c.wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, vw, vh);
    }

    fn uploadPathVertices(self: *SceneRenderer, vertices: []const scene_mod.PathVertex) void {
        if (vertices.len == 0) return;
        const bytes = std.mem.sliceAsBytes(vertices);
        if (self.path_vertex_buffer == null or self.path_vertex_capacity < bytes.len) {
            if (self.path_vertex_buffer) |buf| c.wgpuBufferRelease(buf);
            var capacity: u64 = @max(self.path_vertex_capacity * 2, 4096);
            while (capacity < bytes.len) capacity *= 2;
            self.path_vertex_buffer = c.wgpuDeviceCreateBuffer(self.device, &.{
                .label = stringView("zgpui path vertices"),
                .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
                .size = capacity,
            });
            self.path_vertex_capacity = capacity;
        }
        c.wgpuQueueWriteBuffer(self.queue, self.path_vertex_buffer, 0, bytes.ptr, bytes.len);
    }

    fn setScissor(
        self: *SceneRenderer,
        pass: c.WGPURenderPassEncoder,
        clip: scene_mod.BoundsF,
        viewport: geometry.Size(geometry.DevicePixels),
        scale: f32,
    ) void {
        _ = self;
        const vw: u32 = @intCast(@max(viewport.width, 1));
        const vh: u32 = @intCast(@max(viewport.height, 1));
        if (clip.size_w <= 0 or clip.size_h <= 0) {
            c.wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, vw, vh);
            return;
        }
        const x: i32 = @intFromFloat(@floor(clip.origin_x * scale));
        const y: i32 = @intFromFloat(@floor(clip.origin_y * scale));
        const w: i32 = @intFromFloat(@ceil(clip.size_w * scale));
        const h: i32 = @intFromFloat(@ceil(clip.size_h * scale));
        const x0: u32 = @intCast(@max(x, 0));
        const y0: u32 = @intCast(@max(y, 0));
        const x1: u32 = @min(@as(u32, @intCast(@max(x + w, 0))), vw);
        const y1: u32 = @min(@as(u32, @intCast(@max(y + h, 0))), vh);
        if (x1 <= x0 or y1 <= y0) {
            c.wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, 1, 1);
            return;
        }
        c.wgpuRenderPassEncoderSetScissorRect(pass, x0, y0, x1 - x0, y1 - y0);
    }
};

test "primitive struct sizes are shader-compatible" {
    // All-scalar layouts: WGSL offsets match extern struct offsets exactly.
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(scene_mod.Quad));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(scene_mod.Shadow));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(scene_mod.MonochromeSprite));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(scene_mod.PolychromeSprite));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(scene_mod.PathVertex));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Globals));
}
