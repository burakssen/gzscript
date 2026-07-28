const std = @import("std");
const gd = @import("godot");

const TestObject = extern struct {
    owner: u64,

    pub const godot_class = "TestObject";
};

const OwnerOnly = extern struct {
    owner: u64,
};

fn discardLog(_: gd.abi.StringView) callconv(.c) void {}

var captured_error: [256]u8 = undefined;
var captured_error_len: usize = 0;

fn captureError(message: gd.abi.StringView) callconv(.c) void {
    captured_error_len = @min(message.len, captured_error.len);
    @memcpy(captured_error[0..captured_error_len], message.slice()[0..captured_error_len]);
}

fn missingMethodCall(_: u64, _: gd.abi.StringView, _: ?[*]const gd.abi.Value, _: u32, _: *gd.abi.Value) callconv(.c) gd.abi.Status {
    return .method_not_found;
}

fn discardSignal(_: u64, _: gd.abi.StringView, _: ?[*]const gd.abi.Value, _: u32) callconv(.c) gd.abi.Status {
    return .ok;
}

fn zeroTicks() callconv(.c) u64 {
    return 0;
}

const TestScript = struct {
    pub const Base = gd.Node2D;
    const Self = @This();

    base: Base,
    internal: f64 = 0,
    amplitude: f64 = 10,

    pub const exports = .{
        .amplitude = gd.property(.{ .category = "Movement", .range = .{ .min = 0, .max = 100, .step = 0.1 } }),
    };

    pub const signals = .{
        .started = gd.signal(.{}),
        .position_changed = gd.signal(.{ .position = gd.Vector(2, f64) }),
    };

    pub fn init(ctx: gd.InitContext) !Self {
        return .{ .base = .{ .owner = ctx.owner } };
    }

    pub fn ready(self: *Self) !void {
        self.internal = 1.0;
    }

    pub fn process(self: *Self, delta: f64) !void {
        self.internal = delta;
    }

    pub fn input(self: *Self, event: gd.InputEvent) !void {
        self.internal = @floatFromInt(event.owner);
    }
};

const ErrorScript = struct {
    pub const Base = gd.Node;
    const Self = @This();

    base: Base,

    pub fn init(ctx: gd.InitContext) !Self {
        return .{ .base = .{ .owner = ctx.owner } };
    }

    pub fn ready(_: *Self) !void {
        return error.ReadyFailed;
    }
};

const GroupedExportsScript = struct {
    pub const Base = gd.Node;

    base: Base,
    osc_amplitude: f64 = 10,
    osc_speed: f64 = 1,
    debug_text: []const u8 = "",

    pub const exports = gd.exports(.{
        gd.category("Movement"),
        gd.group("Oscillation", "osc_"),
        gd.field("osc_amplitude", gd.property(.{})),
        gd.subgroup("Timing", "osc_"),
        gd.field("osc_speed", gd.property(.{})),
        gd.endGroup(),
        gd.field("debug_text", gd.property(.{ .hint = .multiline_text })),
    });

    pub fn init(ctx: gd.InitContext) !@This() {
        return .{ .base = .{ .owner = ctx.owner } };
    }
};

test "adapter logs callback error names" {
    captured_error_len = 0;
    var api = gd.abi.EngineApi{
        .abi_version = gd.abi.abi_version,
        .struct_size = @sizeOf(gd.abi.EngineApi),
        .log_info = discardLog,
        .log_error = captureError,
        .object_call = missingMethodCall,
        .object_emit_signal = discardSignal,
        .get_method_bind = undefined,
        .object_ptrcall = undefined,
        .get_ticks_usec = zeroTicks,
    };
    var descriptor: *const gd.abi.ScriptDescriptor = undefined;
    try std.testing.expectEqual(gd.abi.Status.ok, gd.initialize(&api, &descriptor, &gd.ScriptAdapter(ErrorScript).descriptor));
    var instance: ?*anyopaque = null;
    try std.testing.expectEqual(gd.abi.Status.ok, descriptor.create_instance(1, &instance));
    defer descriptor.destroy_instance(instance);
    var result = gd.abi.Value{};
    try std.testing.expectEqual(gd.abi.Status.script_error, descriptor.call_method(instance, .from("_ready"), null, 0, &result));
    try std.testing.expect(std.mem.indexOf(u8, captured_error[0..captured_error_len], "ready: ReadyFailed") != null);
}

