const std = @import("std");
const extension_api = @import("extension_api.zig");
const generator = @import("generate_bindings.zig");

fn generatedFile(files: []const generator.GeneratedFile, path: []const u8) ?[]const u8 {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file.contents;
    return null;
}

test "extension API parses renderer fields and ignores unrelated metadata" {
    const source =
        \\{
        \\  "header": {
        \\    "version_major": 4,
        \\    "version_minor": 7,
        \\    "version_patch": 0,
        \\    "version_status": "stable",
        \\    "precision": "single",
        \\    "version_build": "official"
        \\  },
        \\  "global_enums": [{
        \\    "name": "Flags",
        \\    "is_bitfield": true,
        \\    "values": [{"name":"FLAGS_ONE","value":1},{"name":"FLAGS_TWO","value":2}]
        \\  }],
        \\  "classes": [{
        \\    "name": "Object",
        \\    "api_type": "core",
        \\    "methods": [{
        \\      "name": "attach",
        \\      "hash": 3863233950,
        \\      "arguments": [{"name":"child","type":"Node","meta":"required"}],
        \\      "is_const": true
        \\    }]
        \\  }, {
        \\    "name": "Node",
        \\    "inherits": "Object"
        \\  }],
        \\  "singletons": []
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var api = try extension_api.parse(arena.allocator(), source);
    try api.buildIndex(arena.allocator());

    try std.testing.expectEqual(@as(i64, 3863233950), api.class("Object").?.methods[0].hash);
    try std.testing.expectEqualStrings("required", api.class("Object").?.methods[0].arguments[0].meta.?);
    try std.testing.expect(api.class("Node").?.methods.len == 0);
    try std.testing.expect(api.global_enums[0].is_bitfield);
    try std.testing.expectEqualStrings("FLAGS_TWO", api.global_enums[0].values[1].name);

    var chain = try api.inheritanceChain(arena.allocator(), "Node");
    defer chain.deinit(arena.allocator());
    try std.testing.expectEqualStrings("Object", chain.items[0].name);
    try std.testing.expectEqualStrings("Node", chain.items[1].name);
}

test "Godot names become Zig method names" {
    const set_position = try generator.camelCase(std.testing.allocator, "set_position");
    defer std.testing.allocator.free(set_position);
    const get_node_2d = try generator.camelCase(std.testing.allocator, "get_node_2d");
    defer std.testing.allocator.free(get_node_2d);

    try std.testing.expectEqualStrings("setPosition", set_position);
    try std.testing.expectEqualStrings("getNode2D", get_node_2d);
}

test "Zig keywords are escaped" {
    const escaped = try generator.identifier(std.testing.allocator, "error");
    defer std.testing.allocator.free(escaped);
    const position = try generator.identifier(std.testing.allocator, "position");
    defer std.testing.allocator.free(position);

    try std.testing.expectEqualStrings("@\"error\"", escaped);
    try std.testing.expectEqualStrings("position", position);
}

test "invalid root selections are rejected" {
    const api =
        \\{
        \\  "header":{"version_major":4,"version_minor":7,"version_patch":0,"version_status":"stable","precision":"single"},
        \\  "classes":[
        \\    {"name":"Object","methods":[{"name":"get_viewport","return_value":{"type":"Viewport"}}]},
        \\    {"name":"Viewport"}
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingRoots, generator.renderTree(arena.allocator(), api, "{}"));
    try std.testing.expectError(error.ProfileClassNotFound, generator.renderTree(arena.allocator(), api, "{\"roots\":[\"Missing\"]}"));
}

test "double precision APIs are rejected" {
    const api =
        \\{
        \\  "header":{"version_major":4,"version_minor":7,"version_patch":0,"version_status":"stable","precision":"double"},
        \\  "classes":[{"name":"Node"}]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedPrecision,
        generator.renderTree(arena.allocator(), api, "{\"roots\":[\"Node\"]}"),
    );
}

test "root policy selects eligible methods and derives signature dependencies" {
    const api =
        \\{
        \\  "header":{"version_major":4,"version_minor":7,"version_patch":0,"version_status":"stable","precision":"single"},
        \\  "global_enums":[{"name":"Side","values":[{"name":"SIDE_LEFT","value":0}]}],
        \\  "classes":[
        \\    {"name":"Node","enums":[{"name":"Mode","values":[{"name":"MODE_IDLE","value":0}]}],"methods":[
        \\      {"name":"set_count","hash":1,"arguments":[{"name":"count","type":"int"}]},
        \\      {"name":"set_side","hash":2,"arguments":[{"name":"side","type":"enum::Side"}]},
        \\      {"name":"set_mode","hash":3,"arguments":[{"name":"mode","type":"enum::Node.Mode"}]},
        \\      {"name":"get_child","return_value":{"type":"Child"}},
        \\      {"name":"set_vector_3","arguments":[{"name":"value","type":"Vector3"}]},
        \\      {"name":"virtual_method","is_virtual":true}
        \\    ]},
        \\    {"name":"Child"}
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = try generator.renderTree(arena.allocator(), api, "{\"roots\":[\"Node\"]}");
    const node = generatedFile(files, "generated_classes/classes/node.zig") orelse return error.MissingNodeModule;
    const enums = generatedFile(files, "generated_classes/global_enums.zig") orelse return error.MissingGlobalEnums;
    const index = generatedFile(files, "generated_classes/index.zig") orelse return error.MissingIndex;

    try std.testing.expect(std.mem.indexOf(u8, enums, "pub const Side = enum(i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, node, "pub const Mode = enum(i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, index, "pub const Child = @import") != null);
    try std.testing.expect(std.mem.indexOf(u8, node, "pub fn setCount(self: @This(), count: i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, node, "pub fn getChild(self: @This()) !?Child") != null);
    try std.testing.expect(std.mem.indexOf(u8, node, "setVector3") == null);
    try std.testing.expect(std.mem.indexOf(u8, node, "virtualMethod") == null);
}

test "ptrcall rejects object IDs and narrowed scalar metadata" {
    const api =
        \\{
        \\  "header":{"version_major":4,"version_minor":7,"version_patch":0,"version_status":"stable","precision":"single"},
        \\  "classes":[
        \\    {"name":"Node","methods":[
        \\      {"name":"attach","hash":1,"arguments":[{"name":"child","type":"Child","meta":"required"}]},
        \\      {"name":"get_count","hash":2,"return_value":{"type":"int","meta":"int32"}},
        \\      {"name":"set_weight","hash":3,"arguments":[{"name":"weight","type":"float","meta":"float"}]},
        \\      {"name":"get_index","hash":4,"return_value":{"type":"int"}}
        \\    ]},
        \\    {"name":"Child"}
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = try generator.renderTree(arena.allocator(), api, "{\"roots\":[\"Node\"]}");
    const output = generatedFile(files, "generated_classes/classes/node.zig") orelse return error.MissingNodeModule;

    try std.testing.expect(std.mem.indexOf(u8, output, "support.callVoid(self, \"attach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "support.call(self, i64, \"get_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "support.callVoid(self, \"set_weight\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn getIndex(self: @This()) !i64 { return support.ptrcallMethod(self, i64, \"Node\", \"get_index\", 4, .{}); }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const runtime =") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_mb_") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_mb_attach") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_mb_get_count") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_mb_set_weight") == null);
}

test "binding tree groups cycles and emits deterministic class modules" {
    const api =
        \\{
        \\  "header":{"version_major":4,"version_minor":7,"version_patch":0,"version_status":"stable","precision":"single"},
        \\  "global_enums":[{"name":"Side","values":[{"name":"SIDE_LEFT","value":0}]}],
        \\  "classes":[
        \\    {"name":"A","methods":[{"name":"get_b","return_value":{"type":"B"}}]},
        \\    {"name":"B","methods":[{"name":"get_a","return_value":{"type":"A"}}]},
        \\    {"name":"Node2D","methods":[
        \\      {"name":"set_side","arguments":[{"name":"side","type":"enum::Side"}]},
        \\      {"name":"set_position","arguments":[{"name":"position","type":"Vector2"}]}
        \\    ]}
        \\  ]
        \\}
    ;
    const profile = "{\"roots\":[\"A\",\"B\",\"Node2D\"]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const files = try generator.renderTree(arena.allocator(), api, profile);
    const second = try generator.renderTree(arena.allocator(), api, profile);

    try std.testing.expect(generatedFile(files, "class.zig") != null);
    try std.testing.expect(generatedFile(files, "generated_classes/index.zig") != null);
    try std.testing.expect(generatedFile(files, "generated_classes/global_enums.zig") != null);
    try std.testing.expect(generatedFile(files, "generated_classes/classes/node_2d.zig") != null);
    const cycle = generatedFile(files, "generated_classes/cycles/a__b.zig") orelse return error.MissingCycleShard;
    try std.testing.expect(std.mem.indexOf(u8, cycle, "pub const A = extern struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, cycle, "pub const B = extern struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, cycle, "pub fn getB(self: @This()) !?B { return support.call(self, ?B, \"get_b\", .{}); }") != null);
    try std.testing.expect(std.mem.indexOf(u8, cycle, "_mb_") == null);
    try std.testing.expect(std.mem.indexOf(u8, cycle, "const abi =") == null);
    try std.testing.expect(std.mem.indexOf(u8, cycle, "const Side =") == null);

    const node_2d = generatedFile(files, "generated_classes/classes/node_2d.zig") orelse return error.MissingNode2DModule;
    try std.testing.expect(std.mem.indexOf(u8, node_2d, "const Side = @import") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_2d, "const abi = @import") != null);

    try std.testing.expectEqual(files.len, second.len);
    for (files, second) |first_file, second_file| {
        try std.testing.expectEqualStrings(first_file.path, second_file.path);
        try std.testing.expectEqualStrings(first_file.contents, second_file.contents);
    }
}

test "binding tree sync removes only manifested stale files and detects drift" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{temporary.sub_path});
    const sentinel = generator.GeneratedFile{
        .path = "generated_classes/.generated-bindings",
        .contents = "Generated by tools/generate_bindings.zig. Do not edit.\n",
    };
    const first = [_]generator.GeneratedFile{
        sentinel,
        .{ .path = "generated_classes/classes/a.zig", .contents = "a\n" },
        .{ .path = "generated_classes/manifest.txt", .contents = "classes/a.zig\n" },
    };
    try generator.syncTree(std.testing.io, allocator, root, &first, false);
    try generator.syncTree(std.testing.io, allocator, root, &first, true);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "generated_classes/keep.txt", .data = "keep\n" });

    const second = [_]generator.GeneratedFile{
        sentinel,
        .{ .path = "generated_classes/classes/b.zig", .contents = "b\n" },
        .{ .path = "generated_classes/manifest.txt", .contents = "classes/b.zig\n" },
    };
    try generator.syncTree(std.testing.io, allocator, root, &second, false);
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "generated_classes/classes/a.zig", .{}));
    _ = try temporary.dir.statFile(std.testing.io, "generated_classes/classes/b.zig", .{});
    _ = try temporary.dir.statFile(std.testing.io, "generated_classes/keep.txt", .{});

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "generated_classes/classes/orphan.zig", .data = "orphan\n" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "generated_classes/old_index.zig", .data = "orphan\n" });
    try std.testing.expectError(error.StaleBindings, generator.syncTree(std.testing.io, allocator, root, &second, true));
    try generator.syncTree(std.testing.io, allocator, root, &second, false);
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "generated_classes/classes/orphan.zig", .{}));
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(std.testing.io, "generated_classes/old_index.zig", .{}));
    _ = try temporary.dir.statFile(std.testing.io, "generated_classes/keep.txt", .{});

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "generated_classes/classes/b.zig", .data = "changed\n" });
    try std.testing.expectError(error.StaleBindings, generator.syncTree(std.testing.io, allocator, root, &second, true));

    const unsafe = [_]generator.GeneratedFile{.{ .path = "generated_classes\\..\\escape.zig", .contents = "unsafe\n" }};
    try std.testing.expectError(error.InvalidGeneratedPath, generator.syncTree(std.testing.io, allocator, root, &unsafe, true));
}

