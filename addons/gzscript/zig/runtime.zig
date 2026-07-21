const std = @import("std");
const abi = @import("abi.zig");
const codec = @import("codec.zig");

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
        switch (status) {
            .ok => {},
            .invalid_argument => return error.InvalidArgument,
            .method_not_found => return error.MethodNotFound,
            .property_not_found => return error.PropertyNotFound,
            .type_mismatch => return error.TypeMismatch,
            .out_of_memory => return error.OutOfMemory,
            .script_error => return error.ScriptError,
            .abi_mismatch => return error.AbiMismatch,
        }
        return result;
    }

    pub fn emitSignal(self: Object, name: []const u8, arguments: anytype) !void {
        const values = codec.arguments(arguments);
        const api = engine_api orelse return error.EngineNotReady;
        const status = api.object_emit_signal(self.owner, .from(name), if (values.len == 0) null else &values, values.len);
        if (status != .ok) return error.EmitSignalFailed;
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

pub fn getMethodBind(class_name: []const u8, method_name: []const u8, hash: i64) abi.MethodBind {
    const api = engine_api orelse return null;
    return api.get_method_bind(.from(class_name), .from(method_name), hash);
}

pub fn ptrcall(method_bind: abi.MethodBind, object_id: u64, args: ?[*]const ?*const anyopaque, result: ?*anyopaque) !void {
    const api = engine_api orelse return error.EngineNotReady;
    const status = api.object_ptrcall(method_bind, object_id, args, result);
    if (status != .ok) return error.PtrCallFailed;
}
