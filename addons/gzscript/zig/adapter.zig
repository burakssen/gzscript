const std = @import("std");
const abi = @import("abi.zig");
const codec = @import("codec.zig");
const properties = @import("property.zig");
const runtime = @import("runtime.zig");

fn baseName(comptime T: type) []const u8 {
    if (!@hasDecl(T, "godot_class"))
        @compileError("Zig script Base must declare pub const godot_class");
    return T.godot_class;
}

const CallbackMapping = struct {
    godot_name: []const u8,
    zig_name: []const u8,
    argument_count: u32,
};

const callbacks = [_]CallbackMapping{
    .{ .godot_name = "_ready", .zig_name = "ready", .argument_count = 0 },
    .{ .godot_name = "_enter_tree", .zig_name = "enterTree", .argument_count = 0 },
    .{ .godot_name = "_exit_tree", .zig_name = "exitTree", .argument_count = 0 },
    .{ .godot_name = "_process", .zig_name = "process", .argument_count = 1 },
    .{ .godot_name = "_physics_process", .zig_name = "physicsProcess", .argument_count = 1 },
    .{ .godot_name = "_input", .zig_name = "input", .argument_count = 1 },
    .{ .godot_name = "_unhandled_input", .zig_name = "unhandledInput", .argument_count = 1 },
    .{ .godot_name = "_shortcut_input", .zig_name = "shortcutInput", .argument_count = 1 },
    .{ .godot_name = "_unhandled_key_input", .zig_name = "unhandledKeyInput", .argument_count = 1 },
    .{ .godot_name = "_gui_input", .zig_name = "guiInput", .argument_count = 1 },
    .{ .godot_name = "_draw", .zig_name = "draw", .argument_count = 0 },
};

fn methodCount(comptime T: type) usize {
    var count: usize = 0;
    inline for (callbacks) |cb| {
        if (@hasDecl(T, cb.zig_name)) count += 1;
    }
    return count;
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
    return codec.valueType(T);
}

fn invokeGeneric(instance: anytype, comptime name: []const u8, arguments: ?[*]const abi.Value, comptime argument_count: u32) abi.Status {
    const ScriptType = @TypeOf(instance.*);
    const method_info = @typeInfo(@TypeOf(@field(ScriptType, name)));
    if (method_info != .@"fn") return .method_not_found;
    const params = method_info.@"fn".params;
    if (params.len != argument_count + 1) return .invalid_argument;

    if (comptime argument_count == 0) {
        const result = @call(.auto, @field(ScriptType, name), .{instance});
        if (@typeInfo(@TypeOf(result)) == .error_union) {
            _ = result catch |err| {
                runtime.log.err("gzscript: callback {s}: {s}", .{ name, @errorName(err) });
                return .script_error;
            };
        }
        return .ok;
    } else if (comptime argument_count == 1) {
        const ArgType = params[1].type.?;
        comptime {
            if (std.mem.eql(u8, name, "process") or std.mem.eql(u8, name, "physicsProcess")) {
                if (ArgType != f64 and ArgType != f32) {
                    @compileError("callback " ++ name ++ " expects a float (f64 or f32) argument");
                }
            } else if (std.mem.eql(u8, name, "input") or
                std.mem.eql(u8, name, "unhandledInput") or
                std.mem.eql(u8, name, "shortcutInput") or
                std.mem.eql(u8, name, "unhandledKeyInput") or
                std.mem.eql(u8, name, "guiInput"))
            {
                if (!codec.isObjectType(ArgType)) {
                    @compileError("callback " ++ name ++ " expects a Godot object argument");
                }
            }
        }
        const args = arguments orelse return .invalid_argument;
        const arg = codec.fromValue(ArgType, &args[0]) catch |err| {
            runtime.log.err("gzscript: failed to convert callback argument for {s}: {s}", .{ name, @errorName(err) });
            return .type_mismatch;
        };
        const result = @call(.auto, @field(ScriptType, name), .{ instance, arg });
        if (@typeInfo(@TypeOf(result)) == .error_union) {
            _ = result catch |err| {
                runtime.log.err("gzscript: callback {s}: {s}", .{ name, @errorName(err) });
                return .script_error;
            };
        }
        return .ok;
    } else {
        @compileError("Only callbacks with 0 or 1 arguments are supported currently");
    }
}

