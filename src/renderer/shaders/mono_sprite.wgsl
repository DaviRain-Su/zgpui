// Monochrome sprite pipeline: glyphs and icons sampled from an R8 atlas,
// tinted with a color. Concatenated after common.wgsl.
// Layout mirrors scene.MonochromeSprite.

struct MonochromeSprite {
    order: u32,
    pad: u32,
    bounds: BoundsF,
    clip_bounds: BoundsF,
    uv_bounds: BoundsF,
    color: ColorF,
}

@group(0) @binding(1) var<storage, read> sprites: array<MonochromeSprite>;
@group(1) @binding(0) var atlas_texture: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

struct SpriteVarying {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) @interpolate(flat) instance_id: u32,
}

@vertex
fn vs_mono_sprite(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32,
) -> SpriteVarying {
    let sprite = sprites[instance_index];
    let unit = unit_vertex(vertex_index);
    let device_pos = (bounds_origin(sprite.bounds) + unit * bounds_size(sprite.bounds)) * globals.scale;
    let atlas_size = vec2<f32>(textureDimensions(atlas_texture));
    let uv = (bounds_origin(sprite.uv_bounds) + unit * bounds_size(sprite.uv_bounds)) / atlas_size;

    var out: SpriteVarying;
    out.position = to_ndc(device_pos);
    out.uv = uv;
    out.instance_id = instance_index;
    return out;
}

@fragment
fn fs_mono_sprite(in: SpriteVarying) -> @location(0) vec4<f32> {
    let sprite = sprites[in.instance_id];
    let coverage = textureSample(atlas_texture, atlas_sampler, in.uv).r;
    let color = color_vec(sprite.color);
    let clip = inside_clip(in.position.xy, sprite.clip_bounds);
    return premultiply(vec4<f32>(color.rgb, color.a * coverage * clip));
}
