//! base-gpui catalog alias: `input` re-exports `text_field`.

const text_field = @import("text_field.zig");

pub const Value = text_field.Value;
pub const ChangeHandler = text_field.ChangeHandler;
pub const StyleState = text_field.StyleState;
pub const StyleFn = text_field.StyleFn;
pub const Props = text_field.Props;

pub const readText = text_field.readText;
pub const input = text_field.textField;
