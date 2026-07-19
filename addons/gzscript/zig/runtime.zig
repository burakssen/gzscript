const std = @import("std");
const abi = @import("abi.zig");

pub var engine_api: ?*const abi.EngineApi = null;

pub const InitContext = struct {
    owner: u64,
    allocator: std.mem.Allocator,
};

pub const Object = struct {
    owner: u64,

    pub fn call(self: Object, method: []const u8, arguments: []const abi.Value) !abi.Value {
        const api = engine_api orelse return error.EngineNotReady;
        var result = abi.Value{};
        const status = api.object_call(self.owner, .from(method), if (arguments.len == 0) null else arguments.ptr, @intCast(arguments.len), &result);
        if (status != .ok) return error.CallFailed;
        return result;
    }
};

pub const log = struct {
    pub fn info(comptime format: []const u8, arguments: anytype) void {
        const api = engine_api orelse return;
        var buffer: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, format, arguments) catch return;
        api.log_info(.from(message));
    }

    pub fn err(comptime format: []const u8, arguments: anytype) void {
        const api = engine_api orelse return;
        var buffer: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, format, arguments) catch return;
        api.log_error(.from(message));
    }
};
