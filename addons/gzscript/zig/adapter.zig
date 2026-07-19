const std = @import("std");
const abi = @import("abi.zig");
const properties = @import("property.zig");
const runtime = @import("runtime.zig");

fn baseName(comptime T: type) []const u8 {
    if (!@hasDecl(T, "godot_class"))
        @compileError("Zig script Base must declare pub const godot_class");
    return T.godot_class;
}

fn methodCount(comptime T: type) usize {
    return @as(usize, @intFromBool(@hasDecl(T, "_ready"))) +
        @as(usize, @intFromBool(@hasDecl(T, "_process"))) +
        @as(usize, @intFromBool(@hasDecl(T, "_physics_process")));
}

fn signalCount(comptime T: type) usize {
    return if (@hasDecl(T, "signals")) @typeInfo(@TypeOf(T.signals)).@"struct".fields.len else 0;
}

fn signalArgumentCount(comptime T: type) usize {
    if (!@hasDecl(T, "signals")) return 0;
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(T.signals)).@"struct".fields) |field| {
        const declaration = @field(T.signals, field.name);
        if (!@hasDecl(@TypeOf(declaration), "arguments"))
            @compileError("invalid signal declaration: " ++ field.name);
        count += @typeInfo(@TypeOf(@TypeOf(declaration).arguments)).@"struct".fields.len;
    }
    return count;
}

fn signalValueType(comptime T: type) abi.ValueType {
    return if (@typeInfo(T) == .@"struct" and @hasField(T, "owner"))
        .object
    else
        properties.valueType(T);
}

fn invoke0(instance: anytype, comptime name: []const u8) abi.Status {
    const result = @call(.auto, @field(@TypeOf(instance.*), name), .{instance});
    if (@typeInfo(@TypeOf(result)) == .error_union) {
        _ = result catch return .script_error;
    }
    return .ok;
}

fn invokeDelta(instance: anytype, comptime name: []const u8, delta: f64) abi.Status {
    const result = @call(.auto, @field(@TypeOf(instance.*), name), .{ instance, delta });
    if (@typeInfo(@TypeOf(result)) == .error_union) {
        _ = result catch return .script_error;
    }
    return .ok;
}

