//! `std.Thread`, or a stand-in that refuses: the web build has no threads, and every place
//! atlas spawns one already has an inline fallback for a thread that could not be spawned.
//! Routing those sites through this keeps the fallback the only thing the browser needs.
const std = @import("std");
const builtin = @import("builtin");

pub const available = builtin.target.cpu.arch != .wasm32;

pub const Thread = if (available) std.Thread else struct {
    pub fn spawn(_: anytype, comptime _: anytype, _: anytype) error{Unsupported}!Thread {
        return error.Unsupported;
    }
    pub fn join(_: Thread) void {}
    pub fn detach(_: Thread) void {}
    pub fn getCpuCount() error{Unsupported}!usize {
        return 1;
    }
    pub fn yield() error{Unsupported}!void {}
};

/// The boot clock in nanoseconds, from whatever this target can read: the host's `Io`
/// natively (any thread), the frame's high-resolution timer on the web, where that `Io` is
/// the failing one.
pub fn nowNs() i96 {
    const dvui = @import("dvui");
    if (!available) return @intCast(dvui.currentWindow().backend.nanoTime());
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}