test "adapter dispatches callbacks: ready, process, input" {
    var api = gd.abi.EngineApi{
        .abi_version = gd.abi.abi_version,
        .struct_size = @sizeOf(gd.abi.EngineApi),
        .log_info = discardLog,
        .log_error = discardLog,
        .object_call = missingMethodCall,
        .object_emit_signal = discardSignal,
        .get_method_bind = undefined,
        .object_ptrcall = undefined,
        .get_ticks_usec = zeroTicks,
    };

    var descriptor: *const gd.abi.ScriptDescriptor = undefined;
    try std.testing.expectEqual(
        gd.abi.Status.ok,
        gd.initialize(&api, &descriptor, &gd.ScriptAdapter(TestScript).descriptor),
    );

    var instance_ptr: ?*anyopaque = null;
    try std.testing.expectEqual(gd.abi.Status.ok, descriptor.create_instance(42, &instance_ptr));
    defer descriptor.destroy_instance(instance_ptr);

    // Call ready
    var result_val = gd.abi.Value{};
    try std.testing.expectEqual(
        gd.abi.Status.ok,
        descriptor.call_method(instance_ptr, gd.abi.StringView.from("_ready"), null, 0, &result_val),
    );

    // Call process
    var process_args = [_]gd.abi.Value{
        .{ .type = .floating, .data = .{ .floating = 3.14 } },
    };
    try std.testing.expectEqual(
        gd.abi.Status.ok,
        descriptor.call_method(instance_ptr, gd.abi.StringView.from("_process"), &process_args, 1, &result_val),
    );

    // Call input with an object (e.g. InputEvent)
    var input_args = [_]gd.abi.Value{
        .{ .type = .object, .data = .{ .object_id = 999 } },
    };
    try std.testing.expectEqual(
        gd.abi.Status.ok,
        descriptor.call_method(instance_ptr, gd.abi.StringView.from("_input"), &input_args, 1, &result_val),
    );

    // Call with invalid arg type
    var bad_args = [_]gd.abi.Value{
        .{ .type = .integer, .data = .{ .integer = 42 } },
    };
    try std.testing.expectEqual(
        gd.abi.Status.type_mismatch,
        descriptor.call_method(instance_ptr, gd.abi.StringView.from("_input"), &bad_args, 1, &result_val),
    );
}

test "adapter reflects explicit exports only" {
    const descriptor = gd.ScriptAdapter(TestScript).descriptor;
    try std.testing.expectEqual(@as(u32, 1), descriptor.property_count);
    try std.testing.expectEqualStrings("amplitude", descriptor.properties.?[0].name.slice());
    try std.testing.expectEqual(@as(u32, 2), descriptor.inspector_entry_count);
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.category, descriptor.inspector_entries.?[0].kind);
    try std.testing.expectEqualStrings("Movement", descriptor.inspector_entries.?[0].name.slice());
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.property, descriptor.inspector_entries.?[1].kind);
    try std.testing.expectEqual(@as(f64, 10), descriptor.properties.?[0].default_value.data.floating);
    try std.testing.expectEqualStrings("Node2D", descriptor.base_class.slice());
}

test "adapter emits ordered inspector metadata without changing property indexes" {
    const descriptor = gd.ScriptAdapter(GroupedExportsScript).descriptor;
    try std.testing.expectEqual(@as(u32, 3), descriptor.property_count);
    try std.testing.expectEqualStrings("osc_amplitude", descriptor.properties.?[0].name.slice());
    try std.testing.expectEqualStrings("osc_speed", descriptor.properties.?[1].name.slice());
    try std.testing.expectEqualStrings("debug_text", descriptor.properties.?[2].name.slice());

    try std.testing.expectEqual(@as(u32, 7), descriptor.inspector_entry_count);
    const entries = descriptor.inspector_entries.?;
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.category, entries[0].kind);
    try std.testing.expectEqualStrings("Movement", entries[0].name.slice());
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.group, entries[1].kind);
    try std.testing.expectEqualStrings("Oscillation", entries[1].name.slice());
    try std.testing.expectEqualStrings("osc_", entries[1].prefix.slice());
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.property, entries[2].kind);
    try std.testing.expectEqual(@as(u32, 0), entries[2].property_index);
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.subgroup, entries[3].kind);
    try std.testing.expectEqualStrings("Timing", entries[3].name.slice());
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.property, entries[4].kind);
    try std.testing.expectEqual(@as(u32, 1), entries[4].property_index);
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.group, entries[5].kind);
    try std.testing.expectEqualStrings("", entries[5].name.slice());
    try std.testing.expectEqual(gd.abi.InspectorEntryKind.property, entries[6].kind);
    try std.testing.expectEqual(@as(u32, 2), entries[6].property_index);
}

