pub const abi_version: u32 = 2;

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
};

pub const Vector2 = extern struct { x: f64, y: f64 };

pub const ValueData = extern union {
    boolean: bool,
    integer: i64,
    floating: f64,
    string: StringView,
    vector2: Vector2,
    object_id: u64,
};

pub const Value = extern struct {
    type: ValueType = .nil,
    reserved: u32 = 0,
    data: ValueData = .{ .integer = 0 },
};

pub const PropertyHint = enum(u32) { none = 0, range = 1 };

pub const MethodDescriptor = extern struct {
    name: StringView,
    argument_count: u32,
    flags: u32 = 0,
};

pub const PropertyDescriptor = extern struct {
    name: StringView,
    type: ValueType,
    hint: PropertyHint,
    category: StringView,
    range_min: f64,
    range_max: f64,
    range_step: f64,
    default_value: Value,
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

pub const EngineApi = extern struct {
    abi_version: u32,
    struct_size: u32,
    log_info: *const fn (StringView) callconv(.c) void,
    log_error: *const fn (StringView) callconv(.c) void,
    object_call: *const fn (u64, StringView, ?[*]const Value, u32, *Value) callconv(.c) Status,
    object_emit_signal: *const fn (u64, StringView, ?[*]const Value, u32) callconv(.c) Status,
};

pub const ScriptDescriptor = extern struct {
    abi_version: u32,
    struct_size: u32,
    base_class: StringView,
    methods: ?[*]const MethodDescriptor,
    method_count: u32,
    properties: ?[*]const PropertyDescriptor,
    property_count: u32,
    signals: ?[*]const SignalDescriptor,
    signal_count: u32,
    create_instance: *const fn (u64, *?*anyopaque) callconv(.c) Status,
    destroy_instance: *const fn (?*anyopaque) callconv(.c) void,
    call_method: *const fn (?*anyopaque, StringView, ?[*]const Value, u32, *Value) callconv(.c) Status,
    get_property: *const fn (?*anyopaque, u32, *Value) callconv(.c) Status,
    set_property: *const fn (?*anyopaque, u32, *const Value) callconv(.c) Status,
    notification: *const fn (?*anyopaque, i32, bool) callconv(.c) void,
};
