//! GPUI-adjacent **props** surface: layout/paint styling primitives.
//!
//! Maps roughly to gpui's style/length helpers used when building element
//! trees. Prefer `zgpui.style` / `zgpui.geometry` for existing call sites;
//! this module is the named parity entry point.

const style_mod = @import("style.zig");
const geometry_mod = @import("geometry.zig");
const color_mod = @import("color.zig");

pub const style = style_mod;
pub const Style = style_mod.Style;
pub const Display = style_mod.Display;
pub const FlexDirection = style_mod.FlexDirection;
pub const AlignItems = style_mod.AlignItems;
pub const AlignContent = style_mod.AlignContent;
pub const JustifyContent = style_mod.JustifyContent;
pub const Overflow = style_mod.Overflow;
pub const Length = style_mod.Length;

pub const geometry = geometry_mod;
pub const Pixels = geometry_mod.Pixels;
pub const Point = geometry_mod.Point;
pub const Size = geometry_mod.Size;
pub const Bounds = geometry_mod.Bounds;
pub const Corners = geometry_mod.Corners;
pub const Edges = geometry_mod.Edges;

pub const color = color_mod;
pub const Rgba = color_mod.Rgba;
