const abi = @import("abi.zig");
const codec = @import("codec.zig");
const runtime = @import("runtime.zig");

fn object(val: anytype) runtime.Object {
    return .{ .owner = val.owner };
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

inline fn preparePtrcallArgs(arguments: anytype, arg_ptrs: anytype, engine_vecs: anytype, engine_vec3s: anytype) void {
    const fields = @typeInfo(@TypeOf(arguments)).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const val = @field(arguments, field.name);
        if (comptime codec.isVector2Type(@TypeOf(val))) {
            engine_vecs[i] = .{ codec.vecX(val), codec.vecY(val) };
            arg_ptrs[i] = @ptrCast(&engine_vecs[i]);
        } else if (comptime codec.isVector3Type(@TypeOf(val))) {
            engine_vec3s[i] = .{ codec.vec3X(val), codec.vec3Y(val), codec.vec3Z(val) };
            arg_ptrs[i] = @ptrCast(&engine_vec3s[i]);
        } else {
            // Color, Transform2D/3D, and Rect2 already have matching memory layouts,
            // so we pass their pointer directly without conversion.
            arg_ptrs[i] = @ptrCast(&@field(arguments, field.name));
        }
    }
}

pub fn ptrcallVoid(self: anytype, mb: abi.MethodBind, arguments: anytype) !void {
    const fields = @typeInfo(@TypeOf(arguments)).@"struct".fields;
    var arg_ptrs: [fields.len]?*const anyopaque = undefined;
    var engine_vecs: [fields.len]abi.Vector(2, f32) = undefined;
    var engine_vec3s: [fields.len]abi.Vector(3, f32) = undefined;
    preparePtrcallArgs(arguments, &arg_ptrs, &engine_vecs, &engine_vec3s);
    try runtime.ptrcall(mb, self.owner, if (fields.len == 0) null else &arg_ptrs, null);
}

fn MethodCache(comptime class_name: []const u8, comptime method_name: []const u8, comptime hash: i64) type {
    return struct {
        var value: abi.MethodBind = null;
        const class = class_name;
        const method = method_name;
        const method_hash = hash;

        fn get() !abi.MethodBind {
            if (value == null) value = runtime.getMethodBind(class, method, method_hash);
            return value orelse error.MethodBindNotFound;
        }
    };
}

pub fn ptrcallMethodVoid(
    self: anytype,
    comptime class_name: []const u8,
    comptime method_name: []const u8,
    comptime hash: i64,
    arguments: anytype,
) !void {
    return ptrcallVoid(self, try MethodCache(class_name, method_name, hash).get(), arguments);
}

pub fn ptrcallMethod(
    self: anytype,
    comptime T: type,
    comptime class_name: []const u8,
    comptime method_name: []const u8,
    comptime hash: i64,
    arguments: anytype,
) !T {
    return ptrcall(self, T, try MethodCache(class_name, method_name, hash).get(), arguments);
}

pub fn ptrcall(self: anytype, comptime T: type, mb: abi.MethodBind, arguments: anytype) !T {
    const fields = @typeInfo(@TypeOf(arguments)).@"struct".fields;
    var arg_ptrs: [fields.len]?*const anyopaque = undefined;
    var engine_vecs: [fields.len]abi.Vector(2, f32) = undefined;
    var engine_vec3s: [fields.len]abi.Vector(3, f32) = undefined;
    preparePtrcallArgs(arguments, &arg_ptrs, &engine_vecs, &engine_vec3s);

    if (comptime codec.isVector2Type(T)) {
        var raw_res: abi.Vector(2, f32) = undefined;
        try runtime.ptrcall(mb, self.owner, if (fields.len == 0) null else &arg_ptrs, @ptrCast(&raw_res));
        return codec.makeVec2(T, raw_res[0], raw_res[1]);
    } else if (comptime codec.isVector3Type(T)) {
        var raw_res: abi.Vector(3, f32) = undefined;
        try runtime.ptrcall(mb, self.owner, if (fields.len == 0) null else &arg_ptrs, @ptrCast(&raw_res));
        return codec.makeVec3(T, raw_res[0], raw_res[1], raw_res[2]);
    } else {
        var result: T = undefined;
        try runtime.ptrcall(mb, self.owner, if (fields.len == 0) null else &arg_ptrs, @ptrCast(&result));
        return result;
    }
}