test "adapter reflects exported object classes" {
    const Script = struct {
        pub const Base = gd.Node;
        base: Base,
        texture: ?gd.Texture2D = null,
        pub const exports = .{ .texture = gd.property(.{}) };
        pub fn init(ctx: gd.InitContext) !@This() {
            return .{ .base = .{ .owner = ctx.owner } };
        }
    };
    const descriptor = gd.ScriptAdapter(Script).descriptor;
    try std.testing.expectEqualStrings("Texture2D", descriptor.properties.?[0].class_name.slice());
}

test "adapter reflects signal declarations" {
    const descriptor = gd.ScriptAdapter(TestScript).descriptor;
    try std.testing.expectEqual(@as(u32, 2), descriptor.signal_count);
    try std.testing.expectEqualStrings("started", descriptor.signals.?[0].name.slice());
    try std.testing.expectEqual(@as(u32, 0), descriptor.signals.?[0].argument_count);
    try std.testing.expectEqualStrings("position_changed", descriptor.signals.?[1].name.slice());
    try std.testing.expectEqual(@as(u32, 1), descriptor.signals.?[1].argument_count);
    try std.testing.expectEqualStrings("position", descriptor.signals.?[1].arguments.?[0].name.slice());
    try std.testing.expectEqual(gd.abi.ValueType.vector2, descriptor.signals.?[1].arguments.?[0].type);
}

test "2D wrappers expose typed position methods" {
    try std.testing.expect(@hasDecl(gd.Node2D, "setPosition"));
    try std.testing.expect(@hasDecl(gd.Node2D, "getPosition"));
    try std.testing.expect(@hasDecl(gd.Sprite2D, "setPosition"));
    try std.testing.expect(@hasDecl(gd.Sprite2D, "getPosition"));
}

test "ABI v5 layouts remain stable" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(gd.abi.ValueType.nil));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(gd.abi.ValueType.boolean));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(gd.abi.ValueType.integer));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(gd.abi.ValueType.floating));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(gd.abi.ValueType.string));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(gd.abi.ValueType.vector2));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(gd.abi.ValueType.object));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(gd.abi.ValueType.vector3));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(gd.abi.ValueType.color));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(gd.abi.ValueType.transform2d));
    try std.testing.expectEqual(@as(u32, 10), @intFromEnum(gd.abi.ValueType.transform3d));
    try std.testing.expectEqual(@as(u32, 11), @intFromEnum(gd.abi.ValueType.rect2));

    try std.testing.expectEqual(@as(usize, 16), @sizeOf(gd.abi.StringView));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(gd.abi.Vector(2, f64)));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(gd.abi.Vector(2, f32)));

    try std.testing.expectEqual(@as(usize, 48), @sizeOf(gd.abi.ValueData));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(gd.abi.Value));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(gd.abi.EngineApi));
    try std.testing.expectEqual(@as(usize, 136), @sizeOf(gd.abi.PropertyDescriptor));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(gd.abi.InspectorEntryDescriptor));
    try std.testing.expectEqual(@as(usize, 136), @sizeOf(gd.abi.ScriptDescriptor));

    try std.testing.expectEqual(@as(usize, 8), @alignOf(gd.abi.Value));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(gd.abi.Value, "data"));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(gd.abi.ScriptDescriptor, "create_instance"));
}

test "shared codec supports objects and nullable objects" {
    try std.testing.expect(gd.codec.isObjectType(TestObject));
    try std.testing.expect(!gd.codec.isObjectType(OwnerOnly));
    const object = TestObject{ .owner = 42 };
    const encoded = gd.codec.toValue(object);
    try std.testing.expectEqual(gd.abi.ValueType.object, encoded.type);
    try std.testing.expectEqual(@as(u64, 42), encoded.data.object_id);

    const decoded = try gd.codec.fromValue(TestObject, &encoded);
    try std.testing.expectEqual(@as(u64, 42), decoded.owner);

    const nullable_object: ?TestObject = object;
    const encoded_nullable = gd.codec.toValue(nullable_object);
    const decoded_nullable = try gd.codec.fromValue(?TestObject, &encoded_nullable);
    try std.testing.expectEqual(@as(u64, 42), decoded_nullable.?.owner);

    const nil_object: ?TestObject = null;
    const encoded_nil = gd.codec.toValue(nil_object);
    const decoded_nil = try gd.codec.fromValue(?TestObject, &encoded_nil);
    try std.testing.expectEqual(@as(?TestObject, null), decoded_nil);
}

