// Shadow pipeline: gaussian-blurred rounded rectangles.
// Analytic gaussian integral along x (via erf approximation), numeric
// sampling along y — the approach used by gpui and Evan Wallace's article
// "Fast Rounded Rectangle Shadows".
// Concatenated after common.wgsl. Layout mirrors scene.Shadow.

struct Shadow {
    order: u32,
    blur_radius: f32,
    bounds: BoundsF,
    clip_bounds: BoundsF,
    corner_radii: CornersF,
    color: ColorF,
}

@group(0) @binding(1) var<storage, read> shadows: array<Shadow>;

struct ShadowVarying {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) instance_id: u32,
}

fn gaussian(x: f32, sigma: f32) -> f32 {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159265) * sigma);
}

// Vectorized error function approximation (Abramowitz & Stegun 7.1.27).
fn erf2(v: vec2<f32>) -> vec2<f32> {
    let s = sign(v);
    let a = abs(v);
    var r = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    r = r * r;
    return s - s / (r * r);
}

// Integral of the gaussian over [lower, upper] along one axis.
fn blur_along_x(lower: f32, upper: f32, sigma: f32) -> f32 {
    let integral = 0.5 * erf2(vec2<f32>(lower, upper) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

@vertex
fn vs_shadow(
    @builtin(vertex_index) vertex_index: u32,
    @builtin(instance_index) instance_index: u32,
) -> ShadowVarying {
    let shadow = shadows[instance_index];
    let unit = unit_vertex(vertex_index);
    // Expand the geometry by 3 sigma so the whole blur fits inside.
    let expand = shadow.blur_radius * 3.0;
    let origin = bounds_origin(shadow.bounds) - vec2<f32>(expand);
    let size = bounds_size(shadow.bounds) + vec2<f32>(expand * 2.0);
    let device_pos = (origin + unit * size) * globals.scale;

    var out: ShadowVarying;
    out.position = to_ndc(device_pos);
    out.instance_id = instance_index;
    return out;
}

@fragment
fn fs_shadow(in: ShadowVarying) -> @location(0) vec4<f32> {
    let shadow = shadows[in.instance_id];
    let scale = globals.scale;
    let sigma = max(shadow.blur_radius * scale / 2.0, 0.25);

    let size = bounds_size(shadow.bounds) * scale;
    let half_size = size / 2.0;
    let center = bounds_origin(shadow.bounds) * scale + half_size;
    let point = in.position.xy - center;
    let radius = pick_corner_radius(point, corners_vec(shadow.corner_radii) * scale);

    // Integrate the gaussian along y numerically; x is analytic. Rounded
    // corners shrink the x extent of each y-slice along the corner circle.
    var alpha = 0.0;
    let step_count = 8;
    let y_range = 3.0 * sigma;
    let dy = (y_range * 2.0) / f32(step_count);
    var y = -y_range + dy * 0.5;
    for (var i = 0; i < step_count; i = i + 1) {
        let sample_y = point.y - y;
        var x_extent = half_size.x;
        let cy = abs(sample_y) - (half_size.y - radius);
        if (cy > 0.0) {
            let circle = sqrt(max(radius * radius - cy * cy, 0.0));
            x_extent = half_size.x - radius + circle;
        }
        let in_y = step(abs(sample_y), half_size.y);
        alpha = alpha + blur_along_x(-x_extent - point.x, x_extent - point.x, sigma) * gaussian(y, sigma) * dy * in_y;
        y = y + dy;
    }

    let color = color_vec(shadow.color);
    let clip = inside_clip(in.position.xy, shadow.clip_bounds);
    return premultiply(vec4<f32>(color.rgb, color.a * saturate(alpha) * clip));
}
