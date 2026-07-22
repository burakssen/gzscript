const std = @import("std");
const abi = @import("abi.zig");
const runtime = @import("runtime.zig");
const support = @import("class_support.zig");

const TestObject = extern struct { owner: u64 };

var bind_lookups: usize = 0;
var ptrcalls: usize = 0;
var return_null_bind = false;

fn discardLog(_: abi.StringView) callconv(.c) void {}
fn discardCall(_: u64, _: abi.StringView, _: ?[*]const abi.Value, _: u32, _: *abi.Value) callconv(.c) abi.Status {
    return .ok;
}
fn discardSignal(_: u64, _: abi.StringView, _: ?[*]const abi.Value, _: u32) callconv(.c) abi.Status {
    return .ok;
}
fn getMethodBind(_: abi.StringView, _: abi.StringView, _: i64) callconv(.c) abi.MethodBind {
    bind_lookups += 1;
    if (return_null_bind) return null;
    return @ptrFromInt(1);
}
fn ptrcall(_: abi.MethodBind, _: u64, _: ?[*]const ?*const anyopaque, result: ?*anyopaque) callconv(.c) abi.Status {
    ptrcalls += 1;
    if (result) |pointer| @as(*bool, @ptrCast(@alignCast(pointer))).* = true;
    return .ok;
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
};

test "cached ptrcall resolves each method metadata tuple once" {
    runtime.engine_api = &engine_api;
    bind_lookups = 0;
    ptrcalls = 0;
    return_null_bind = false;
    const object = TestObject{ .owner = 42 };

    try std.testing.expect(try support.ptrcallMethod(object, bool, "TestObject", "ready_a", 1, .{}));
    try std.testing.expect(try support.ptrcallMethod(object, bool, "TestObject", "ready_a", 1, .{}));
    try std.testing.expect(try support.ptrcallMethod(object, bool, "TestObject", "ready_b", 2, .{}));

    try std.testing.expectEqual(@as(usize, 2), bind_lookups);
    try std.testing.expectEqual(@as(usize, 3), ptrcalls);
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
