pub const abi_version: u32 = 5;

pub const StringView = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn from(value: []const u8) StringView {
        return .{ .ptr = value.ptr, .len = value.len };
    }

    pub fn slice(self: StringView) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    method_not_found = 2,
    property_not_found = 3,
    type_mismatch = 4,
    out_of_memory = 5,
    script_error = 6,
    abi_mismatch = 7,
};

pub const ValueType = enum(u32) {
    nil = 0,
    boolean = 1,
    integer = 2,
    floating = 3,
    string = 4,
    vector2 = 5,
    object = 6,
    vector3 = 7,
    color = 8,
    transform2d = 9,
    transform3d = 10,
    rect2 = 11,
};

pub fn Vector(comptime N: comptime_int, comptime T: type) type {
    if (N != 2 and N != 3) @compileError("ABI vectors must have 2 or 3 elements");
    return [N]T;
}

pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
};

pub const Transform2D = extern struct {
    x: Vector(2, f32) = .{ 1, 0 },
    y: Vector(2, f32) = .{ 0, 1 },
    origin: Vector(2, f32) = .{ 0, 0 },
};

pub const Transform3D = extern struct {
    basis: [3]Vector(3, f32) = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } },
    origin: Vector(3, f32) = .{ 0, 0, 0 },
};

pub const Rect2 = extern struct {
    position: Vector(2, f32) = .{ 0, 0 },
    size: Vector(2, f32) = .{ 0, 0 },
};

pub const ValueData = extern union {
    boolean: bool,
    integer: i64,
    floating: f64,
    string: StringView,
    vector2: Vector(2, f32),
    vector3: Vector(3, f32),
    color: Color,
    transform2d: Transform2D,
    transform3d: Transform3D,
    rect2: Rect2,
    object_id: u64,
};

pub const Value = extern struct {
    type: ValueType = .nil,
    reserved: u32 = 0,
    data: ValueData = .{ .integer = 0 },
};

pub const PropertyHint = enum(u32) {
    none = 0,
    range = 1,
    @"enum" = 2,
    file = 13,
    multiline_text = 18,
};

pub const MethodDescriptor = extern struct {
    name: StringView,
    argument_count: u32,
    flags: u32 = 0,
};

pub const PropertyDescriptor = extern struct {
    name: StringView,
    type: ValueType,
    hint: PropertyHint,
    hint_string: StringView,
    class_name: StringView,
    range_min: f64,
    range_max: f64,
    range_step: f64,
    default_value: Value,
};

pub const InspectorEntryKind = enum(u32) {
    property = 0,
    category = 1,
    group = 2,
    subgroup = 3,
};

pub const InspectorEntryDescriptor = extern struct {
    kind: InspectorEntryKind,
    property_index: u32 = 0,
    name: StringView,
    prefix: StringView,
};

pub const SignalArgumentDescriptor = extern struct {
    name: StringView,
    type: ValueType,
};

pub const SignalDescriptor = extern struct {
    name: StringView,
    arguments: ?[*]const SignalArgumentDescriptor,
    argument_count: u32,
};

pub const MethodBind = ?*anyopaque;

pub const EngineApi = extern struct {
    abi_version: u32,
    struct_size: u32,
    log_info: *const fn (StringView) callconv(.c) void,
    log_error: *const fn (StringView) callconv(.c) void,
    object_call: *const fn (u64, StringView, ?[*]const Value, u32, *Value) callconv(.c) Status,
    object_emit_signal: *const fn (u64, StringView, ?[*]const Value, u32) callconv(.c) Status,
    get_method_bind: *const fn (StringView, StringView, i64) callconv(.c) MethodBind,
    object_ptrcall: *const fn (MethodBind, u64, ?[*]const ?*const anyopaque, ?*anyopaque) callconv(.c) Status,
    get_ticks_usec: *const fn () callconv(.c) u64,
};

pub const ScriptDescriptor = extern struct {
    abi_version: u32,
    struct_size: u32,
    base_class: StringView,
    methods: ?[*]const MethodDescriptor,
    method_count: u32,
    properties: ?[*]const PropertyDescriptor,
    property_count: u32,
    inspector_entries: ?[*]const InspectorEntryDescriptor,
    inspector_entry_count: u32,
    signals: ?[*]const SignalDescriptor,
    signal_count: u32,
    create_instance: *const fn (u64, *?*anyopaque) callconv(.c) Status,
    destroy_instance: *const fn (?*anyopaque) callconv(.c) void,
    call_method: *const fn (?*anyopaque, StringView, ?[*]const Value, u32, *Value) callconv(.c) Status,
    get_property: *const fn (?*anyopaque, u32, *Value) callconv(.c) Status,
    set_property: *const fn (?*anyopaque, u32, *const Value) callconv(.c) Status,
    notification: *const fn (?*anyopaque, i32, bool) callconv(.c) void,
};