test "enum aliases and bitfields preserve their semantics" {
    const api =
        \\{
        \\  "header":{"version_major":4,"version_minor":7,"version_patch":0,"version_status":"stable","precision":"single"},
        \\  "global_enums":[{"name":"Flags","is_bitfield":true,"values":[
        \\    {"name":"FLAGS_NONE","value":0},
        \\    {"name":"FLAGS_DEFAULT","value":0},
        \\    {"name":"FLAGS_VISIBLE","value":1}
        \\  ]}],
        \\  "classes":[{"name":"Object","methods":[{"name":"set_flags","arguments":[{"name":"flags","type":"bitfield::Flags"}]}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const files = try generator.renderTree(arena.allocator(), api, "{\"roots\":[\"Object\"]}");
    const output = generatedFile(files, "generated_classes/global_enums.zig") orelse return error.MissingGlobalEnums;

    try std.testing.expect(std.mem.indexOf(u8, output, "pub const Flags = enum(i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "    _,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const default: @This() = .none;") != null);
}

test "generated bindings and public SDK exports match" {
    const allocator = std.testing.allocator;
    const index_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "addons/gzscript/zig/generated_classes/index.zig", allocator, .unlimited);
    defer allocator.free(index_source);
    const godot_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "addons/gzscript/zig/godot.zig", allocator, .unlimited);
    defer allocator.free(godot_source);

    var generated = std.StringHashMap(void).init(allocator);
    defer generated.deinit();
    var lines = std.mem.splitScalar(u8, index_source, '\n');
    while (lines.next()) |line| {
        const prefix = "pub const ";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const separator = std.mem.indexOf(u8, line, " = @import(") orelse continue;
        const name = line[prefix.len..separator];
        try generated.put(name, {});
        const expected = try std.fmt.allocPrint(allocator, "pub const {s} = classes.{s};", .{ name, name });
        defer allocator.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, godot_source, expected) != null);
    }

    lines = std.mem.splitScalar(u8, godot_source, '\n');
    while (lines.next()) |line| {
        const prefix = "pub const ";
        const separator = " = classes.";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const separator_index = std.mem.indexOf(u8, line, separator) orelse continue;
        const name = line[prefix.len..separator_index];
        try std.testing.expect(generated.contains(name));
    }
}
