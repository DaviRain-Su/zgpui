//! AppKit / Carbon virtual-key and modifier mapping for the native backend.
//! Logic only — no Objective-C calls; safe for unit tests without a window.

const std = @import("std");
const platform_mod = @import("../platform.zig");

/// NSEventModifierFlag* (subset used by zgpui).
pub const NSEventModifierFlagCapsLock: c_ulong = 1 << 16;
pub const NSEventModifierFlagShift: c_ulong = 1 << 17;
pub const NSEventModifierFlagControl: c_ulong = 1 << 18;
pub const NSEventModifierFlagOption: c_ulong = 1 << 19;
pub const NSEventModifierFlagCommand: c_ulong = 1 << 20;

/// Carbon `kVK_*` virtual key codes (hardware-ish, layout-independent).
pub const kVK_ANSI_A: u16 = 0x00;
pub const kVK_ANSI_S: u16 = 0x01;
pub const kVK_ANSI_D: u16 = 0x02;
pub const kVK_ANSI_F: u16 = 0x03;
pub const kVK_ANSI_H: u16 = 0x04;
pub const kVK_ANSI_G: u16 = 0x05;
pub const kVK_ANSI_Z: u16 = 0x06;
pub const kVK_ANSI_X: u16 = 0x07;
pub const kVK_ANSI_C: u16 = 0x08;
pub const kVK_ANSI_V: u16 = 0x09;
pub const kVK_ANSI_B: u16 = 0x0B;
pub const kVK_ANSI_Q: u16 = 0x0C;
pub const kVK_ANSI_W: u16 = 0x0D;
pub const kVK_ANSI_E: u16 = 0x0E;
pub const kVK_ANSI_R: u16 = 0x0F;
pub const kVK_ANSI_Y: u16 = 0x10;
pub const kVK_ANSI_T: u16 = 0x11;
pub const kVK_ANSI_1: u16 = 0x12;
pub const kVK_ANSI_2: u16 = 0x13;
pub const kVK_ANSI_3: u16 = 0x14;
pub const kVK_ANSI_4: u16 = 0x15;
pub const kVK_ANSI_6: u16 = 0x16;
pub const kVK_ANSI_5: u16 = 0x17;
pub const kVK_ANSI_Equal: u16 = 0x18;
pub const kVK_ANSI_9: u16 = 0x19;
pub const kVK_ANSI_7: u16 = 0x1A;
pub const kVK_ANSI_Minus: u16 = 0x1B;
pub const kVK_ANSI_8: u16 = 0x1C;
pub const kVK_ANSI_0: u16 = 0x1D;
pub const kVK_ANSI_RightBracket: u16 = 0x1E;
pub const kVK_ANSI_O: u16 = 0x1F;
pub const kVK_ANSI_U: u16 = 0x20;
pub const kVK_ANSI_LeftBracket: u16 = 0x21;
pub const kVK_ANSI_I: u16 = 0x22;
pub const kVK_ANSI_P: u16 = 0x23;
pub const kVK_Return: u16 = 0x24;
pub const kVK_ANSI_L: u16 = 0x25;
pub const kVK_ANSI_J: u16 = 0x26;
pub const kVK_ANSI_Quote: u16 = 0x27;
pub const kVK_ANSI_K: u16 = 0x28;
pub const kVK_ANSI_Semicolon: u16 = 0x29;
pub const kVK_ANSI_Backslash: u16 = 0x2A;
pub const kVK_ANSI_Comma: u16 = 0x2B;
pub const kVK_ANSI_Slash: u16 = 0x2C;
pub const kVK_ANSI_N: u16 = 0x2D;
pub const kVK_ANSI_M: u16 = 0x2E;
pub const kVK_ANSI_Period: u16 = 0x2F;
pub const kVK_Tab: u16 = 0x30;
pub const kVK_Space: u16 = 0x31;
pub const kVK_ANSI_Grave: u16 = 0x32;
pub const kVK_Delete: u16 = 0x33; // backspace
pub const kVK_Escape: u16 = 0x35;
pub const kVK_RightCommand: u16 = 0x36;
pub const kVK_Command: u16 = 0x37;
pub const kVK_Shift: u16 = 0x38;
pub const kVK_CapsLock: u16 = 0x39;
pub const kVK_Option: u16 = 0x3A;
pub const kVK_Control: u16 = 0x3B;
pub const kVK_RightShift: u16 = 0x3C;
pub const kVK_RightOption: u16 = 0x3D;
pub const kVK_RightControl: u16 = 0x3E;
pub const kVK_F5: u16 = 0x60;
pub const kVK_F6: u16 = 0x61;
pub const kVK_F7: u16 = 0x62;
pub const kVK_F3: u16 = 0x63;
pub const kVK_F8: u16 = 0x64;
pub const kVK_F9: u16 = 0x65;
pub const kVK_F11: u16 = 0x67;
pub const kVK_F10: u16 = 0x6D;
pub const kVK_F12: u16 = 0x6F;
pub const kVK_Home: u16 = 0x73;
pub const kVK_PageUp: u16 = 0x74;
pub const kVK_ForwardDelete: u16 = 0x75;
pub const kVK_F4: u16 = 0x76;
pub const kVK_End: u16 = 0x77;
pub const kVK_F2: u16 = 0x78;
pub const kVK_PageDown: u16 = 0x79;
pub const kVK_F1: u16 = 0x7A;
pub const kVK_LeftArrow: u16 = 0x7B;
pub const kVK_RightArrow: u16 = 0x7C;
pub const kVK_DownArrow: u16 = 0x7D;
pub const kVK_UpArrow: u16 = 0x7E;

