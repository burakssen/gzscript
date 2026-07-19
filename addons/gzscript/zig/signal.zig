pub fn Signal(comptime argument_types: anytype) type {
    if (@typeInfo(@TypeOf(argument_types)) != .@"struct")
        @compileError("signal arguments must be a named struct");
    inline for (@typeInfo(@TypeOf(argument_types)).@"struct".fields) |field| {
        if (field.type != type)
            @compileError("signal argument must be a type: " ++ field.name);
    }
    return struct {
        pub const arguments = argument_types;
    };
}

pub fn signal(comptime argument_types: anytype) Signal(argument_types) {
    return .{};
}
