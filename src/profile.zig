//! Lightweight per-frame CPU phase profiler for `Window.renderFrame`.
//!
//! Uses monotonic timestamps (no `std.time.Timer` in Zig 0.16). When disabled,
//! scopes are inert and `beginFrame` / `recordTotal` return immediately.

const std = @import("std");
const builtin = @import("builtin");

pub const Phase = enum {
    build_layout,
    prepaint,
    paint,
    overlays,
    atlas,
    gpu,
    total,
    count_,
};

pub const FrameStats = struct {
    /// Nanoseconds recorded for each phase during the last profiled frame.
    ns: [@intFromEnum(Phase.count_)]u64 = .{0} ** @intFromEnum(Phase.count_),

    pub fn ms(self: FrameStats, phase: Phase) f64 {
        return nsToMs(self.ns[@intFromEnum(phase)]);
    }
};

pub const Profiler = struct {
    enabled: bool = false,
    last: FrameStats = .{},
    /// Rolling window of total frame times (most recent 60 frames).
    ring_total_ns: [60]u64 = .{0} ** 60,
    ring_i: u8 = 0,
    ring_filled: u8 = 0,

    pub fn beginFrame(self: *Profiler) void {
        if (!self.enabled) return;
        self.last = .{};
    }

    pub fn scope(self: *Profiler, phase: Phase) Scope {
        return .{
            .profiler = self,
            .phase = phase,
            .start_ns = if (self.enabled) monotonicNowNs() else 0,
            .active = self.enabled,
        };
    }

    pub fn recordTotal(self: *Profiler, total_ns: u64) void {
        if (!self.enabled) return;
        self.last.ns[@intFromEnum(Phase.total)] = total_ns;
        self.ring_total_ns[self.ring_i] = total_ns;
        self.ring_i = @intCast((self.ring_i + 1) % self.ring_total_ns.len);
        if (self.ring_filled < self.ring_total_ns.len) self.ring_filled += 1;
    }

    pub fn avgTotalMs(self: *const Profiler) f64 {
        const n: usize = self.ring_filled;
        if (n == 0) return 0;
        var sum: u64 = 0;
        for (self.ring_total_ns[0..n]) |v| sum += v;
        return nsToMs(sum) / @as(f64, @floatFromInt(n));
    }

    pub fn lastMs(self: *const Profiler, phase: Phase) f64 {
        return self.last.ms(phase);
    }
};

pub const Scope = struct {
    profiler: *Profiler,
    phase: Phase,
    start_ns: u128,
    active: bool,

    pub fn end(self: *Scope) void {
        if (!self.active) return;
        const elapsed = monotonicNowNs() - self.start_ns;
        self.profiler.last.ns[@intFromEnum(self.phase)] += @intCast(elapsed);
    }
};

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

var test_now_ns: u128 = 0;
var use_test_clock: bool = false;

fn monotonicNowNs() u128 {
    if (builtin.is_test and use_test_clock) return test_now_ns;
    return monotonicNowNsImpl();
}

/// Monotonic timestamp for frame wall-clock timing (used by `Window.renderFrame`).
pub fn nowNs() u128 {
    return monotonicNowNs();
}

fn monotonicNowNsImpl() u128 {
    switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos, .visionos => {
            const c = std.c;
            var timebase: c.mach_timebase_info_data = undefined;
            _ = c.mach_timebase_info(&timebase);
            const ticks = c.mach_absolute_time();
            return @as(u128, ticks) * timebase.numer / timebase.denom;
        },
        .windows => {
            const w = std.os.windows;
            var freq: w.LARGE_INTEGER = undefined;
            var counter: w.LARGE_INTEGER = undefined;
            if (w.QueryPerformanceFrequency(&freq) == 0 or freq == 0) return 0;
            if (w.QueryPerformanceCounter(&counter) == 0) return 0;
            return @as(u128, @intCast(counter)) * std.time.ns_per_s / @as(u128, @intCast(freq));
        },
        else => {
            const c = std.c;
            // Zig 0.16 `std.c.timespec` uses `sec` / `nsec` (not POSIX `tv_*`).
            var ts: c.timespec = undefined;
            if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
            return @as(u128, @intCast(ts.sec)) * std.time.ns_per_s + @as(u128, @intCast(ts.nsec));
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "FrameStats.ms converts nanoseconds" {
    var stats: FrameStats = .{};
    stats.ns[@intFromEnum(Phase.paint)] = 2 * std.time.ns_per_ms;
    try std.testing.expectApproxEqAbs(2.0, stats.ms(.paint), 0.001);
}

test "Scope accumulates elapsed time when enabled" {
    use_test_clock = true;
    defer {
        use_test_clock = false;
        test_now_ns = 0;
    }

    var profiler: Profiler = .{ .enabled = true };
    profiler.beginFrame();

    test_now_ns = 1_000;
    var scope = profiler.scope(.paint);
    test_now_ns = 4_000;
    scope.end();

    try std.testing.expectEqual(@as(u64, 3_000), profiler.last.ns[@intFromEnum(Phase.paint)]);
}

test "avgTotalMs averages last N total records" {
    var profiler: Profiler = .{ .enabled = true };
    profiler.recordTotal(1 * std.time.ns_per_ms);
    profiler.recordTotal(2 * std.time.ns_per_ms);
    profiler.recordTotal(3 * std.time.ns_per_ms);
    try std.testing.expectApproxEqAbs(2.0, profiler.avgTotalMs(), 0.001);
}

test "disabled profiler is a no-op" {
    use_test_clock = true;
    defer {
        use_test_clock = false;
        test_now_ns = 0;
    }

    var profiler: Profiler = .{ .enabled = false };
    profiler.beginFrame();

    test_now_ns = 0;
    var scope = profiler.scope(.gpu);
    test_now_ns = 1_000_000;
    scope.end();
    profiler.recordTotal(1_000_000);

    try std.testing.expectEqual(@as(u64, 0), profiler.last.ns[@intFromEnum(Phase.gpu)]);
    try std.testing.expectEqual(@as(u64, 0), profiler.last.ns[@intFromEnum(Phase.total)]);
    try std.testing.expectEqual(@as(u8, 0), profiler.ring_filled);
    try std.testing.expectApproxEqAbs(0, profiler.avgTotalMs(), 0.001);
}

test "beginFrame clears last stats" {
    var profiler: Profiler = .{ .enabled = true };
    profiler.last.ns[@intFromEnum(Phase.paint)] = 999;
    profiler.beginFrame();
    try std.testing.expectEqual(@as(u64, 0), profiler.last.ns[@intFromEnum(Phase.paint)]);
}
