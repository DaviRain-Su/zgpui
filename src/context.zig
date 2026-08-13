//! GPUI-adjacent **context** surface: app-owned state and entity handles.
//!
//! Maps roughly to gpui's `App` / `Context` / entity ownership model. zgpui
//! uses a flatter `App` + `Entity(T)` API (no closure-based `update`); this
//! module groups those types under one name.

const app_mod = @import("app.zig");
const value_mod = @import("value.zig");
const clipboard_mod = @import("clipboard.zig");

pub const app = app_mod;
pub const App = app_mod.App;
pub const Entity = app_mod.Entity;
pub const EntityId = app_mod.EntityId;
pub const SubscriptionId = app_mod.SubscriptionId;
pub const DirtyRegion = app_mod.App.DirtyRegion;

pub const value = value_mod;
pub const Value = value_mod.Value;
pub const MaskValue = value_mod.MaskValue;
pub const FieldValue = value_mod.FieldValue;

pub const clipboard = clipboard_mod;
pub const Clipboard = clipboard_mod.Clipboard;
pub const ClipboardBridge = clipboard_mod.ClipboardBridge;
