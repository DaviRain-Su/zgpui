//! Embedded Solar / hand-drawn icon catalog (ProofShip comet-kit assets).
//!
//! Low-level only: path constants + SVG bytes. zgpui does **not** ship an SVG
//! renderer yet — apps (or a future paint helper) consume [`load`].
//!
//! Attribution: [`src/assets/ATTRIBUTION.md`](assets/ATTRIBUTION.md).

const std = @import("std");
const color = @import("color.zig");

const Rgba = color.Rgba;

const Entry = struct {
    path: []const u8,
    bytes: []const u8,
};

fn entry(comptime file: []const u8) Entry {
    return .{
        .path = "icons/" ++ file ++ ".svg",
        .bytes = @embedFile("assets/icons/" ++ file ++ ".svg"),
    };
}

/// Logical path constants (`icons/<name>.svg`), matching comet-kit.
pub const monitor = "icons/monitor.svg";
pub const laptop = "icons/laptop.svg";
pub const pen_new_square = "icons/pen-new-square.svg";
pub const sort_vertical = "icons/sort-vertical.svg";
pub const list = "icons/list.svg";
pub const folder_with_files = "icons/folder-with-files.svg";
pub const folder = "icons/folder.svg";
pub const git_branch = "icons/git-branch.svg";
pub const sidebar_minimalistic = "icons/sidebar-minimalistic.svg";
pub const sidebar_minimalistic_left = "icons/sidebar-minimalistic-left.svg";
pub const key_minimalistic = "icons/key-minimalistic.svg";
pub const keyboard = "icons/keyboard.svg";
pub const arrow_left = "icons/arrow-left.svg";
pub const arrow_right = "icons/arrow-right.svg";
pub const arrow_up = "icons/arrow-up.svg";
pub const arrow_down = "icons/arrow-down.svg";
pub const return_key = "icons/return.svg";
pub const alt_arrow_down = "icons/alt-arrow-down.svg";
pub const expand_arrows = "icons/expand-arrows.svg";
pub const fold_vertical = "icons/fold-vertical.svg";
pub const alt_arrow_left = "icons/alt-arrow-left.svg";
pub const alt_arrow_right = "icons/alt-arrow-right.svg";
pub const smartphone = "icons/smartphone.svg";
pub const archive_up_minimalistic = "icons/archive-up-minimalistic.svg";
pub const refresh = "icons/refresh.svg";
pub const restart = "icons/restart.svg";
pub const add_circle = "icons/add-circle.svg";
pub const tuning = "icons/tuning.svg";
pub const paperclip = "icons/paperclip.svg";
pub const pen = "icons/pen.svg";
pub const archive_minimalistic = "icons/archive-minimalistic.svg";
pub const trash_bin_minimalistic = "icons/trash-bin-minimalistic.svg";
pub const settings_minimalistic = "icons/settings-minimalistic.svg";
pub const logout_2 = "icons/logout-2.svg";
pub const magnifer = "icons/magnifer.svg";
pub const command = "icons/command.svg";
pub const document = "icons/document.svg";
pub const document_add = "icons/document-add.svg";
pub const global = "icons/global.svg";
pub const checklist = "icons/checklist.svg";
pub const widget = "icons/widget.svg";
pub const wifi_off = "icons/wifi-off.svg";
pub const close_circle = "icons/close-circle.svg";
pub const info_circle = "icons/info-circle.svg";
pub const danger_triangle = "icons/danger-triangle.svg";
pub const chat_round_line = "icons/chat-round-line.svg";
pub const bell = "icons/bell.svg";
pub const volume_loud = "icons/volume-loud.svg";
pub const terminal = "icons/terminal.svg";
pub const plus = "icons/plus.svg";
pub const close = "icons/close.svg";
pub const stop = "icons/stop.svg";
pub const check = "icons/check.svg";
pub const copy = "icons/copy.svg";
pub const comet_logo = "icons/comet-logo.svg";
pub const claude_mark = "icons/claude-mark.svg";
pub const openai_mark = "icons/openai-mark.svg";
pub const cursor_mark = "icons/cursor-mark.svg";
pub const grok_mark = "icons/grok-mark.svg";
pub const hermes_mark = "icons/hermes-mark.svg";
pub const pi_mark = "icons/pi-mark.svg";

const catalog = [_]Entry{
    entry("monitor"),
    entry("laptop"),
    entry("pen-new-square"),
    entry("sort-vertical"),
    entry("list"),
    entry("folder-with-files"),
    entry("folder"),
    entry("git-branch"),
    entry("sidebar-minimalistic"),
    entry("sidebar-minimalistic-left"),
    entry("key-minimalistic"),
    entry("keyboard"),
    entry("arrow-left"),
    entry("arrow-right"),
    entry("arrow-up"),
    entry("arrow-down"),
    entry("return"),
    entry("alt-arrow-down"),
    entry("expand-arrows"),
    entry("fold-vertical"),
    entry("alt-arrow-left"),
    entry("alt-arrow-right"),
    entry("smartphone"),
    entry("archive-up-minimalistic"),
    entry("refresh"),
    entry("restart"),
    entry("add-circle"),
    entry("tuning"),
    entry("paperclip"),
    entry("pen"),
    entry("archive-minimalistic"),
    entry("trash-bin-minimalistic"),
    entry("settings-minimalistic"),
    entry("logout-2"),
    entry("magnifer"),
    entry("command"),
    entry("document"),
    entry("document-add"),
    entry("global"),
    entry("checklist"),
    entry("widget"),
    entry("wifi-off"),
    entry("close-circle"),
    entry("info-circle"),
    entry("danger-triangle"),
    entry("chat-round-line"),
    entry("bell"),
    entry("volume-loud"),
    entry("terminal"),
    entry("plus"),
    entry("close"),
    entry("stop"),
    entry("check"),
    entry("copy"),
    entry("comet-logo"),
    entry("claude-mark"),
    entry("openai-mark"),
    entry("cursor-mark"),
    entry("grok-mark"),
    entry("hermes-mark"),
    entry("pi-mark"),
};

/// Look up embedded SVG bytes by logical path (`icons/….svg`).
pub fn load(path: []const u8) ?[]const u8 {
    for (catalog) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.bytes;
    }
    return null;
}

/// All registered logical paths (stable order).
pub fn paths() []const []const u8 {
    const paths_list = comptime blk: {
        var out: [catalog.len][]const u8 = undefined;
        for (catalog, 0..) |e, i| out[i] = e.path;
        break :blk out;
    };
    return &paths_list;
}

/// Claude mark brand orange (`#D97757`).
pub fn claudeBrand() Rgba {
    return Rgba.fromHex(0xd97757);
}

test "every registered icon loads as svg" {
    for (paths()) |path| {
        const bytes = load(path) orelse return error.MissingIcon;
        try std.testing.expect(bytes.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "<svg") != null);
    }
}

test "unknown path is null" {
    try std.testing.expect(load("icons/nope.svg") == null);
}
