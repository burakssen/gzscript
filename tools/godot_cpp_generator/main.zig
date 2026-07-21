const std = @import("std");
const generator = @import("generator.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) {
        std.debug.print("usage: godot-cpp-generator EXTENSION_API_JSON GDEXTENSION_INTERFACE_JSON OUTPUT_DIR\n", .{});
        return error.InvalidArguments;
    }

    const cwd = std.Io.Dir.cwd();
    const api_source = try cwd.readFileAlloc(init.io, args[1], allocator, .unlimited);
    const interface_source = try cwd.readFileAlloc(init.io, args[2], allocator, .unlimited);
    try generator.generateTree(allocator, init.io, cwd, args[3], api_source, interface_source);
}
