//! base-gpui catalog alias: `scroll_area` re-exports scroll view helpers
//! and scrollbar geometry.

const scroll = @import("../elements/scroll.zig");

pub const ScrollState = scroll.ScrollState;
pub const ScrollAxes = scroll.ScrollAxes;
pub const ScrollView = scroll.ScrollView;
pub const default_line_height = scroll.default_line_height;

pub const scrollView = scroll.scrollView;
pub const scrollArea = scroll.scrollView;

pub const scrollbar = @import("scrollbar.zig");