pub fn mapModifiers(flags: c_ulong) platform_mod.Modifiers {
    return .{
        .shift = flags & NSEventModifierFlagShift != 0,
        .control = flags & NSEventModifierFlagControl != 0,
        .alt = flags & NSEventModifierFlagOption != 0,
        .command = flags & NSEventModifierFlagCommand != 0,
        .caps_lock = flags & NSEventModifierFlagCapsLock != 0,
    };
}

pub fn modifiersEqual(a: platform_mod.Modifiers, b: platform_mod.Modifiers) bool {
    const Bits = @Int(.unsigned, @bitSizeOf(platform_mod.Modifiers));
    return @as(Bits, @bitCast(a)) == @as(Bits, @bitCast(b));
}

pub fn mapKey(key_code: u16) platform_mod.Key {
    return switch (key_code) {
        kVK_ANSI_A => .a,
        kVK_ANSI_B => .b,
        kVK_ANSI_C => .c,
        kVK_ANSI_D => .d,
        kVK_ANSI_E => .e,
        kVK_ANSI_F => .f,
        kVK_ANSI_G => .g,
        kVK_ANSI_H => .h,
        kVK_ANSI_I => .i,
        kVK_ANSI_J => .j,
        kVK_ANSI_K => .k,
        kVK_ANSI_L => .l,
        kVK_ANSI_M => .m,
        kVK_ANSI_N => .n,
        kVK_ANSI_O => .o,
        kVK_ANSI_P => .p,
        kVK_ANSI_Q => .q,
        kVK_ANSI_R => .r,
        kVK_ANSI_S => .s,
        kVK_ANSI_T => .t,
        kVK_ANSI_U => .u,
        kVK_ANSI_V => .v,
        kVK_ANSI_W => .w,
        kVK_ANSI_X => .x,
        kVK_ANSI_Y => .y,
        kVK_ANSI_Z => .z,
        kVK_ANSI_0 => .zero,
        kVK_ANSI_1 => .one,
        kVK_ANSI_2 => .two,
        kVK_ANSI_3 => .three,
        kVK_ANSI_4 => .four,
        kVK_ANSI_5 => .five,
        kVK_ANSI_6 => .six,
        kVK_ANSI_7 => .seven,
        kVK_ANSI_8 => .eight,
        kVK_ANSI_9 => .nine,
        kVK_F1 => .f1,
        kVK_F2 => .f2,
        kVK_F3 => .f3,
        kVK_F4 => .f4,
        kVK_F5 => .f5,
        kVK_F6 => .f6,
        kVK_F7 => .f7,
        kVK_F8 => .f8,
        kVK_F9 => .f9,
        kVK_F10 => .f10,
        kVK_F11 => .f11,
        kVK_F12 => .f12,
        kVK_Escape => .escape,
        kVK_Tab => .tab,
        kVK_Space => .space,
        kVK_Return => .enter,
        kVK_Delete => .backspace,
        kVK_ForwardDelete => .delete,
        kVK_LeftArrow => .left,
        kVK_RightArrow => .right,
        kVK_UpArrow => .up,
        kVK_DownArrow => .down,
        kVK_Home => .home,
        kVK_End => .end,
        kVK_PageUp => .page_up,
        kVK_PageDown => .page_down,
        kVK_ANSI_Minus => .minus,
        kVK_ANSI_Equal => .equal,
        kVK_ANSI_LeftBracket => .left_bracket,
        kVK_ANSI_RightBracket => .right_bracket,
        kVK_ANSI_Backslash => .backslash,
        kVK_ANSI_Semicolon => .semicolon,
        kVK_ANSI_Quote => .apostrophe,
        kVK_ANSI_Grave => .grave,
        kVK_ANSI_Comma => .comma,
        kVK_ANSI_Period => .period,
        kVK_ANSI_Slash => .slash,
        kVK_Shift => .left_shift,
        kVK_RightShift => .right_shift,
        kVK_Control => .left_control,
        kVK_RightControl => .right_control,
        kVK_Option => .left_alt,
        kVK_RightOption => .right_alt,
        kVK_Command => .left_command,
        kVK_RightCommand => .right_command,
        else => .unknown,
    };
}

