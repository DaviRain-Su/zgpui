// Quad pipeline: rounded rectangles with backgrounds and borders (SDF).
// Concatenated after common.wgsl. Layout mirrors scene.Quad.

struct Quad {
    order: u32,
    pad: u32,
    bounds: BoundsF,
    clip_bounds: BoundsF,
    background: ColorF,
    border_color: ColorF,
    corner_radii: CornersF,
    border_widths: EdgesF,
}

@group(0) @binding(1) var<storage, read> quads: array<Quad>;

struct QuadVarying {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) instance_id: u32,
}

@vertex
fn vs_quad(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32,
) -> QuadVarying {
    let quad = quads[instance_index];
    let unit = unit_vertex(vertex_index);
    let device_pos = (bounds_origin(quad.bounds) + unit * bounds_size(quad.bounds)) * globals.scale;

    var out: QuadVarying;
    out.position = to_ndc(device_pos);
    out.instance_id = instance_index;
    return out;
}

@fragment
fn fs_quad(in: QuadVarying) -> @location(0) vec4<f32> {
    let quad = quads[in.instance_id];
    let scale = globals.scale;

    let size = bounds_size(quad.bounds) * scale;
    let half_size = size / 2.0;
    let center = bounds_origin(quad.bounds) * scale + half_size;
    let point = in.position.xy - center;

    let radius = pick_corner_radius(point, corners_vec(quad.corner_radii) * scale);
    let dist = sdf_rounded_rect(point, half_size, radius);

    // Border width for the edge this fragment is closest to.
    // edges_vec = (top, right, bottom, left)
    let bw = edges_vec(quad.border_widths) * scale;
    let horizontal_edge_dist = half_size.x - abs(point.x);
    let vertical_edge_dist = half_size.y - abs(point.y);
    var border_width = 0.0;
    if (horizontal_edge_dist < vertical_edge_dist) {
        border_width = select(bw.y, bw.w, point.x < 0.0); // right or left
    } else {
        border_width = select(bw.z, bw.x, point.y < 0.0); // bottom or top
    }

    var color = color_vec(quad.background);
    if (border_width > 0.0) {
        let inner_dist = dist + border_width;
        let border_mask = saturate(inner_dist + 0.5); // 1 within border ring
        color = mix(color, color_vec(quad.border_color), border_mask);
    }

    // Anti-aliased outer edge.
    let alpha = saturate(0.5 - dist);
    let clip = inside_clip(in.position.xy, quad.clip_bounds);
    return premultiply(vec4<f32>(color.rgb, color.a * alpha * clip));
}