pub fn ScriptAdapter(comptime Script: type) type {
    if (!@hasDecl(Script, "Base")) @compileError("Zig script must declare pub const Base");
    if (!@hasField(Script, "base")) @compileError("Zig script must contain a base field");
    if (!@hasDecl(Script, "init")) @compileError("Zig script must declare pub fn init(ctx: gd.InitContext) !Self");

    const export_count = if (@hasDecl(Script, "exports")) @typeInfo(@TypeOf(Script.exports)).@"struct".fields.len else 0;
    const method_count = methodCount(Script);
    const signal_count = signalCount(Script);
    const signal_argument_count = signalArgumentCount(Script);

    return struct {
        const Box = struct {
            arena: std.heap.ArenaAllocator,
            script: Script,
        };

        const methods: [method_count]abi.MethodDescriptor = buildMethods();
        const property_descriptors: [export_count]abi.PropertyDescriptor = buildProperties();
        const signal_arguments: [signal_argument_count]abi.SignalArgumentDescriptor = buildSignalArguments();
        const signal_descriptors: [signal_count]abi.SignalDescriptor = buildSignals();

        fn buildMethods() [method_count]abi.MethodDescriptor {
            var result: [method_count]abi.MethodDescriptor = undefined;
            var index: usize = 0;
            if (@hasDecl(Script, "_ready")) {
                result[index] = .{ .name = .from("_ready"), .argument_count = 0 };
                index += 1;
            }
            if (@hasDecl(Script, "_process")) {
                result[index] = .{ .name = .from("_process"), .argument_count = 1 };
                index += 1;
            }
            if (@hasDecl(Script, "_physics_process")) {
                result[index] = .{ .name = .from("_physics_process"), .argument_count = 1 };
            }
            return result;
        }

        fn buildProperties() [export_count]abi.PropertyDescriptor {
            var result: [export_count]abi.PropertyDescriptor = undefined;
            if (!@hasDecl(Script, "exports")) return result;
            const export_fields = @typeInfo(@TypeOf(Script.exports)).@"struct".fields;
            const script_fields = @typeInfo(Script).@"struct".fields;
            inline for (export_fields, 0..) |export_field, index| {
                if (!@hasField(Script, export_field.name)) @compileError("export does not match a script field: " ++ export_field.name);
                const field = comptime find: {
                    for (script_fields) |candidate| if (std.mem.eql(u8, candidate.name, export_field.name)) break :find candidate;
                    unreachable;
                };
                const default_ptr = field.default_value_ptr orelse @compileError("exported fields require a default value: " ++ field.name);
                const default_value = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                const options: properties.Property = @field(Script.exports, export_field.name);
                result[index] = .{
                    .name = .from(export_field.name),
                    .type = properties.valueType(field.type),
                    .hint = if (options.range != null) .range else .none,
                    .category = .from(options.category),
                    .range_min = if (options.range) |range| range.min else 0,
                    .range_max = if (options.range) |range| range.max else 0,
                    .range_step = if (options.range) |range| range.step else 0,
                    .default_value = properties.toValue(default_value),
                };
            }
            return result;
        }

        fn buildSignalArguments() [signal_argument_count]abi.SignalArgumentDescriptor {
            var result: [signal_argument_count]abi.SignalArgumentDescriptor = undefined;
            var index: usize = 0;
            if (!@hasDecl(Script, "signals")) return result;
            inline for (@typeInfo(@TypeOf(Script.signals)).@"struct".fields) |signal_field| {
                const declaration = @field(Script.signals, signal_field.name);
                inline for (@typeInfo(@TypeOf(@TypeOf(declaration).arguments)).@"struct".fields) |argument_field| {
                    result[index] = .{
                        .name = .from(argument_field.name),
                        .type = signalValueType(@field(@TypeOf(declaration).arguments, argument_field.name)),
                    };
                    index += 1;
                }
            }
            return result;
        }

        fn buildSignals() [signal_count]abi.SignalDescriptor {
            var result: [signal_count]abi.SignalDescriptor = undefined;
            var argument_index: usize = 0;
            if (!@hasDecl(Script, "signals")) return result;
            inline for (@typeInfo(@TypeOf(Script.signals)).@"struct".fields, 0..) |signal_field, signal_index| {
                const declaration = @field(Script.signals, signal_field.name);
                const argument_count = @typeInfo(@TypeOf(@TypeOf(declaration).arguments)).@"struct".fields.len;
                result[signal_index] = .{
                    .name = .from(signal_field.name),
                    .arguments = if (argument_count == 0) null else signal_arguments[argument_index..].ptr,
                    .argument_count = argument_count,
                };
                argument_index += argument_count;
            }
            return result;
        }

        fn create(owner: u64, output: *?*anyopaque) callconv(.c) abi.Status {
            const box = std.heap.page_allocator.create(Box) catch return .out_of_memory;
            box.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            box.script = Script.init(.{ .owner = owner, .allocator = box.arena.allocator() }) catch {
                box.arena.deinit();
                std.heap.page_allocator.destroy(box);
                return .script_error;
            };
            output.* = box;
            return .ok;
        }

        fn destroy(pointer: ?*anyopaque) callconv(.c) void {
            const raw = pointer orelse return;
            const box: *Box = @ptrCast(@alignCast(raw));
            if (@hasDecl(Script, "deinit")) box.script.deinit();
            box.arena.deinit();
            std.heap.page_allocator.destroy(box);
        }

        fn call(pointer: ?*anyopaque, method: abi.StringView, arguments: ?[*]const abi.Value, argument_count: u32, result: *abi.Value) callconv(.c) abi.Status {
            _ = result;
            const raw = pointer orelse return .invalid_argument;
            const box: *Box = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, method.slice(), "_ready")) {
                if (!@hasDecl(Script, "_ready") or argument_count != 0) return .method_not_found;
                return invoke0(&box.script, "_ready");
            }
            if (std.mem.eql(u8, method.slice(), "_process")) {
                if (!@hasDecl(Script, "_process") or argument_count != 1) return .method_not_found;
                const args = arguments orelse return .invalid_argument;
                if (args[0].type != .floating) return .type_mismatch;
                return invokeDelta(&box.script, "_process", args[0].data.floating);
            }
            if (std.mem.eql(u8, method.slice(), "_physics_process")) {
                if (!@hasDecl(Script, "_physics_process") or argument_count != 1) return .method_not_found;
                const args = arguments orelse return .invalid_argument;
                if (args[0].type != .floating) return .type_mismatch;
                return invokeDelta(&box.script, "_physics_process", args[0].data.floating);
            }
            return .method_not_found;
        }

        fn getProperty(pointer: ?*anyopaque, property_index: u32, result: *abi.Value) callconv(.c) abi.Status {
            const raw = pointer orelse return .invalid_argument;
            const box: *Box = @ptrCast(@alignCast(raw));
            if (!@hasDecl(Script, "exports")) return .property_not_found;
            inline for (@typeInfo(@TypeOf(Script.exports)).@"struct".fields, 0..) |field, index| {
                if (property_index == index) {
                    result.* = properties.toValue(@field(box.script, field.name));
                    return .ok;
                }
            }
            return .property_not_found;
        }

        fn setProperty(pointer: ?*anyopaque, property_index: u32, value: *const abi.Value) callconv(.c) abi.Status {
            const raw = pointer orelse return .invalid_argument;
            const box: *Box = @ptrCast(@alignCast(raw));
            if (!@hasDecl(Script, "exports")) return .property_not_found;
            inline for (@typeInfo(@TypeOf(Script.exports)).@"struct".fields, 0..) |field, index| {
                if (property_index == index) {
                    const FieldType = @TypeOf(@field(box.script, field.name));
                    const converted = properties.fromValue(FieldType, value) orelse return .type_mismatch;
                    @field(box.script, field.name) = if (FieldType == []const u8)
                        box.arena.allocator().dupe(u8, converted) catch return .out_of_memory
                    else
                        converted;
                    return .ok;
                }
            }
            return .property_not_found;
        }

        fn notification(_: ?*anyopaque, _: i32, _: bool) callconv(.c) void {}

        pub const descriptor = abi.ScriptDescriptor{
            .abi_version = abi.abi_version,
            .struct_size = @sizeOf(abi.ScriptDescriptor),
            .base_class = .from(baseName(Script.Base)),
            .methods = if (method_count == 0) null else &methods,
            .method_count = method_count,
            .properties = if (export_count == 0) null else &property_descriptors,
            .property_count = export_count,
            .signals = if (signal_count == 0) null else &signal_descriptors,
            .signal_count = signal_count,
            .create_instance = create,
            .destroy_instance = destroy,
            .call_method = call,
            .get_property = getProperty,
            .set_property = setProperty,
            .notification = notification,
        };
    };
}
