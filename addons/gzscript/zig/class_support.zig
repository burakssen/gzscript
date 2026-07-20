const abi = @import("abi.zig");
const codec = @import("codec.zig");
const runtime = @import("runtime.zig");

fn object(value: anytype) runtime.Object {
    return .{ .owner = value.owner };
}

pub fn emitSignal(self: anytype, name: []const u8, arguments: anytype) !void {
    try object(self).emitSignal(name, arguments);
}

pub fn callVoid(self: anytype, method: []const u8, arguments: anytype) !void {
    const encoded = codec.arguments(arguments);
    _ = try object(self).call(method, &encoded);
}

pub fn call(self: anytype, comptime T: type, method: []const u8, arguments: anytype) !T {
    const encoded = codec.arguments(arguments);
    const result = try object(self).call(method, &encoded);
    return codec.fromValue(T, &result);
}
