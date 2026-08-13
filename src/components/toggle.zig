//! base-gpui catalog alias: `toggle` is the binary switch component.

const switch_ = @import("switch.zig");

pub const ToggleState = switch_.SwitchState;
pub const Value = switch_.Value;
pub const ChangeHandler = switch_.ChangeHandler;
pub const StyleState = switch_.StyleState;
pub const StyleFn = switch_.StyleFn;
pub const Props = switch_.Props;

pub const toggle = switch_.switchEl;
pub const isOn = switch_.isOn;