pub fn ScriptAdapter(comptime Script: type) type {
    if (!@hasDecl(Script, "Base")) @compileError("Zig script must declare pub const Base");
    if (!@hasField(Script, "base")) @compileError("Zig script must contain a base field");
    if (@FieldType(Script, "base") != Script.Base) @compileError("Zig script base field must have type Script.Base");
    if (!@hasDecl(Script, "init")) @compileError("Zig script must declare pub fn init(ctx: gd.InitContext) !Self");

    const export_count = if (@hasDecl(Script, "exports")) @typeInfo(@TypeOf(Script.exports)).@"struct".fields.len else 0;
    const method_count = methodCount(Script);
    const signal_count = signalCount(Script);
    const signal_argument_count = signalArgumentCount(Script);

    return struct {
        const Box = struct {
            arena: std.heap.ArenaAllocator,
            script: Script,
            owned_strings: [export_count]?[]u8,
        };

        const methods: [method_count]abi.MethodDescriptor = buildMethods();
        const property_descriptors: [export_count]abi.PropertyDescriptor = buildProperties();
        const signal_arguments: [signal_argument_count]abi.SignalArgumentDescriptor = buildSignalArguments();
        const signal_descriptors: [signal_count]abi.SignalDescriptor = buildSignals();

        fn buildMethods() [method_count]abi.MethodDescriptor {
            var result: [method_count]abi.MethodDescriptor = undefined;
            var index: usize = 0;
            inline for (callbacks) |cb| {
                if (@hasDecl(Script, cb.zig_name)) {
                    result[index] = .{ .name = .from(cb.godot_name), .argument_count = cb.argument_count };
                    index += 1;
                }
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
                    .hint = options.hint,
                    .hint_string = .from(options.hint_string),
                    .category = .from(options.category),
                    .class_name = .from(codec.objectClassName(field.type)),
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
            for (&box.owned_strings) |*value| value.* = null;
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
            for (box.owned_strings) |value| {
                if (value) |string| std.heap.page_allocator.free(string);
            }
            box.arena.deinit();
            std.heap.page_allocator.destroy(box);
        }

        fn call(pointer: ?*anyopaque, method: abi.StringView, arguments: ?[*]const abi.Value, argument_count: u32, result: *abi.Value) callconv(.c) abi.Status {
            _ = result;
            const raw = pointer orelse return .invalid_argument;
            const box: *Box = @ptrCast(@alignCast(raw));
            const name = method.slice();
            inline for (callbacks) |cb| {
                if (std.mem.eql(u8, name, cb.godot_name)) {
                    if (!@hasDecl(Script, cb.zig_name) or argument_count != cb.argument_count) return .method_not_found;
                    return invokeGeneric(&box.script, cb.zig_name, arguments, cb.argument_count);
                }
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
                    @field(box.script, field.name) = if (FieldType == []const u8) replace: {
                        const replacement = std.heap.page_allocator.dupe(u8, converted) catch return .out_of_memory;
                        if (box.owned_strings[index]) |previous| std.heap.page_allocator.free(previous);
                        box.owned_strings[index] = replacement;
                        break :replace replacement;
                    } else converted;
                    return .ok;
                }
            }
            return .property_not_found;
        }

        fn notification(pointer: ?*anyopaque, what: i32, reversed: bool) callconv(.c) void {
            _ = reversed;
            const raw = pointer orelse return;
            const box: *Box = @ptrCast(@alignCast(raw));
            // a compile-time declaration check avoids notification metadata.
            if (@hasDecl(Script, "notification")) {
                const result = box.script.notification(what);
                if (@typeInfo(@TypeOf(result)) == .error_union) {
                    _ = result catch |err| {
                        runtime.log.err("gzscript: error in notification callback: {s}", .{@errorName(err)});
                    };
                }
            }
        }

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
