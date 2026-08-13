//! macOS CoreText helpers: resolve UI / named system fonts to filesystem
//! paths so FreeType can load them. On other platforms these return
//! `error.UnsupportedPlatform`.

const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

const CFIndex = isize;
const CFStringEncoding = u32;
const CFAllocatorRef = ?*anyopaque;
const CFTypeRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFURLRef = ?*anyopaque;
const CTFontRef = ?*anyopaque;

const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;
const kCTFontUIFontSystem: u32 = 2;

const MacApi = if (is_macos) struct {
    extern "CoreFoundation" fn CFStringCreateWithCString(
        alloc: CFAllocatorRef,
        c_str: [*:0]const u8,
        encoding: CFStringEncoding,
    ) callconv(.c) CFStringRef;
    extern "CoreFoundation" fn CFURLGetFileSystemRepresentation(
        url: CFURLRef,
        resolve_against_base: u8,
        buffer: [*]u8,
        max_buf_len: CFIndex,
    ) callconv(.c) u8;
    extern "CoreFoundation" fn CFRelease(cf: CFTypeRef) callconv(.c) void;

    extern "CoreText" fn CTFontCreateWithName(
        name: CFStringRef,
        size: f64,
        matrix: ?*anyopaque,
    ) callconv(.c) CTFontRef;
    extern "CoreText" fn CTFontCreateUIFontForLanguage(
        ui_type: u32,
        size: f64,
        language: CFStringRef,
    ) callconv(.c) CTFontRef;
    extern "CoreText" fn CTFontCopyAttribute(
        font: CTFontRef,
        attribute: CFStringRef,
    ) callconv(.c) CFTypeRef;

    extern "CoreText" const kCTFontURLAttribute: CFStringRef;
} else struct {};

pub const Error = error{
    UnsupportedPlatform,
    FontNotFound,
    FontUrlMissing,
    OutOfMemory,
};

/// Resolve a PostScript / family name (e.g. "Helvetica", ".AppleSystemUIFont")
/// to a NUL-terminated filesystem path owned by `allocator`.
pub fn resolveNamedFontPath(allocator: std.mem.Allocator, name: [:0]const u8) Error![:0]u8 {
    if (!is_macos) return error.UnsupportedPlatform;

    const cf_name = MacApi.CFStringCreateWithCString(null, name.ptr, kCFStringEncodingUTF8) orelse {
        return error.FontNotFound;
    };
    defer MacApi.CFRelease(cf_name);

    const font = MacApi.CTFontCreateWithName(cf_name, 12.0, null) orelse return error.FontNotFound;
    defer MacApi.CFRelease(font);

    return pathFromFont(allocator, font);
}

/// Resolve the system UI font (`kCTFontUIFontSystem`) to a filesystem path.
pub fn resolveUiFontPath(allocator: std.mem.Allocator) Error![:0]u8 {
    if (!is_macos) return error.UnsupportedPlatform;

    const font = MacApi.CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12.0, null) orelse {
        return error.FontNotFound;
    };
    defer MacApi.CFRelease(font);

    return pathFromFont(allocator, font);
}

fn pathFromFont(allocator: std.mem.Allocator, font: CTFontRef) Error![:0]u8 {
    if (!is_macos) return error.UnsupportedPlatform;

    const url_obj = MacApi.CTFontCopyAttribute(font, MacApi.kCTFontURLAttribute) orelse {
        return error.FontUrlMissing;
    };
    defer MacApi.CFRelease(url_obj);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (MacApi.CFURLGetFileSystemRepresentation(url_obj, 1, &buf, buf.len) == 0) {
        return error.FontUrlMissing;
    }
    const len = std.mem.len(@as([*:0]const u8, @ptrCast(&buf)));
    return allocator.dupeZ(u8, buf[0..len]) catch return error.OutOfMemory;
}

test "resolveNamedFontPath Helvetica on macOS" {
    if (!is_macos) return;

    const path = try resolveNamedFontPath(std.testing.allocator, "Helvetica");
    defer std.testing.allocator.free(path);
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, path, ".ttf") != null or
        std.mem.indexOf(u8, path, ".ttc") != null or
        std.mem.indexOf(u8, path, ".otf") != null);
}

test "resolveUiFontPath on macOS" {
    if (!is_macos) return;

    const path = try resolveUiFontPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(path.len > 0);
}

test "CoreText helpers unsupported off macOS" {
    if (is_macos) return;
    try std.testing.expectError(error.UnsupportedPlatform, resolveUiFontPath(std.testing.allocator));
    try std.testing.expectError(
        error.UnsupportedPlatform,
        resolveNamedFontPath(std.testing.allocator, "Helvetica"),
    );
}
