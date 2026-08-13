//! base-gpui catalog alias: `number_field` wraps `number_input`.

const number_input = @import("number_input.zig");

pub const Value = number_input.Value;
pub const ChangeHandler = number_input.ChangeHandler;
pub const StyleState = number_input.StyleState;
pub const StyleFn = number_input.StyleFn;
pub const Props = number_input.Props;

pub const clampValue = number_input.clampValue;
pub const readValue = number_input.readValue;
pub const numberField = number_input.numberInput;