test "shared codec round-trips ABI v5 value types" {
    const vector = gd.codec.toValue(gd.Vector(2, f64){ 3.0, 4.0 });
    try std.testing.expectEqual(gd.abi.ValueType.vector2, vector.type);
    const decoded_vector = try gd.codec.fromValue(gd.Vector(2, f64), &vector);
    try std.testing.expectEqual(@as(f64, 3.0), decoded_vector[0]);
    try std.testing.expectEqual(@as(f64, 4.0), decoded_vector[1]);

    const vector_f32 = gd.codec.toValue(gd.Vector(2, f32){ 3.0, 4.0 });
    try std.testing.expectEqual(gd.abi.ValueType.vector2, vector_f32.type);
    const decoded_f32 = try gd.codec.fromValue(gd.Vector(2, f32), &vector_f32);
    try std.testing.expectEqual(@as(f32, 3.0), decoded_f32[0]);
    try std.testing.expectEqual(@as(f32, 4.0), decoded_f32[1]);

    const floating = gd.codec.toValue(@as(f32, 1.5));
    try std.testing.expectEqual(@as(f32, 1.5), try gd.codec.fromValue(f32, &floating));

    const string = gd.codec.toValue(@as([]const u8, "zig"));
    try std.testing.expectEqualStrings("zig", try gd.codec.fromValue([]const u8, &string));

    const absent = gd.codec.toValue(@as(?TestObject, null));
    try std.testing.expectEqual(gd.abi.ValueType.nil, absent.type);
}

test "shared codec rejects integer overflow" {
    const encoded = gd.abi.Value{ .type = .integer, .data = .{ .integer = 256 } };
    try std.testing.expectError(error.IntegerOverflow, gd.codec.fromValue(u8, &encoded));
}

fn discardGetMethodBind(_: gd.abi.StringView, _: gd.abi.StringView, _: i64) callconv(.c) gd.abi.MethodBind {
    return null;
}

fn discardPtrcall(_: gd.abi.MethodBind, _: u64, _: ?[*]const ?*const anyopaque, _: ?*anyopaque) callconv(.c) gd.abi.Status {
    return .ok;
}

test "runtime preserves engine call errors" {
    const api = gd.abi.EngineApi{
        .abi_version = gd.abi.abi_version,
        .struct_size = @sizeOf(gd.abi.EngineApi),
        .log_info = discardLog,
        .log_error = discardLog,
        .object_call = missingMethodCall,
        .object_emit_signal = discardSignal,
        .get_method_bind = discardGetMethodBind,
        .object_ptrcall = discardPtrcall,
        .get_ticks_usec = zeroTicks,
    };

    var descriptor: *const gd.abi.ScriptDescriptor = undefined;
    try std.testing.expectEqual(
        gd.abi.Status.ok,
        gd.initialize(&api, &descriptor, &gd.ScriptAdapter(TestScript).descriptor),
    );
    try std.testing.expectError(
        error.MethodNotFound,
        (gd.Object{ .owner = 42 }).call("missing", &.{}),
    );
}

test "Node2D wrappers expose supported Godot 4.7 methods" {
    inline for (.{
        "setPosition",
        "setRotation",
        "setRotationDegrees",
        "setSkew",
        "setScale",
        "getPosition",
        "getRotation",
        "getRotationDegrees",
        "getSkew",
        "getScale",
        "rotate",
        "moveLocalX",
        "moveLocalY",
        "translate",
        "globalTranslate",
        "applyScale",
        "setGlobalPosition",
        "getGlobalPosition",
        "setGlobalRotation",
        "setGlobalRotationDegrees",
        "getGlobalRotation",
        "getGlobalRotationDegrees",
        "setGlobalSkew",
        "getGlobalSkew",
        "setGlobalScale",
        "getGlobalScale",
        "lookAt",
        "getAngleTo",
        "toLocal",
        "toGlobal",
    }) |method| {
        try std.testing.expect(@hasDecl(gd.Node2D, method));
        try std.testing.expect(@hasDecl(gd.Sprite2D, method));
    }
    try std.testing.expect(@hasDecl(gd.Node2D, "setTransform"));
}

test "scene and UI wrappers expose selected ABI v5 methods" {
    inline for (.{ gd.Node, gd.CanvasItem, gd.Control, gd.Node2D, gd.Sprite2D, gd.Node3D }) |Class| {
        try std.testing.expect(@hasDecl(Class, "getParent"));
        try std.testing.expect(@hasDecl(Class, "isInsideTree"));
    }
    inline for (.{ gd.CanvasItem, gd.Control, gd.Node2D, gd.Sprite2D }) |Class| {
        try std.testing.expect(@hasDecl(Class, "setVisible"));
        try std.testing.expect(@hasDecl(Class, "getVisibilityLayerBit"));
    }
    try std.testing.expect(@hasDecl(gd.Control, "setPosition"));
    try std.testing.expect(@hasDecl(gd.Control, "findValidFocusNeighbor"));
    try std.testing.expect(@hasDecl(gd.Sprite2D, "setCentered"));
    try std.testing.expect(@hasDecl(gd.Sprite2D, "getTexture"));
    try std.testing.expect(@hasDecl(gd.Node3D, "setRotationOrder"));
    try std.testing.expect(@hasDecl(gd.Node3D, "rotateX"));
    try std.testing.expect(@hasDecl(gd.Node3D, "setPosition"));
    try std.testing.expect(!@hasDecl(gd.Texture2D, "setTexture"));
}

