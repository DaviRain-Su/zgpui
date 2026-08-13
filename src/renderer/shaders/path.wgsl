// Path pipeline: triangle-list vertices with per-vertex color.
// Concatenated after common.wgsl. Uses a vertex buffer (not storage).

struct PathVertexIn {
    @location(0) position: vec2<f32>,
    @location(1) color: vec4<f32>,
}

struct PathVarying {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
}

@vertex
fn vs_path(in: PathVertexIn) -> PathVarying {
    var out: PathVarying;
    out.position = to_ndc(in.position * globals.scale);
    out.color = in.color;
    return out;
}

@fragment
fn fs_path(in: PathVarying) -> @location(0) vec4<f32> {
    return premultiply(in.color);
}
