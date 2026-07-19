const std = @import("std");
const abi = @import("abi.zig");
const properties = @import("property.zig");

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

    pub fn emit_signal(self: Object, name: []const u8, arguments: anytype) !void {
        const fields = @typeInfo(@TypeOf(arguments)).@"struct".fields;
        var values: [fields.len]abi.Value = undefined;
        inline for (fields, 0..) |field, index| {
            const value = @field(arguments, field.name);
            values[index] = if (@typeInfo(@TypeOf(value)) == .@"struct" and @hasField(@TypeOf(value), "owner"))
                .{ .type = .object, .data = .{ .object_id = value.owner } }
            else
                properties.toValue(value);
        }
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
