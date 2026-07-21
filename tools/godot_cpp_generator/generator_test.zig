const std = @import("std");
const generator = @import("generator.zig");

test "only the pinned Godot ABI is accepted" {
    const supported =
        \\{"header":{"version_major":4,"version_minor":7,"precision":"single"}}
    ;
    const wrong_version =
        \\{"header":{"version_major":4,"version_minor":6,"precision":"single"}}
    ;
    const wrong_precision =
        \\{"header":{"version_major":4,"version_minor":7,"precision":"double"}}
    ;

    try generator.validateApi(std.testing.allocator, supported);
    try std.testing.expectError(error.UnsupportedGodotVersion, generator.validateApi(std.testing.allocator, wrong_version));
    try std.testing.expectError(error.UnsupportedPrecision, generator.validateApi(std.testing.allocator, wrong_precision));
}

test "snapshot restores the complete generated tree" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    // ponytail: the snapshot is immutable because Godot, precision, and pointer width are pinned.
    try generator.extractSnapshot(std.testing.io, temporary.dir, "out");
    try std.testing.expect((try temporary.dir.statFile(std.testing.io, "out/gen/include/godot_cpp/classes/object.hpp", .{})).kind == .file);
    try std.testing.expect((try temporary.dir.statFile(std.testing.io, "out/gen/include/godot_cpp/variant/string.hpp", .{})).kind == .file);
    try std.testing.expect((try temporary.dir.statFile(std.testing.io, "out/gen/src/all_generated.cpp", .{})).kind == .file);
}

test "snapshot rejects metadata outside the pinned revision" {
    try std.testing.expectError(error.UnexpectedApiMetadata, generator.validatePinnedInputs("{}", "{}"));
}

test "snapshot revision matches the package pin" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig.zon", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, generator.godot_cpp_revision) != null);
}
