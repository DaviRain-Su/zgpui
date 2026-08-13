//! macOS glue: attach a CAMetalLayer to a GLFW window's NSView.
//!
//! glfw3native.h cannot be translated by translate-c (it pulls in Objective-C
//! headers), so `glfwGetCocoaWindow` is declared manually and the Cocoa calls
//! go through `objc_msgSend` casted to properly-typed function pointers.

const std = @import("std");
const glfw = @import("glfw_c");
const objc = @import("objc_c");

extern fn glfwGetCocoaWindow(window: ?*glfw.GLFWwindow) callconv(.c) ?*anyopaque;

pub const Error = error{
    NoCocoaWindow,
    NoContentView,
    MissingCAMetalLayerClass,
    MetalLayerCreationFailed,
};

/// Creates a CAMetalLayer, makes the window's content view layer-backed, and
/// installs the layer. Returns the CAMetalLayer* for use as a wgpu surface
/// source. `contents_scale` should be the window's content scale factor so
/// the layer renders at native (retina) resolution.
pub fn attach(window: ?*glfw.GLFWwindow, contents_scale: f64) Error!*anyopaque {
    // objc_msgSend is declared variadic-less in the runtime headers; each call
    // site must cast it to the correct concrete signature.
    const msgId: *const fn (objc.id, objc.SEL) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    const msgClassId: *const fn (objc.Class, objc.SEL) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    const msgSetBool: *const fn (objc.id, objc.SEL, bool) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const msgSetId: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const msgSetF64: *const fn (objc.id, objc.SEL, f64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);

    const ns_window_ptr = glfwGetCocoaWindow(window) orelse return error.NoCocoaWindow;
    const ns_window: objc.id = @ptrCast(@alignCast(ns_window_ptr));

    // [nsWindow contentView]
    const content_view = msgId(ns_window, objc.sel_registerName("contentView"));
    if (content_view == null) return error.NoContentView;

    // [CAMetalLayer layer]
    const layer_class = objc.objc_getClass("CAMetalLayer") orelse
        return error.MissingCAMetalLayerClass;
    const layer = msgClassId(layer_class, objc.sel_registerName("layer"));
    if (layer == null) return error.MetalLayerCreationFailed;

    // [layer setContentsScale:scale]  (CGFloat is f64 on 64-bit)
    msgSetF64(layer, objc.sel_registerName("setContentsScale:"), contents_scale);
    // [contentView setWantsLayer:YES]; [contentView setLayer:layer]
    msgSetBool(content_view, objc.sel_registerName("setWantsLayer:"), true);
    msgSetId(content_view, objc.sel_registerName("setLayer:"), layer);

    return @ptrCast(layer);
}
