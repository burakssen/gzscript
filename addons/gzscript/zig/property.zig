const abi = @import("abi.zig");
const codec = @import("codec.zig");

pub const Range = struct {
    min: f64,
    max: f64,
    step: f64 = 0.01,
};

pub const Property = struct {
    category: []const u8 = "",
    range: ?Range = null,
    hint: abi.PropertyHint = .none,
    hint_string: []const u8 = "",
};

pub fn property(comptime options: anytype) Property {
    var result = Property{};
    if (@hasField(@TypeOf(options), "category")) result.category = options.category;
    if (@hasField(@TypeOf(options), "hint")) result.hint = options.hint;
    if (@hasField(@TypeOf(options), "hint_string")) result.hint_string = options.hint_string;
    if (@hasField(@TypeOf(options), "range")) {
        result.range = .{
            .min = options.range.min,
            .max = options.range.max,
            .step = if (@hasField(@TypeOf(options.range), "step")) options.range.step else 0.01,
        };
        result.hint = .range;
    }
    return result;
}

pub fn valueType(comptime T: type) abi.ValueType {
    return codec.valueType(T);
}

pub fn toValue(value: anytype) abi.Value {
    return codec.toValue(value);
}

pub fn fromValue(comptime T: type, value: *const abi.Value) ?T {
    return codec.fromValue(T, value) catch null;
}
