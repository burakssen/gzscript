const abi = @import("abi.zig");

pub const Range = struct {
    min: f64,
    max: f64,
    step: f64 = 0.01,
};

pub const Property = struct {
    category: []const u8 = "",
    range: ?Range = null,
};

pub fn property(comptime options: anytype) Property {
    var result = Property{};
    if (@hasField(@TypeOf(options), "category")) result.category = options.category;
    if (@hasField(@TypeOf(options), "range")) {
        result.range = .{
            .min = options.range.min,
            .max = options.range.max,
            .step = if (@hasField(@TypeOf(options.range), "step")) options.range.step else 0.01,
        };
    }
    return result;
}

pub fn valueType(comptime T: type) abi.ValueType {
    return if (T == bool)
        .boolean
    else if (T == i8 or T == i16 or T == i32 or T == i64 or T == u8 or T == u16 or T == u32)
        .integer
    else if (T == f32 or T == f64)
        .floating
    else if (T == []const u8)
        .string
    else if (T == abi.Vector2)
        .vector2
    else
        @compileError("unsupported exported property type: " ++ @typeName(T));
}

pub fn toValue(value: anytype) abi.Value {
    const T = @TypeOf(value);
    return if (T == bool)
        .{ .type = .boolean, .data = .{ .boolean = value } }
    else if (T == i8 or T == i16 or T == i32 or T == i64 or T == u8 or T == u16 or T == u32)
        .{ .type = .integer, .data = .{ .integer = @intCast(value) } }
    else if (T == f32 or T == f64)
        .{ .type = .floating, .data = .{ .floating = @floatCast(value) } }
    else if (T == []const u8)
        .{ .type = .string, .data = .{ .string = .from(value) } }
    else if (T == abi.Vector2)
        .{ .type = .vector2, .data = .{ .vector2 = value } }
    else
        @compileError("unsupported value type: " ++ @typeName(T));
}

pub fn fromValue(comptime T: type, value: *const abi.Value) ?T {
    if (value.type != valueType(T)) return null;
    return if (T == bool)
        value.data.boolean
    else if (T == i8 or T == i16 or T == i32 or T == i64 or T == u8 or T == u16 or T == u32)
        @intCast(value.data.integer)
    else if (T == f32 or T == f64)
        @floatCast(value.data.floating)
    else if (T == []const u8)
        value.data.string.slice()
    else if (T == abi.Vector2)
        value.data.vector2
    else
        unreachable;
}
