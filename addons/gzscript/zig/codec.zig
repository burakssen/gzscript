const std = @import("std");
const abi = @import("abi.zig");

fn optionalChild(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => null,
    };
}

pub fn isObjectType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, "owner") and @hasDecl(T, "godot_class"),
        else => false,
    };
}

fn isEnumType(comptime T: type) bool {
    return @typeInfo(T) == .@"enum";
}

fn enumFromInteger(comptime T: type, value: i64) !T {
    const info = @typeInfo(T).@"enum";
    if (!info.is_exhaustive) return @enumFromInt(value);
    inline for (info.fields) |field| {
        if (field.value == value) return @enumFromInt(value);
    }
    return error.InvalidEnumValue;
}

pub fn isVector2Type(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .vector => |info| info.len == 2 and (info.child == f32 or info.child == f64),
        .@"struct" => |info| (info.is_tuple and info.fields.len == 2) or (@hasField(T, "x") and @hasField(T, "y") and info.fields.len == 2),
        else => false,
    };
}

pub inline fn vecX(val: anytype) f32 {
    const T = @TypeOf(val);
    if (@typeInfo(T) == .vector) {
        return @floatCast(val[0]);
    } else if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        return @floatCast(val[0]);
    } else {
        return @floatCast(val.x);
    }
}

pub inline fn vecY(val: anytype) f32 {
    const T = @TypeOf(val);
    if (@typeInfo(T) == .vector) {
        return @floatCast(val[1]);
    } else if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        return @floatCast(val[1]);
    } else {
        return @floatCast(val.y);
    }
}

pub inline fn makeVec2(comptime T: type, x: f32, y: f32) T {
    if (@typeInfo(T) == .vector) {
        return T{ @floatCast(x), @floatCast(y) };
    } else if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        return T{ @floatCast(x), @floatCast(y) };
    } else {
        return T{ .x = @floatCast(x), .y = @floatCast(y) };
    }
}

pub fn valueType(comptime T: type) abi.ValueType {
    if (optionalChild(T)) |Child| {
        if (comptime !isObjectType(Child)) @compileError("only Godot object wrappers may be optional ABI values");
        return .object;
    }
    if (comptime isObjectType(T)) return .object;
    if (comptime isEnumType(T)) return .integer;
    return if (T == bool)
        .boolean
    else if (T == i8 or T == i16 or T == i32 or T == i64 or T == u8 or T == u16 or T == u32)
        .integer
    else if (T == f32 or T == f64)
        .floating
    else if (T == []const u8)
        .string
    else if (comptime isVector2Type(T))
        .vector2
    else
        @compileError("unsupported ABI value type: " ++ @typeName(T));
}

pub fn toValue(value: anytype) abi.Value {
    const T = @TypeOf(value);
    if (optionalChild(T)) |Child| {
        if (comptime !isObjectType(Child)) @compileError("only Godot object wrappers may be optional ABI values");
        return if (value) |payload| toValue(payload) else .{};
    }
    if (comptime isObjectType(T)) return .{ .type = .object, .data = .{ .object_id = value.owner } };
    if (comptime isEnumType(T)) return .{ .type = .integer, .data = .{ .integer = @intFromEnum(value) } };
    return if (T == bool)
        .{ .type = .boolean, .data = .{ .boolean = value } }
    else if (T == i8 or T == i16 or T == i32 or T == i64 or T == u8 or T == u16 or T == u32)
        .{ .type = .integer, .data = .{ .integer = @intCast(value) } }
    else if (T == f32 or T == f64)
        .{ .type = .floating, .data = .{ .floating = @floatCast(value) } }
    else if (T == []const u8)
        .{ .type = .string, .data = .{ .string = .from(value) } }
    else if (comptime isVector2Type(T))
        .{ .type = .vector2, .data = .{ .vector2 = .{ vecX(value), vecY(value) } } }
    else
        @compileError("unsupported ABI value type: " ++ @typeName(T));
}

pub fn fromValue(comptime T: type, value: *const abi.Value) !T {
    if (optionalChild(T)) |Child| {
        if (comptime !isObjectType(Child)) @compileError("only Godot object wrappers may be optional ABI values");
        if (value.type == .nil or (value.type == .object and value.data.object_id == 0)) return null;
        return try fromValue(Child, value);
    }
    if (value.type != valueType(T)) return error.TypeMismatch;
    if (comptime isObjectType(T)) return if (value.data.object_id == 0) error.NullObject else T{ .owner = value.data.object_id };
    if (comptime isEnumType(T)) return enumFromInteger(T, value.data.integer);
    return if (T == bool)
        value.data.boolean
    else if (T == i8 or T == i16 or T == i32 or T == i64 or T == u8 or T == u16 or T == u32)
        std.math.cast(T, value.data.integer) orelse error.IntegerOverflow
    else if (T == f32 or T == f64)
        @floatCast(value.data.floating)
    else if (T == []const u8)
        value.data.string.slice()
    else if (comptime isVector2Type(T))
        makeVec2(T, value.data.vector2[0], value.data.vector2[1])
    else
        unreachable;
}

pub fn arguments(values: anytype) [@typeInfo(@TypeOf(values)).@"struct".fields.len]abi.Value {
    const fields = @typeInfo(@TypeOf(values)).@"struct".fields;
    var result: [fields.len]abi.Value = undefined;
    inline for (fields, 0..) |field, index| result[index] = toValue(@field(values, field.name));
    return result;
}
