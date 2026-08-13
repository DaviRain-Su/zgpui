//! Headless animation clock: easing curves, tweens, springs, and a fixed-slot
//! timeline. Components tick values each frame — not a CSS animation engine.

const std = @import("std");
const color = @import("color.zig");

const Rgba = color.Rgba;

/// Default fade duration for overlay enter/exit tweens.
pub const default_fade_ms: f32 = 150;

pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
};

pub const AnimationId = u64;

pub fn animationId(name: []const u8) AnimationId {
    return std.hash.Wyhash.hash(0x4e1a0711, name);
}

/// Map normalized time `t` in 0..1 through an easing curve.
pub fn ease(easing: Easing, t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    return switch (easing) {
        .linear => x,
        .ease_in => x * x * x,
        .ease_out => {
            const u = 1 - x;
            return 1 - u * u * u;
        },
        .ease_in_out => if (x < 0.5)
            4 * x * x * x
        else
            1 - std.math.pow(f32, -2 * x + 2, 3) / 2,
    };
}

pub const Tween = struct {
    from: f32,
    to: f32,
    duration_ms: f32,
    elapsed_ms: f32 = 0,
    easing: Easing = .ease_in_out,

    pub fn tick(self: *Tween, dt_ms: f32) f32 {
        if (self.duration_ms <= 0) {
            self.elapsed_ms = self.duration_ms;
            return self.to;
        }
        self.elapsed_ms += dt_ms;
        const t = std.math.clamp(self.elapsed_ms / self.duration_ms, 0, 1);
        const eased = ease(self.easing, t);
        return self.from + (self.to - self.from) * eased;
    }

    pub fn finished(self: *const Tween) bool {
        return self.elapsed_ms >= self.duration_ms;
    }

    pub fn reset(self: *Tween) void {
        self.elapsed_ms = 0;
    }
};

pub const Spring = struct {
    value: f32 = 0,
    velocity: f32 = 0,
    target: f32 = 0,
    stiffness: f32 = 180,
    damping: f32 = 20,

    pub const settle_epsilon: f32 = 0.001;

    pub fn tick(self: *Spring, dt_ms: f32) f32 {
        const dt = dt_ms / 1000.0;
        const displacement = self.value - self.target;
        const acceleration = -self.stiffness * displacement - self.damping * self.velocity;
        self.velocity += acceleration * dt;
        self.value += self.velocity * dt;
        return self.value;
    }

    pub fn settled(self: *const Spring) bool {
        const displacement = @abs(self.value - self.target);
        const speed = @abs(self.velocity);
        return displacement < settle_epsilon and speed < settle_epsilon;
    }
};

const max_slots = 32;

const Anim = union(enum) {
    tween: Tween,
    spring: Spring,
};

const Slot = struct {
    id: AnimationId = 0,
    active: bool = false,
    anim: Anim,

    fn inactive() Slot {
        return .{
            .id = 0,
            .active = false,
            .anim = .{ .tween = .{ .from = 0, .to = 0, .duration_ms = 0 } },
        };
    }
};

pub const Timeline = struct {
    slots: [max_slots]Slot,

    pub fn init() Timeline {
        var timeline: Timeline = undefined;
        for (&timeline.slots) |*slot| slot.* = Slot.inactive();
        return timeline;
    }

    pub fn startTween(self: *Timeline, id: AnimationId, tween: Tween) void {
        const slot_index = self.findOrAllocSlot(id) orelse 0;
        self.slots[slot_index] = .{
            .id = id,
            .active = true,
            .anim = .{ .tween = tween },
        };
    }

    pub fn startSpring(self: *Timeline, id: AnimationId, spring: Spring) void {
        const slot_index = self.findOrAllocSlot(id) orelse 0;
        self.slots[slot_index] = .{
            .id = id,
            .active = true,
            .anim = .{ .spring = spring },
        };
    }

    /// Advance all active animations. Returns `true` when any slot still needs frames.
    pub fn tick(self: *Timeline, dt_ms: f32) bool {
        var any_active = false;
        for (&self.slots) |*slot| {
            if (!slot.active) continue;
            switch (slot.anim) {
                .tween => |*t| {
                    _ = t.tick(dt_ms);
                    if (t.finished()) {
                        slot.active = false;
                    } else {
                        any_active = true;
                    }
                },
                .spring => |*s| {
                    _ = s.tick(dt_ms);
                    if (s.settled()) {
                        slot.active = false;
                    } else {
                        any_active = true;
                    }
                },
            }
        }
        return any_active;
    }

    pub fn value(self: *const Timeline, id: AnimationId) ?f32 {
        for (self.slots) |slot| {
            if (slot.id != id) continue;
            return switch (slot.anim) {
                .tween => |t| {
                    if (!slot.active or t.finished()) return t.to;
                    return t.from + (t.to - t.from) * ease(t.easing, std.math.clamp(t.elapsed_ms / t.duration_ms, 0, 1));
                },
                .spring => |s| if (!slot.active and s.settled()) s.target else s.value,
            };
        }
        return null;
    }

    pub fn isActive(self: *const Timeline, id: AnimationId) bool {
        for (self.slots) |slot| {
            if (slot.active and slot.id == id) return true;
        }
        return false;
    }

    fn findOrAllocSlot(self: *Timeline, id: AnimationId) ?usize {
        var empty: ?usize = null;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.id == id) return i;
            if (!slot.active and empty == null) empty = i;
        }
        return empty;
    }
};

