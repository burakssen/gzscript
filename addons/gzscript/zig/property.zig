const std = @import("std");
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

pub const Field = struct {
    name: []const u8,
    property: Property,
};

pub const Marker = struct {
    name: []const u8,
    prefix: []const u8 = "",
};

pub const ExportEntry = union(enum) {
    field: Field,
    category: Marker,
    group: Marker,
    subgroup: Marker,
};

pub fn property(comptime options: anytype) Property {
    inline for (@typeInfo(@TypeOf(options)).@"struct".fields) |field_info| {
        if (!std.mem.eql(u8, field_info.name, "category") and
            !std.mem.eql(u8, field_info.name, "range") and
            !std.mem.eql(u8, field_info.name, "hint") and
            !std.mem.eql(u8, field_info.name, "hint_string"))
            @compileError("unknown property option: " ++ field_info.name);
    }
    var result = Property{};
    if (@hasField(@TypeOf(options), "category")) result.category = options.category;
    if (@hasField(@TypeOf(options), "hint")) result.hint = options.hint;
    if (@hasField(@TypeOf(options), "hint_string")) result.hint_string = options.hint_string;
    if (@hasField(@TypeOf(options), "range")) {
        if (options.range.min > options.range.max)
            @compileError("property range minimum must not exceed maximum");
        const step = if (@hasField(@TypeOf(options.range), "step")) options.range.step else 0.01;
        if (step <= 0) @compileError("property range step must be positive");
        if (result.hint != .none and result.hint != .range)
            @compileError("property range conflicts with explicit hint");
        result.range = .{
            .min = options.range.min,
            .max = options.range.max,
            .step = step,
        };
        result.hint = .range;
    }
    return result;
}

pub fn exports(comptime entries: anytype) @TypeOf(entries) {
    if (!@typeInfo(@TypeOf(entries)).@"struct".is_tuple)
        @compileError("gd.exports expects an ordered tuple");
    return entries;
}

pub fn field(comptime name: []const u8, comptime definition: Property) ExportEntry {
    return .{ .field = .{ .name = name, .property = definition } };
}

pub fn category(comptime name: []const u8) ExportEntry {
    if (name.len == 0) @compileError("category name cannot be empty");
    return .{ .category = .{ .name = name } };
}

pub fn group(comptime name: []const u8, comptime prefix: []const u8) ExportEntry {
    if (name.len == 0) @compileError("use gd.endGroup() to end a group");
    return .{ .group = .{ .name = name, .prefix = prefix } };
}

pub fn subgroup(comptime name: []const u8, comptime prefix: []const u8) ExportEntry {
    if (name.len == 0) @compileError("subgroup name cannot be empty");
    return .{ .subgroup = .{ .name = name, .prefix = prefix } };
}

pub fn endGroup() ExportEntry {
    return .{ .group = .{ .name = "" } };
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
