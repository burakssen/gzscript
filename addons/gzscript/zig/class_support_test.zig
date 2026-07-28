const std = @import("std");
const abi = @import("abi.zig");
const runtime = @import("runtime.zig");
const support = @import("class_support.zig");

const TestObject = extern struct { owner: u64 };

var bind_lookups = std.atomic.Value(usize).init(0);
var ptrcalls = std.atomic.Value(usize).init(0);
var return_null_bind = false;
const concurrent_workers = 8;
const concurrent_hash = 4;
var workers_started = std.atomic.Value(usize).init(0);
var worker_failures = std.atomic.Value(usize).init(0);

fn discardLog(_: abi.StringView) callconv(.c) void {}
fn discardCall(_: u64, _: abi.StringView, _: ?[*]const abi.Value, _: u32, _: *abi.Value) callconv(.c) abi.Status {
    return .ok;
}
fn discardSignal(_: u64, _: abi.StringView, _: ?[*]const abi.Value, _: u32) callconv(.c) abi.Status {
    return .ok;
}
fn getMethodBind(_: abi.StringView, _: abi.StringView, hash: i64) callconv(.c) abi.MethodBind {
    _ = bind_lookups.fetchAdd(1, .monotonic);
    if (hash == concurrent_hash) {
        while (workers_started.load(.acquire) != concurrent_workers) std.atomic.spinLoopHint();
    }
    if (return_null_bind) return null;
    return @ptrFromInt(1);
}
fn ptrcall(_: abi.MethodBind, _: u64, _: ?[*]const ?*const anyopaque, result: ?*anyopaque) callconv(.c) abi.Status {
    _ = ptrcalls.fetchAdd(1, .monotonic);
    if (result) |pointer| @as(*bool, @ptrCast(@alignCast(pointer))).* = true;
    return .ok;
}
fn zeroTicks() callconv(.c) u64 {
    return 0;
}

const engine_api = abi.EngineApi{
    .abi_version = abi.abi_version,
    .struct_size = @sizeOf(abi.EngineApi),
    .log_info = discardLog,
    .log_error = discardLog,
    .object_call = discardCall,
    .object_emit_signal = discardSignal,
    .get_method_bind = getMethodBind,
    .object_ptrcall = ptrcall,
    .get_ticks_usec = zeroTicks,
};

fn callConcurrentMethod(object: TestObject) void {
    _ = workers_started.fetchAdd(1, .release);
    const result = support.ptrcallMethod(object, bool, "TestObject", "concurrent", concurrent_hash, .{}) catch {
        _ = worker_failures.fetchAdd(1, .monotonic);
        return;
    };
    if (!result) _ = worker_failures.fetchAdd(1, .monotonic);
}

test "cached ptrcall resolves each method metadata tuple once" {
    runtime.engine_api = &engine_api;
    bind_lookups.store(0, .monotonic);
    ptrcalls.store(0, .monotonic);
    return_null_bind = false;
    const object = TestObject{ .owner = 42 };

    try std.testing.expect(try support.ptrcallMethod(object, bool, "TestObject", "ready_a", 1, .{}));
    try std.testing.expect(try support.ptrcallMethod(object, bool, "TestObject", "ready_a", 1, .{}));
    try std.testing.expect(try support.ptrcallMethod(object, bool, "TestObject", "ready_b", 2, .{}));

    try std.testing.expectEqual(@as(usize, 2), bind_lookups.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), ptrcalls.load(.monotonic));
}

test "missing method bind returns an error" {
    runtime.engine_api = &engine_api;
    return_null_bind = true;
    const object = TestObject{ .owner = 42 };

    try std.testing.expectError(
        error.MethodBindNotFound,
        support.ptrcallMethod(object, bool, "MissingObject", "missing", 3, .{}),
    );
}

test "concurrent ptrcalls initialize a method bind once" {
    runtime.engine_api = &engine_api;
    bind_lookups.store(0, .monotonic);
    ptrcalls.store(0, .monotonic);
    workers_started.store(0, .monotonic);
    worker_failures.store(0, .monotonic);
    return_null_bind = false;
    const object = TestObject{ .owner = 42 };

    var threads: [concurrent_workers]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, callConcurrentMethod, .{object});
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), worker_failures.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), bind_lookups.load(.monotonic));
    try std.testing.expectEqual(@as(usize, concurrent_workers), ptrcalls.load(.monotonic));
}