pub fn mapMouseButton(button_number: c_long) ?platform_mod.MouseButton {
    return switch (button_number) {
        0 => .left,
        1 => .right,
        2 => .middle,
        3 => .back,
        4 => .forward,
        else => null,
    };
}

test "key mapping covers letters, digits, and named keys" {
    try std.testing.expectEqual(platform_mod.Key.a, mapKey(kVK_ANSI_A));
    try std.testing.expectEqual(platform_mod.Key.z, mapKey(kVK_ANSI_Z));
    try std.testing.expectEqual(platform_mod.Key.zero, mapKey(kVK_ANSI_0));
    try std.testing.expectEqual(platform_mod.Key.nine, mapKey(kVK_ANSI_9));
    try std.testing.expectEqual(platform_mod.Key.escape, mapKey(kVK_Escape));
    try std.testing.expectEqual(platform_mod.Key.enter, mapKey(kVK_Return));
    try std.testing.expectEqual(platform_mod.Key.f12, mapKey(kVK_F12));
    try std.testing.expectEqual(platform_mod.Key.left_command, mapKey(kVK_Command));
    try std.testing.expectEqual(platform_mod.Key.grave, mapKey(kVK_ANSI_Grave));
    try std.testing.expectEqual(platform_mod.Key.backspace, mapKey(kVK_Delete));
    try std.testing.expectEqual(platform_mod.Key.delete, mapKey(kVK_ForwardDelete));
    try std.testing.expectEqual(platform_mod.Key.unknown, mapKey(0xFFFF));
}

test "modifier mapping" {
    const none = mapModifiers(0);
    try std.testing.expect(!none.shift and !none.control and !none.alt and
        !none.command and !none.caps_lock);

    const all = mapModifiers(NSEventModifierFlagShift | NSEventModifierFlagControl |
        NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagCapsLock);
    try std.testing.expect(all.shift and all.control and all.alt and
        all.command and all.caps_lock);

    try std.testing.expect(modifiersEqual(all, all));
    try std.testing.expect(!modifiersEqual(all, none));
}

test "mouse button mapping" {
    try std.testing.expectEqual(platform_mod.MouseButton.left, mapMouseButton(0).?);
    try std.testing.expectEqual(platform_mod.MouseButton.right, mapMouseButton(1).?);
    try std.testing.expectEqual(platform_mod.MouseButton.middle, mapMouseButton(2).?);
    try std.testing.expectEqual(platform_mod.MouseButton.back, mapMouseButton(3).?);
    try std.testing.expectEqual(platform_mod.MouseButton.forward, mapMouseButton(4).?);
    try std.testing.expectEqual(@as(?platform_mod.MouseButton, null), mapMouseButton(5));
}