/// Start a 0→1 opacity tween when no animation is already running for `id`.
pub fn fadeIn(timeline: *Timeline, id: AnimationId, duration_ms: f32) void {
    if (timeline.isActive(id)) return;
    if (timeline.value(id) != null) return;
    timeline.startTween(id, .{
        .from = 0,
        .to = 1,
        .duration_ms = duration_ms,
        .easing = .ease_out,
    });
}

/// Start a fade to 0 from the current value (or 1 when inactive).
pub fn fadeOut(timeline: *Timeline, id: AnimationId, duration_ms: f32) void {
    const from = timeline.value(id) orelse 1;
    timeline.startTween(id, .{
        .from = from,
        .to = 0,
        .duration_ms = duration_ms,
        .easing = .ease_in,
    });
}

/// Current tween/spring value for `id`, or `fallback` when inactive.
pub fn opacityOf(timeline: *const Timeline, id: AnimationId, fallback: f32) f32 {
    return timeline.value(id) orelse fallback;
}

/// Multiply an existing color alpha by normalized opacity.
pub fn scaleAlpha(c: Rgba, opacity: f32) Rgba {
    return c.withAlpha(c.a * std.math.clamp(opacity, 0, 1));
}

/// Tracks monotonic deltas and ticks a timeline each frame.
pub const AnimationClock = struct {
    last_ns: ?u128 = null,
    /// Delta in ms from the most recent `tick`/`tickAt` call.
    last_dt_ms: f32 = 0,

    pub fn reset(self: *AnimationClock) void {
        self.last_ns = null;
        self.last_dt_ms = 0;
    }

    /// Returns `true` when the timeline still has active animations.
    pub fn tick(self: *AnimationClock, timeline: *Timeline) bool {
        return self.tickAt(timeline, monotonicNowNs());
    }

    /// Advance with an explicit monotonic timestamp in nanoseconds.
    pub fn tickAt(self: *AnimationClock, timeline: *Timeline, now_ns: u128) bool {
        const dt_ms: f32 = if (self.last_ns) |last|
            @as(f32, @floatFromInt(now_ns - last)) / @as(f32, @floatFromInt(std.time.ns_per_ms))
        else
            0;
        self.last_ns = now_ns;
        self.last_dt_ms = dt_ms;
        return timeline.tick(dt_ms);
    }

    /// Advance with an explicit delta (unit tests, fixed-step loops).
    pub fn advance(self: *AnimationClock, timeline: *Timeline, dt_ms: f32) bool {
        _ = self;
        return timeline.tick(dt_ms);
    }
};

pub fn monotonicNowNs() u128 {
    const c = std.c;
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos, .visionos => {
            var timebase: c.mach_timebase_info_data = undefined;
            _ = c.mach_timebase_info(&timebase);
            const ticks = c.mach_absolute_time();
            return @as(u128, ticks) * timebase.numer / timebase.denom;
        },
        else => {
            var ts: c.timespec = undefined;
            if (c.clock_gettime(c.CLOCK.MONOTONIC, &ts) != 0) return 0;
            return @as(u128, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u128, @intCast(ts.tv_nsec));
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ease curves are monotonic endpoints" {
    try std.testing.expectEqual(@as(f32, 0), ease(.linear, 0));
    try std.testing.expectEqual(@as(f32, 1), ease(.linear, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), ease(.ease_in, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.875), ease(.ease_out, 0.5), 0.001);
    try std.testing.expectEqual(@as(f32, 0), ease(.ease_in_out, 0));
    try std.testing.expectEqual(@as(f32, 1), ease(.ease_in_out, 1));
}

test "tween finishes and clamps" {
    var tween: Tween = .{
        .from = 0,
        .to = 100,
        .duration_ms = 100,
        .easing = .linear,
    };
    const mid = tween.tick(50);
    try std.testing.expectApproxEqAbs(@as(f32, 50), mid, 0.001);
    try std.testing.expect(!tween.finished());

    const end = tween.tick(50);
    try std.testing.expectApproxEqAbs(@as(f32, 100), end, 0.001);
    try std.testing.expect(tween.finished());

    const past = tween.tick(10);
    try std.testing.expectApproxEqAbs(@as(f32, 100), past, 0.001);

    tween.reset();
    try std.testing.expectEqual(@as(f32, 0), tween.elapsed_ms);
    try std.testing.expect(!tween.finished());
}

test "spring settles toward target" {
    var spring: Spring = .{
        .value = 0,
        .velocity = 0,
        .target = 1,
        .stiffness = 200,
        .damping = 26,
    };
    var i: usize = 0;
    while (i < 500 and !spring.settled()) : (i += 1) {
        _ = spring.tick(16);
    }
    try std.testing.expect(spring.settled());
    try std.testing.expectApproxEqAbs(@as(f32, 1), spring.value, 0.01);
}

test "timeline replace-by-id and value lookup" {
    var timeline = Timeline.init();
    const id = animationId("opacity");

    timeline.startTween(id, .{
        .from = 0,
        .to = 1,
        .duration_ms = 100,
        .easing = .linear,
    });
    try std.testing.expect(timeline.isActive(id));
    _ = timeline.tick(50);
    const half = timeline.value(id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), half, 0.001);

    timeline.startTween(id, .{
        .from = half,
        .to = 0,
        .duration_ms = 100,
        .easing = .linear,
    });
    _ = timeline.tick(50);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), timeline.value(id).?, 0.001);
}

