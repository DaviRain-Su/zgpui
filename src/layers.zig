//! GPUI-adjacent **layers** surface: stacked overlays above the main tree.
//!
//! Maps roughly to gpui's layered window/overlay presentation. Input still
//! hits the topmost layer first; modals trap focus and outside clicks.

const overlay_mod = @import("overlay.zig");

pub const overlay = overlay_mod;
pub const OverlayStack = overlay_mod.OverlayStack;
pub const OverlayEntry = overlay_mod.OverlayEntry;
pub const overlayId = overlay_mod.overlayId;
