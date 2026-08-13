// Shared definitions prepended to every zgpui pipeline shader.
//
// IMPORTANT: primitive structs mirror the extern structs in src/scene.zig.
// They use only f32/u32 scalar members so the WGSL memory layout matches C
// layout exactly (vec2/vec4 members would change alignment).
//
// All primitive coordinates are logical pixels; `globals.scale` converts to
// device pixels, and positions map to NDC via `globals.viewport_size`
// (device pixels).

struct Globals {
    viewport_size: vec2<f32>,
    scale: f32,
    _pad: f32,
}

@group(0) @binding(0) var<uniform> globals: Globals;

struct BoundsF {
    origin_x: f32,
    origin_y: f32,
    size_w: f32,
    size_h: f32,
}

struct CornersF {
    top_left: f32,
    top_right: f32,
    bottom_right: f32,
    bottom_left: f32,
}

struct EdgesF {
    top: f32,
    right: f32,
    bottom: f32,
    left: f32,
}

struct ColorF {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
}

fn bounds_origin(b: BoundsF) -> vec2<f32> {
    return vec2<f32>(b.origin_x, b.origin_y);
}

fn bounds_size(b: BoundsF) -> vec2<f32> {
    return vec2<f32>(b.size_w, b.size_h);
}

fn color_vec(c: ColorF) -> vec4<f32> {
    return vec4<f32>(c.r, c.g, c.b, c.a);
}

fn corners_vec(c: CornersF) -> vec4<f32> {
    return vec4<f32>(c.top_left, c.top_right, c.bottom_right, c.bottom_left);
}

fn edges_vec(e: EdgesF) -> vec4<f32> {
    return vec4<f32>(e.top, e.right, e.bottom, e.left);
}

fn to_ndc(device_pos: vec2<f32>) -> vec4<f32> {
    let ndc = device_pos / globals.viewport_size * 2.0 - 1.0;
    return vec4<f32>(ndc.x, -ndc.y, 0.0, 1.0);
}

// Unit quad corner for a 4-vertex triangle strip.
fn unit_vertex(vertex_index: u32) -> vec2<f32> {
    return vec2<f32>(
        f32(vertex_index & 1u),
        f32((vertex_index >> 1u) & 1u),
    );
}

// Pick the corner radius for the quadrant containing `point` (relative to
// center, +x right, +y down). radii = (top_left, top_right, bottom_right,
// bottom_left).
fn pick_corner_radius(point: vec2<f32>, radii: vec4<f32>) -> f32 {
    if (point.x < 0.0) {
        if (point.y < 0.0) {
            return radii.x;
        } else {
            return radii.w;
        }
    } else {
        if (point.y < 0.0) {
            return radii.y;
        } else {
            return radii.z;
        }
    }
}

// Signed distance to a rounded rectangle centered at origin with
// half-extents `half_size` and corner radius `radius`.
fn sdf_rounded_rect(point: vec2<f32>, half_size: vec2<f32>, radius: f32) -> f32 {
    let q = abs(point) - half_size + vec2<f32>(radius);
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

fn premultiply(color: vec4<f32>) -> vec4<f32> {
    return vec4<f32>(color.rgb * color.a, color.a);
}

fn inside_clip(device_pos: vec2<f32>, clip: BoundsF) -> f32 {
    if (clip.size_w <= 0.0 || clip.size_h <= 0.0) {
        return 1.0; // zero clip bounds = no clipping
    }
    let origin = bounds_origin(clip) * globals.scale;
    let size = bounds_size(clip) * globals.scale;
    let inside = step(origin, device_pos) * step(device_pos, origin + size);
    return inside.x * inside.y;
}
