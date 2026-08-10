//! Runtime accessors — backed by `sdk.runtime` and plugin-owned state.
//!
//! Three ways to find our `State`, in order of cost, because a dylib gets its own private copy
//! of every SDK global and none of them is guaranteed populated in every load path.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const State = @import("State.zig");

var owned_state: ?*State = null;

/// `register` points this at the plugin-owned `State` — the fast path for `state()`.
pub fn adoptState(st: *State) void {
    owned_state = st;
}

pub fn allocator() std.mem.Allocator {
    return sdk.allocator();
}

pub fn host() *sdk.Host {
    return sdk.host();
}

pub fn state() *State {
    if (owned_state) |s| return s;
    if (sdk.injectedState(State)) |s| return s;
    const pl = sdk.host().pluginById("atlas") orelse @panic("atlas plugin not registered");
    return @ptrCast(@alignCast(pl.state));
}
