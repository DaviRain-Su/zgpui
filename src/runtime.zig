//! GPUI-adjacent **runtime** surface: window loop, dirty, animation, input
//! routing helpers that sit above platform backends.
//!
//! Maps roughly to gpui's window/app runtime pieces (frame scheduling,
//! input, timers). Platform backends remain under `zgpui.platform`.

const window_mod = @import("window.zig");
const dirty_mod = @import("dirty.zig");
const animation_mod = @import("animation.zig");
const hotkey_mod = @import("hotkey.zig");
const profile_mod = @import("profile.zig");
const debug_hud_mod = @import("debug_hud.zig");
const element_mod = @import("element.zig");
const a11y_mod = @import("a11y.zig");

pub const window = window_mod;
pub const Window = window_mod.Window;
pub const RenderFn = window_mod.RenderFn;

pub const dirty = dirty_mod;
pub const DirtyTracker = dirty_mod.DirtyTracker;
pub const PartialPresentPlan = dirty_mod.PartialPresentPlan;
pub const ScissorRect = dirty_mod.ScissorRect;
pub const planPartialPresent = dirty_mod.planPartialPresent;
pub const planPaintClip = dirty_mod.planPaintClip;
pub const classifyInputDirty = dirty_mod.classifyInputDirty;
pub const InputDirtyKind = dirty_mod.InputDirtyKind;

pub const animation = animation_mod;
pub const Easing = animation_mod.Easing;
pub const Tween = animation_mod.Tween;
pub const Spring = animation_mod.Spring;
pub const Timeline = animation_mod.Timeline;
pub const AnimationClock = animation_mod.AnimationClock;
pub const AnimationId = animation_mod.AnimationId;
pub const animationId = animation_mod.animationId;
pub const fadeIn = animation_mod.fadeIn;
pub const fadeOut = animation_mod.fadeOut;
pub const opacityOf = animation_mod.opacityOf;
pub const scaleAlpha = animation_mod.scaleAlpha;
pub const default_fade_ms = animation_mod.default_fade_ms;

pub const hotkey = hotkey_mod;
pub const Chord = hotkey_mod.Chord;
pub const ActionId = hotkey_mod.ActionId;
pub const actionId = hotkey_mod.actionId;
pub const Binding = hotkey_mod.Binding;
pub const Keymap = hotkey_mod.Keymap;
pub const HotkeyRouter = hotkey_mod.HotkeyRouter;

pub const profile = profile_mod;
pub const FramePhase = profile_mod.Phase;
pub const FrameStats = profile_mod.FrameStats;
pub const FrameProfiler = profile_mod.Profiler;

pub const debug_hud = debug_hud_mod;
pub const DebugHudStats = debug_hud_mod.Stats;
pub const DebugHudProfilerView = debug_hud_mod.ProfilerView;
pub const formatDebugHudLine = debug_hud_mod.formatHudLine;
pub const collectDebugHudStats = debug_hud_mod.collectStats;

pub const element = element_mod;
pub const Element = element_mod.Element;
pub const ElementId = element_mod.ElementId;
pub const elementId = element_mod.elementId;
pub const InputState = element_mod.InputState;
pub const FrameState = element_mod.FrameState;

pub const a11y = a11y_mod;
pub const A11yRole = a11y_mod.Role;
pub const A11yNode = a11y_mod.Node;
pub const A11yNameSource = a11y_mod.NameSource;
