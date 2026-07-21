const std = @import("std");

pub const Header = struct {
    version_major: i64,
    version_minor: i64,
    version_patch: i64,
    version_status: []const u8,
    precision: []const u8,
};

pub const EnumValue = struct {
    name: []const u8,
    value: i64,
};

pub const ApiEnum = struct {
    name: []const u8,
    is_bitfield: bool = false,
    values: []const EnumValue = &.{},
};

pub const TypeRef = struct {
    name: []const u8,
    meta: ?[]const u8,
};

pub const Argument = struct {
    name: []const u8,
    type: []const u8,
    meta: ?[]const u8 = null,

    pub fn typeRef(self: *const Argument) TypeRef {
        return .{ .name = self.type, .meta = self.meta };
    }
};

pub const ReturnValue = struct {
    type: []const u8,
    meta: ?[]const u8 = null,

    pub fn typeRef(self: *const ReturnValue) TypeRef {
        return .{ .name = self.type, .meta = self.meta };
    }
};

pub const Method = struct {
    name: []const u8,
    return_value: ?ReturnValue = null,
    arguments: []const Argument = &.{},
    is_vararg: bool = false,
    is_static: bool = false,
    is_virtual: bool = false,
    hash: i64 = 0,
};

pub const Class = struct {
    name: []const u8,
    inherits: ?[]const u8 = null,
    methods: []const Method = &.{},
    enums: []const ApiEnum = &.{},

    pub fn method(self: *const Class, name: []const u8) ?*const Method {
        for (self.methods) |*candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }

    pub fn apiEnum(self: *const Class, name: []const u8) ?*const ApiEnum {
        for (self.enums) |*candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }
};

pub const ExtensionApi = struct {
    header: Header,
    global_enums: []const ApiEnum = &.{},
    classes: []const Class = &.{},
    classes_by_name: std.StringHashMapUnmanaged(*const Class) = .empty,

    pub fn buildIndex(self: *ExtensionApi, allocator: std.mem.Allocator) !void {
        for (self.classes) |*class_entry| {
            try self.classes_by_name.put(allocator, class_entry.name, class_entry);
        }
    }

    pub fn class(self: *const ExtensionApi, name: []const u8) ?*const Class {
        return self.classes_by_name.get(name);
    }

    pub fn globalEnum(self: *const ExtensionApi, name: []const u8) ?*const ApiEnum {
        for (self.global_enums) |*candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }

    pub fn inheritanceChain(self: *const ExtensionApi, allocator: std.mem.Allocator, class_name: []const u8) !std.ArrayList(*const Class) {
        var result: std.ArrayList(*const Class) = .empty;
        var visited = std.StringHashMap(void).init(allocator);
        var current: ?[]const u8 = class_name;
        while (current) |name| {
            if (visited.contains(name)) return error.InheritanceCycle;
            try visited.put(name, {});
            const class_entry = self.class(name) orelse return error.InheritedClassNotFound;
            try result.append(allocator, class_entry);
            current = class_entry.inherits;
        }
        std.mem.reverse(*const Class, result.items);
        return result;
    }

    pub fn findDeclaringClass(self: *const ExtensionApi, allocator: std.mem.Allocator, method: *const Method, class_name: []const u8) ![]const u8 {
        var chain = try self.inheritanceChain(allocator, class_name);
        defer chain.deinit(allocator);
        var index = chain.items.len;
        while (index > 0) {
            index -= 1;
            const class_entry = chain.items[index];
            if (class_entry.method(method.name) != null) return class_entry.name;
        }
        return class_name;
    }
};

const Document = struct {
    header: Header,
    global_enums: []const ApiEnum = &.{},
    classes: []const Class = &.{},
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ExtensionApi {
    const document = try std.json.parseFromSliceLeaky(Document, allocator, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{
        .header = document.header,
        .global_enums = document.global_enums,
        .classes = document.classes,
    };
}
