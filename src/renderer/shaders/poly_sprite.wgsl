// Polychrome sprite pipeline: full-color images sampled from an RGBA
// texture. Concatenated after common.wgsl.
// Layout mirrors scene.PolychromeSprite.

struct PolychromeSprite {
    order: u32,
    opacity: f32,
    bounds: BoundsF,
    clip_bounds: BoundsF,
    uv_bounds: BoundsF,
}

@group(0) @binding(1) var<storage, read> sprites: array<PolychromeSprite>;
@group(1) @binding(0) var image_texture: texture_2d<f32>;
@group(1) @binding(1) var image_sampler: sampler;

struct SpriteVarying {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) @interpolate(flat) instance_id: u32,
}

@vertex
fn vs_poly_sprite(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32,
) -> SpriteVarying {
    let sprite = sprites[instance_index];
    let unit = unit_vertex(vertex_index);
    let device_pos = (bounds_origin(sprite.bounds) + unit * bounds_size(sprite.bounds)) * globals.scale;
    let tex_size = vec2<f32>(textureDimensions(image_texture));
    let uv = (bounds_origin(sprite.uv_bounds) + unit * bounds_size(sprite.uv_bounds)) / tex_size;

    var out: SpriteVarying;
    out.position = to_ndc(device_pos);
    out.uv = uv;
    out.instance_id = instance_index;
    return out;
}

@fragment
fn fs_poly_sprite(in: SpriteVarying) -> @location(0) vec4<f32> {
    let sprite = sprites[in.instance_id];
    var color = textureSample(image_texture, image_sampler, in.uv);
    let clip = inside_clip(in.position.xy, sprite.clip_bounds);
    color.a = color.a * sprite.opacity * clip;
    return premultiply(color);
}
