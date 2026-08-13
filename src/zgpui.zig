//! zgpui — a GPUI-inspired UI framework for Zig.
//!
//! Layer map (bottom to top):
//! - `platform`  window/input abstraction (`platform/glfw.zig` backend)
//! - `renderer`  wgpu renderer for Scene primitives
//! - `scene`     draw primitives: quads, shadows, sprites, paths
//! - `text`      FreeType/HarfBuzz shaping + glyph atlas
//! - `layout`    flexbox layout engine
//! - `element`   three-phase element system (request_layout/prepaint/paint)
//! - `app`       entity/context state model
//! - `components` headless components (base-gpui style)

const std = @import("std");
const builtin = @import("builtin");

pub const geometry = @import("geometry.zig");
pub const color = @import("color.zig");
pub const platform = @import("platform.zig");
pub const scene = @import("scene.zig");
pub const app = @import("app.zig");
pub const clipboard = @import("clipboard.zig");
pub const value = @import("value.zig");
pub const style = @import("style.zig");
pub const glfw_platform = @import("platform/glfw.zig");
pub const appkit_platform = if (builtin.os.tag == .macos)
    @import("platform/appkit.zig")
else
    struct {};
pub const renderer = @import("renderer/gpu.zig");
pub const scene_renderer = @import("renderer/scene_renderer.zig");
pub const path = @import("path.zig");
pub const text = @import("text/text.zig");
pub const layout = @import("layout/layout.zig");
pub const element = @import("element.zig");
pub const a11y = @import("a11y.zig");
pub const testing = @import("testing.zig");
pub const overlay = @import("overlay.zig");
pub const components = @import("components/components.zig");
pub const window = @import("window.zig");
pub const animation = @import("animation.zig");
pub const dirty = @import("dirty.zig");
pub const hotkey = @import("hotkey.zig");
pub const profile = @import("profile.zig");
pub const debug_hud = @import("debug_hud.zig");

pub const Window = window.Window;
pub const DirtyTracker = dirty.DirtyTracker;
pub const PartialPresentPlan = dirty.PartialPresentPlan;
pub const ScissorRect = dirty.ScissorRect;
pub const planPartialPresent = dirty.planPartialPresent;
pub const toDevicePixels = geometry.toDevicePixels;
pub const App = app.App;
pub const Clipboard = clipboard.Clipboard;
pub const ClipboardBridge = clipboard.ClipboardBridge;
pub const Entity = app.Entity;
pub const Value = value.Value;
pub const MaskValue = value.MaskValue;
pub const FieldValue = value.FieldValue;
pub const OverlayStack = overlay.OverlayStack;
pub const OverlayEntry = overlay.OverlayEntry;
pub const overlayId = overlay.overlayId;
pub const Easing = animation.Easing;
pub const Tween = animation.Tween;
pub const Spring = animation.Spring;
pub const Timeline = animation.Timeline;
pub const AnimationClock = animation.AnimationClock;
pub const AnimationId = animation.AnimationId;
pub const animationId = animation.animationId;
pub const Chord = hotkey.Chord;
pub const ActionId = hotkey.ActionId;
pub const actionId = hotkey.actionId;
pub const Binding = hotkey.Binding;
pub const Keymap = hotkey.Keymap;
pub const HotkeyRouter = hotkey.HotkeyRouter;
pub const DebugHudStats = debug_hud.Stats;
pub const DebugHudProfilerView = debug_hud.ProfilerView;
pub const formatDebugHudLine = debug_hud.formatHudLine;
pub const collectDebugHudStats = debug_hud.collectStats;
pub const FramePhase = profile.Phase;
pub const FrameStats = profile.FrameStats;
pub const FrameProfiler = profile.Profiler;
pub const fadeIn = animation.fadeIn;
pub const fadeOut = animation.fadeOut;
pub const opacityOf = animation.opacityOf;
pub const scaleAlpha = animation.scaleAlpha;
pub const default_fade_ms = animation.default_fade_ms;
pub const div_mod = @import("elements/div.zig");
pub const scroll_mod = @import("elements/scroll.zig");
pub const text_element = @import("elements/text.zig");
pub const text_input_mod = @import("elements/text_input.zig");
pub const text_area_mod = @import("elements/text_area.zig");

pub const Element = element.Element;
pub const ElementId = element.ElementId;
pub const elementId = element.elementId;
pub const A11yRole = a11y.Role;
pub const A11yNode = a11y.Node;
pub const A11yNameSource = a11y.NameSource;
pub const Div = div_mod.Div;
pub const div = div_mod.div;
pub const ScrollView = scroll_mod.ScrollView;
pub const ScrollState = scroll_mod.ScrollState;
pub const ScrollAxes = scroll_mod.ScrollAxes;
pub const scrollView = scroll_mod.scrollView;
pub const Text = text_element.Text;
pub const textEl = text_element.textEl;
pub const TextResources = text_element.TextResources;
pub const TextInput = text_input_mod.TextInput;
pub const TextInputState = text_input_mod.TextInputState;
pub const textInput = text_input_mod.textInput;
pub const TextArea = text_area_mod.TextArea;
pub const TextAreaState = text_area_mod.TextAreaState;
pub const textArea = text_area_mod.textArea;

pub const Pixels = geometry.Pixels;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Bounds = geometry.Bounds;
pub const Corners = geometry.Corners;
pub const Edges = geometry.Edges;
pub const Rgba = color.Rgba;

test {
    std.testing.refAllDecls(@This());
    // Linux-only at runtime, but compile/run harness tests on every host.
    _ = @import("platform/wayland_surface.zig");
}

test "c bindings translate" {
    _ = @import("glfw_c");
    _ = @import("wgpu_c");
    if (builtin.os.tag == .macos) _ = @import("objc_c");
    _ = @import("text_c");
}