test "generated upcasts preserve object identity" {
    const control = gd.Control{ .owner = 41 };
    try std.testing.expectEqual(control.owner, control.asCanvasItem().owner);
    try std.testing.expectEqual(control.owner, control.asNode().owner);

    const sprite = gd.Sprite2D{ .owner = 42 };
    try std.testing.expectEqual(sprite.owner, sprite.asNode2D().owner);
    try std.testing.expectEqual(sprite.owner, sprite.asCanvasItem().owner);
    try std.testing.expectEqual(sprite.owner, sprite.asNode().owner);

    const node3d = gd.Node3D{ .owner = 43 };
    try std.testing.expectEqual(node3d.owner, node3d.asNode().owner);
}

test "generated tagged enums preserve Godot values" {
    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(gd.Side.left));
    try std.testing.expectEqual(@as(i64, 3), @intFromEnum(gd.Side.bottom));
    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(gd.EulerOrder.xyz));
    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(gd.Node.ProcessMode.inherit));
    try std.testing.expectEqual(@as(i64, 8), @intFromEnum(gd.Control.LayoutPreset.center));
    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(gd.Node3D.RotationEditMode.euler));
    try std.testing.expectEqual(
        gd.Control.LayoutDirection.application_locale,
        gd.Control.LayoutDirection.locale,
    );
}

test "shared codec safely round-trips generated enums" {
    const order = gd.EulerOrder.zyx;

    const encoded_order = gd.codec.toValue(order);
    try std.testing.expectEqual(gd.abi.ValueType.integer, encoded_order.type);
    try std.testing.expectEqual(order, try gd.codec.fromValue(gd.EulerOrder, &encoded_order));

    const combined_flags: gd.Control.SizeFlags = @enumFromInt(5);
    const encoded_flags = gd.codec.toValue(combined_flags);
    try std.testing.expectEqual(combined_flags, try gd.codec.fromValue(gd.Control.SizeFlags, &encoded_flags));

    const invalid = gd.abi.Value{ .type = .integer, .data = .{ .integer = 99 } };
    try std.testing.expectError(error.InvalidEnumValue, gd.codec.fromValue(gd.Side, &invalid));
}

test "class factories preserve identity and ABI layout" {
    comptime {
        if (gd.Node == gd.Control) @compileError("Node and Control must be distinct types");
        if (gd.Node2D == gd.Sprite2D) @compileError("Node2D and Sprite2D must be distinct types");
        if (gd.CanvasItem == gd.Node2D) @compileError("CanvasItem and Node2D must be distinct types");
        if (gd.Node == gd.Node3D) @compileError("Node and Node3D must be distinct types");
    }

    try std.testing.expectEqualStrings("Node", gd.Node.godot_class);
    try std.testing.expectEqualStrings("CanvasItem", gd.CanvasItem.godot_class);
    try std.testing.expectEqualStrings("Control", gd.Control.godot_class);
    try std.testing.expectEqualStrings("Node2D", gd.Node2D.godot_class);
    try std.testing.expectEqualStrings("Sprite2D", gd.Sprite2D.godot_class);
    try std.testing.expectEqualStrings("Node3D", gd.Node3D.godot_class);
    try std.testing.expectEqualStrings("Texture2D", gd.Texture2D.godot_class);
    try std.testing.expectEqualStrings("Viewport", gd.Viewport.godot_class);
    try std.testing.expectEqualStrings("Tween", gd.Tween.godot_class);

    inline for (.{ gd.Node, gd.CanvasItem, gd.Control, gd.Node2D, gd.Sprite2D, gd.Node3D, gd.Texture2D, gd.Viewport, gd.Tween }) |Class| {
        try std.testing.expectEqual(@sizeOf(u64), @sizeOf(Class));
        try std.testing.expectEqual(@alignOf(u64), @alignOf(Class));
        try std.testing.expectEqual(@as(usize, 0), @offsetOf(Class, "owner"));
        try std.testing.expect(@hasDecl(Class, "emitSignal"));
    }

    try std.testing.expect(!@hasDecl(gd.Node, "setPosition"));
}