test "timeline tick requests redraw while animating" {
    var timeline = Timeline.init();
    const id = animationId("slide");
    timeline.startTween(id, .{
        .from = 0,
        .to = 10,
        .duration_ms = 32,
        .easing = .linear,
    });

    try std.testing.expect(timeline.tick(16));
    try std.testing.expect(timeline.isActive(id));
    try std.testing.expect(!timeline.tick(16));
    try std.testing.expect(!timeline.isActive(id));
}

test "animationId is stable" {
    try std.testing.expectEqual(animationId("fade"), animationId("fade"));
    try std.testing.expect(animationId("fade") != animationId("slide"));
}

test "fade helpers drive opacity" {
    var timeline = Timeline.init();
    const id = animationId("overlay-fade");

    timeline.startTween(id, .{
        .from = 0,
        .to = 1,
        .duration_ms = 100,
        .easing = .linear,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 0), opacityOf(&timeline, id, 1), 0.001);

    _ = timeline.tick(50);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), opacityOf(&timeline, id, 1), 0.001);

    _ = timeline.tick(50);
    try std.testing.expectApproxEqAbs(@as(f32, 1), opacityOf(&timeline, id, 1), 0.001);
    try std.testing.expect(!timeline.isActive(id));

    timeline.startTween(id, .{
        .from = 1,
        .to = 0,
        .duration_ms = 100,
        .easing = .linear,
    });
    _ = timeline.tick(50);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), opacityOf(&timeline, id, 1), 0.001);

    _ = timeline.tick(50);
    try std.testing.expectApproxEqAbs(@as(f32, 0), opacityOf(&timeline, id, 1), 0.001);
}

test "fadeIn is idempotent while active" {
    var timeline = Timeline.init();
    const id = animationId("once");
    fadeIn(&timeline, id, 200);
    _ = timeline.tick(50);
    const mid = opacityOf(&timeline, id, 1);
    fadeIn(&timeline, id, 200);
    try std.testing.expectApproxEqAbs(mid, opacityOf(&timeline, id, 1), 0.001);
}

test "fadeIn survives ensureFadeIn after completion" {
    var timeline = Timeline.init();
    const id = animationId("dialog-fade-fade-dialog");

    fadeIn(&timeline, id, 150);
    try std.testing.expectApproxEqAbs(0, opacityOf(&timeline, id, 1), 0.001);
    _ = timeline.tick(150);

    fadeIn(&timeline, id, 150);
    try std.testing.expectApproxEqAbs(1, opacityOf(&timeline, id, 1), 0.05);
}

test "scaleAlpha multiplies alpha" {
    const c = Rgba.fromHex(0xff0000).withAlpha(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), scaleAlpha(c, 0.5).a, 0.001);
}

test "window-style clock drives timeline" {
    var timeline = Timeline.init();
    var clock: AnimationClock = .{};
    const id = animationId("demo");

    timeline.startSpring(id, .{
        .value = 0,
        .target = 1,
        .stiffness = 120,
        .damping = 18,
    });

    var frames: usize = 0;
    var last_value: f32 = 0;
    while (frames < 300) : (frames += 1) {
        if (timeline.value(id)) |v| last_value = v;
        if (!clock.advance(&timeline, 16)) break;
    }
    try std.testing.expect(frames > 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), last_value, 0.05);
}
