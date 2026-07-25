const std = @import("std");
const extension_api = @import("extension_api.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const checking = args.len == 5 and std.mem.eql(u8, args[1], "--check");
    if ((!checking and args.len != 4) or (checking and args.len != 5)) return error.InvalidArguments;
    const offset: usize = if (checking) 1 else 0;

    const api_source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1 + offset], allocator, .unlimited);
    const profile_source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2 + offset], allocator, .unlimited);
    const files = try renderTree(allocator, api_source, profile_source);
    try syncTree(init.io, allocator, args[3 + offset], files, checking);
}

const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "addrspace", {} },      .{ "align", {} },    .{ "allowzero", {} },
    .{ "and", {} },            .{ "anyframe", {} }, .{ "anytype", {} },
    .{ "asm", {} },            .{ "async", {} },    .{ "await", {} },
    .{ "break", {} },          .{ "callconv", {} }, .{ "catch", {} },
    .{ "comptime", {} },       .{ "const", {} },    .{ "continue", {} },
    .{ "defer", {} },          .{ "else", {} },     .{ "enum", {} },
    .{ "errdefer", {} },       .{ "error", {} },    .{ "export", {} },
    .{ "extern", {} },         .{ "fn", {} },       .{ "for", {} },
    .{ "if", {} },             .{ "inline", {} },   .{ "linksection", {} },
    .{ "noalias", {} },        .{ "noinline", {} }, .{ "nosuspend", {} },
    .{ "opaque", {} },         .{ "or", {} },       .{ "orelse", {} },
    .{ "packed", {} },         .{ "pub", {} },      .{ "resume", {} },
    .{ "return", {} },         .{ "struct", {} },   .{ "suspend", {} },
    .{ "switch", {} },         .{ "test", {} },     .{ "threadlocal", {} },
    .{ "try", {} },            .{ "union", {} },    .{ "unreachable", {} },
    .{ "usingnamespace", {} }, .{ "var", {} },      .{ "volatile", {} },
    .{ "while", {} },
});

pub fn identifier(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (zig_keywords.has(name)) return std.fmt.allocPrint(allocator, "@\"{s}\"", .{name});
    return allocator.dupe(u8, name);
}

pub fn camelCase(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var parts = std.mem.splitScalar(u8, name, '_');
    if (parts.next()) |head| try result.appendSlice(allocator, head);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "2d")) {
            try result.appendSlice(allocator, "2D");
        } else if (std.mem.eql(u8, part, "3d")) {
            try result.appendSlice(allocator, "3D");
        } else if (part.len != 0) {
            try result.append(allocator, std.ascii.toUpper(part[0]));
            try result.appendSlice(allocator, part[1..]);
        }
    }
    return result.toOwnedSlice(allocator);
}

const Value = std.json.Value;
const StringSet = std.StringHashMap(void);
const TypeMap = std.StringHashMap([]const u8);

const ResolvedBindings = struct {
    api: *const extension_api.ExtensionApi,
    root_names: std.ArrayList([]const u8),
    root_set: StringSet,
    methods_by_class: std.StringHashMap(std.ArrayList(*const extension_api.Method)),
    generated_names: std.ArrayList([]const u8),
    generated_set: StringSet,
    shell_set: StringSet,
    enum_types: TypeMap,
    global_enums: std.ArrayList(*const extension_api.ApiEnum),
    class_enums: std.StringHashMap(std.ArrayList(*const extension_api.ApiEnum)),
};

pub const GeneratedFile = struct {
    path: []const u8,
    contents: []const u8,
};

pub fn syncTree(io: std.Io, allocator: std.mem.Allocator, output_root: []const u8, files: []const GeneratedFile, checking: bool) !void {
    const cwd = std.Io.Dir.cwd();
    const generated_root = try std.fs.path.join(allocator, &.{ output_root, "generated_classes" });
    const sentinel_path = try std.fs.path.join(allocator, &.{ generated_root, ".generated-bindings" });
    const manifest_path = try std.fs.path.join(allocator, &.{ generated_root, "manifest.txt" });
    var expected = StringSet.init(allocator);
    for (files) |file| {
        try validateGeneratedPath(file.path);
        if (std.mem.startsWith(u8, file.path, "generated_classes/") and !std.mem.eql(u8, file.path, "generated_classes/.generated-bindings") and !std.mem.eql(u8, file.path, "generated_classes/manifest.txt"))
            try expected.put(file.path["generated_classes/".len..], {});
    }

    if (!checking) {
        const generated_exists = if (cwd.statFile(io, generated_root, .{})) |_| true else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
        if (generated_exists) {
            const sentinel = cwd.readFileAlloc(io, sentinel_path, allocator, .unlimited) catch |err| switch (err) {
                error.FileNotFound => return error.UnownedGeneratedDirectory,
                else => return err,
            };
            if (!std.mem.eql(u8, sentinel, "Generated by tools/generate_bindings.zig. Do not edit.\n")) return error.UnownedGeneratedDirectory;
        }

        const previous_manifest = cwd.readFileAlloc(io, manifest_path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (previous_manifest) |manifest| {
            var lines = std.mem.splitScalar(u8, manifest, '\n');
            while (lines.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                if (line.len == 0 or expected.contains(line)) continue;
                try validateGeneratedPath(line);
                const stale_path = try std.fs.path.join(allocator, &.{ generated_root, line });
                cwd.deleteFile(io, stale_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
        }
    }

    try reconcileManagedFiles(io, allocator, generated_root, &expected, checking);

    for (files) |generated_file| {
        const full_path = try std.fs.path.join(allocator, &.{ output_root, generated_file.path });
        if (checking) {
            const existing = cwd.readFileAlloc(io, full_path, allocator, .unlimited) catch return error.StaleBindings;
            if (!std.mem.eql(u8, existing, generated_file.contents)) return error.StaleBindings;
        } else {
            try cwd.createDirPath(io, std.fs.path.dirname(full_path).?);
            const file = try cwd.createFile(io, full_path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, generated_file.contents);
        }
    }
}

fn validateGeneratedPath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidGeneratedPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidGeneratedPath;
}

fn reconcileManagedFiles(io: std.Io, allocator: std.mem.Allocator, generated_root: []const u8, expected: *const StringSet, checking: bool) !void {
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, generated_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer root.close(io);
    var root_walker = try root.walk(allocator);
    defer root_walker.deinit();
    var stale_root_files: std.ArrayList([]const u8) = .empty;
    while (try root_walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null or std.mem.indexOfScalar(u8, entry.path, '\\') != null) continue;
        if (expected.contains(entry.path)) continue;
        if (checking) return error.StaleBindings;
        try stale_root_files.append(allocator, try allocator.dupe(u8, entry.path));
    }
    for (stale_root_files.items) |path| try root.deleteFile(io, path);

    for ([_][]const u8{ "classes", "cycles" }) |directory_name| {
        const directory_path = try std.fs.path.join(allocator, &.{ generated_root, directory_name });
        var directory = cwd.openDir(io, directory_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer directory.close(io);
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        var stale: std.ArrayList([]const u8) = .empty;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory_name, entry.path });
            for (key) |*character| if (character.* == '\\') {
                character.* = '/';
            };
            if (expected.contains(key)) continue;
            if (checking) return error.StaleBindings;
            try stale.append(allocator, try allocator.dupe(u8, entry.path));
        }
        for (stale.items) |path| try directory.deleteFile(io, path);
    }
}

const ClassComponent = struct {
    members: std.ArrayList([]const u8),
    path: []const u8,
};

fn resolveBindings(arena: std.mem.Allocator, api: *const extension_api.ExtensionApi, roots: *const std.json.Array) !ResolvedBindings {
    var root_names: std.ArrayList([]const u8) = .empty;
    var root_set = StringSet.init(arena);
    for (roots.items) |*root_value| {
        const name = try stringValue(root_value);
        if (root_set.contains(name)) return error.DuplicateProfileClass;
        if (api.class(name) == null) return error.ProfileClassNotFound;
        try root_set.put(name, {});
        try root_names.append(arena, name);
    }

    var methods_by_class = std.StringHashMap(std.ArrayList(*const extension_api.Method)).init(arena);
    for (root_names.items) |class_name| {
        try methods_by_class.put(class_name, try automaticMethods(arena, api, class_name, &root_set));
    }

    var generated_names = std.ArrayList([]const u8).empty;
    try generated_names.appendSlice(arena, root_names.items);
    var generated_set = StringSet.init(arena);
    for (root_names.items) |name| try generated_set.put(name, {});
    var shell_set = StringSet.init(arena);
    var enum_types = TypeMap.init(arena);
    var global_enums: std.ArrayList(*const extension_api.ApiEnum) = .empty;
    var global_enum_set = StringSet.init(arena);
    var class_enums = std.StringHashMap(std.ArrayList(*const extension_api.ApiEnum)).init(arena);
    var class_enum_set = StringSet.init(arena);

    for (root_names.items) |class_name| {
        for (methods_by_class.get(class_name).?.items) |method| {
            for (method.arguments) |*argument| try collectTypeDependencies(
                arena,
                api,
                argument.typeRef(),
                &generated_names,
                &generated_set,
                &shell_set,
                &enum_types,
                &global_enums,
                &global_enum_set,
                &class_enums,
                &class_enum_set,
            );
            if (method.return_value) |*return_value| try collectTypeDependencies(
                arena,
                api,
                return_value.typeRef(),
                &generated_names,
                &generated_set,
                &shell_set,
                &enum_types,
                &global_enums,
                &global_enum_set,
                &class_enums,
                &class_enum_set,
            );
        }
    }

    return .{
        .api = api,
        .root_names = root_names,
        .root_set = root_set,
        .methods_by_class = methods_by_class,
        .generated_names = generated_names,
        .generated_set = generated_set,
        .shell_set = shell_set,
        .enum_types = enum_types,
        .global_enums = global_enums,
        .class_enums = class_enums,
    };
}

pub fn renderTree(allocator: std.mem.Allocator, api_source: []const u8, profile_source: []const u8) ![]GeneratedFile {
    var api = try extension_api.parse(allocator, api_source);
    try api.buildIndex(allocator);
    if (api.header.version_major != 4 or api.header.version_minor != 7) return error.UnsupportedGodotVersion;
    if (!std.mem.eql(u8, api.header.precision, "single")) return error.UnsupportedPrecision;

    const profile = try std.json.parseFromSliceLeaky(Value, allocator, profile_source, .{});
    const roots = optionalArrayField(&profile, "roots") orelse return error.MissingRoots;
    var bindings = try resolveBindings(allocator, &api, roots);
    return renderResolvedTree(allocator, &bindings);
}

fn renderResolvedTree(allocator: std.mem.Allocator, bindings: *ResolvedBindings) ![]GeneratedFile {
    const class_count = bindings.generated_names.items.len;
    var class_indexes = std.StringHashMap(usize).init(allocator);
    for (bindings.generated_names.items, 0..) |name, index| try class_indexes.put(name, index);

    const reachability = try allocator.alloc(bool, class_count * class_count);
    @memset(reachability, false);
    for (0..class_count) |index| reachability[index * class_count + index] = true;
    for (bindings.generated_names.items, 0..) |class_name, source_index| {
        if (!bindings.shell_set.contains(class_name)) {
            var chain = try bindings.api.inheritanceChain(allocator, class_name);
            defer chain.deinit(allocator);
            for (chain.items[0 .. chain.items.len - 1]) |ancestor| {
                if (class_indexes.get(ancestor.name)) |target_index| reachability[source_index * class_count + target_index] = true;
            }
            for (bindings.methods_by_class.get(class_name).?.items) |method| {
                for (method.arguments) |*argument| addTypeEdge(argument.typeRef(), source_index, class_count, &class_indexes, reachability);
                if (method.return_value) |*return_value| addTypeEdge(return_value.typeRef(), source_index, class_count, &class_indexes, reachability);
            }
        }
    }
    const dependencies = try allocator.dupe(bool, reachability);
    for (0..class_count) |via| {
        for (0..class_count) |source| {
            if (!reachability[source * class_count + via]) continue;
            for (0..class_count) |target| {
                if (reachability[via * class_count + target]) reachability[source * class_count + target] = true;
            }
        }
    }

    const assigned = try allocator.alloc(bool, class_count);
    @memset(assigned, false);
    var components: std.ArrayList(ClassComponent) = .empty;
    var class_components = std.StringHashMap(usize).init(allocator);
    for (0..class_count) |source| {
        if (assigned[source]) continue;
        var members: std.ArrayList([]const u8) = .empty;
        for (source..class_count) |target| {
            if (!assigned[target] and reachability[source * class_count + target] and reachability[target * class_count + source]) {
                assigned[target] = true;
                try members.append(allocator, bindings.generated_names.items[target]);
            }
        }
        std.mem.sort([]const u8, members.items, {}, lessThanString);
        const component_index = components.items.len;
        const path = try componentPath(allocator, members.items);
        for (members.items) |name| try class_components.put(name, component_index);
        try components.append(allocator, .{ .members = members, .path = path });
    }

    var files: std.ArrayList(GeneratedFile) = .empty;
    try files.append(allocator, .{
        .path = "generated_classes/.generated-bindings",
        .contents = "Generated by tools/generate_bindings.zig. Do not edit.\n",
    });
    try files.append(allocator, .{
        .path = "generated_classes/global_enums.zig",
        .contents = try renderGlobalEnums(allocator, bindings),
    });
    for (components.items, 0..) |*component, component_index| {
        try files.append(allocator, .{
            .path = component.path,
            .contents = try renderClassComponent(allocator, bindings, component, component_index, components.items, &class_components, dependencies, class_count, &class_indexes),
        });
    }
    try files.append(allocator, .{
        .path = "generated_classes/index.zig",
        .contents = try renderGeneratedIndex(allocator, bindings, components.items, &class_components),
    });
    try files.append(allocator, .{
        .path = "class.zig",
        .contents = try renderClassFacade(allocator, bindings),
    });
    std.mem.sort(GeneratedFile, files.items, {}, generatedFileLessThan);

    var manifest = std.Io.Writer.Allocating.init(allocator);
    for (files.items) |file| {
        if (!std.mem.startsWith(u8, file.path, "generated_classes/") or std.mem.eql(u8, file.path, "generated_classes/.generated-bindings")) continue;
        try manifest.writer.print("{s}\n", .{file.path["generated_classes/".len..]});
    }
    try files.append(allocator, .{
        .path = "generated_classes/manifest.txt",
        .contents = try allocator.dupe(u8, manifest.writer.buffered()),
    });
    std.mem.sort(GeneratedFile, files.items, {}, generatedFileLessThan);
    return files.toOwnedSlice(allocator);
}

fn addTypeEdge(type_ref: extension_api.TypeRef, source_index: usize, class_count: usize, class_indexes: *const std.StringHashMap(usize), reachability: []bool) void {
    const dependency = if (enumReference(type_ref.name)) |reference| reference.owner else type_ref.name;
    if (dependency) |name| {
        if (class_indexes.get(name)) |target_index| reachability[source_index * class_count + target_index] = true;
    }
}

fn componentPath(allocator: std.mem.Allocator, members: []const []const u8) ![]const u8 {
    if (members.len == 1) return std.fmt.allocPrint(allocator, "generated_classes/classes/{s}.zig", .{try fileStem(allocator, members[0])});
    var name = std.Io.Writer.Allocating.init(allocator);
    for (members, 0..) |member, index| {
        if (index != 0) try name.writer.writeAll("__");
        try name.writer.writeAll(try fileStem(allocator, member));
    }
    return std.fmt.allocPrint(allocator, "generated_classes/cycles/{s}.zig", .{name.writer.buffered()});
}

fn fileStem(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (name, 0..) |character, index| {
        const previous = if (index == 0) null else name[index - 1];
        const next = if (index + 1 == name.len) null else name[index + 1];
        const word_start = index != 0 and ((std.ascii.isUpper(character) and ((previous != null and std.ascii.isLower(previous.?)) or (previous != null and std.ascii.isUpper(previous.?) and next != null and std.ascii.isLower(next.?)))) or (std.ascii.isDigit(character) and previous != null and std.ascii.isAlphabetic(previous.?) and (next == null or std.ascii.isUpper(next.?))));
        if (word_start) try result.append(allocator, '_');
        try result.append(allocator, std.ascii.toLower(character));
    }
    return result.toOwnedSlice(allocator);
}

fn renderGlobalEnums(allocator: std.mem.Allocator, bindings: *const ResolvedBindings) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll("// Generated by tools/generate_bindings.zig. Do not edit.\n\n");
    for (bindings.global_enums.items, 0..) |entry, index| {
        try renderEnum(&output.writer, allocator, entry, "");
        if (index + 1 != bindings.global_enums.items.len) try output.writer.writeByte('\n');
    }
    return allocator.dupe(u8, output.writer.buffered());
}

fn renderClassComponent(
    allocator: std.mem.Allocator,
    bindings: *ResolvedBindings,
    component: *const ClassComponent,
    component_index: usize,
    components: []const ClassComponent,
    class_components: *const std.StringHashMap(usize),
    dependencies: []const bool,
    class_count: usize,
    class_indexes: *const std.StringHashMap(usize),
) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    const writer = &output.writer;
    try writer.writeAll("// Generated by tools/generate_bindings.zig. Do not edit.\n");
    if (componentUsesAbi(bindings, component)) try writer.writeAll("const abi = @import(\"../../abi.zig\");\n");
    try writer.writeAll("const support = @import(\"../../class_support.zig\");\n");
    for (bindings.global_enums.items) |entry| {
        if (componentUsesGlobalEnum(bindings, component, entry.name))
            try writer.print("const {s} = @import(\"../global_enums.zig\").{s};\n", .{ entry.name, entry.name });
    }

    var imported = StringSet.init(allocator);
    for (component.members.items) |source_name| {
        const source_index = class_indexes.get(source_name).?;
        for (bindings.generated_names.items, 0..) |target_name, target_index| {
            const target_component = class_components.get(target_name).?;
            if (target_component == component_index or imported.contains(target_name) or !dependencies[source_index * class_count + target_index]) continue;
            try imported.put(target_name, {});
            try writer.print("const {s} = @import(\"{s}\").{s};\n", .{ target_name, try relativeComponentPath(allocator, component.path, components[target_component].path), target_name });
        }
    }
    try writer.writeByte('\n');
    for (component.members.items, 0..) |class_name, index| {
        try renderResolvedClass(writer, allocator, bindings, class_name);
        if (index + 1 != component.members.items.len) try writer.writeByte('\n');
    }
    return allocator.dupe(u8, output.writer.buffered());
}

fn componentUsesAbi(bindings: *const ResolvedBindings, component: *const ClassComponent) bool {
    for (component.members.items) |class_name| {
        const methods = bindings.methods_by_class.get(class_name) orelse continue;
        for (methods.items) |method| {
            for (method.arguments) |argument| {
                const type_name = argument.type;
                if (std.mem.eql(u8, type_name, "Vector2") or std.mem.eql(u8, type_name, "Vector3") or
                    std.mem.eql(u8, type_name, "Color") or std.mem.eql(u8, type_name, "Transform2D") or
                    std.mem.eql(u8, type_name, "Transform3D") or std.mem.eql(u8, type_name, "Rect2")) return true;
            }
            if (method.return_value) |value| {
                const type_name = value.type;
                if (std.mem.eql(u8, type_name, "Vector2") or std.mem.eql(u8, type_name, "Vector3") or
                    std.mem.eql(u8, type_name, "Color") or std.mem.eql(u8, type_name, "Transform2D") or
                    std.mem.eql(u8, type_name, "Transform3D") or std.mem.eql(u8, type_name, "Rect2")) return true;
            }
        }
    }
    return false;
}

fn componentUsesGlobalEnum(bindings: *const ResolvedBindings, component: *const ClassComponent, enum_name: []const u8) bool {
    for (component.members.items) |class_name| {
        const methods = bindings.methods_by_class.get(class_name) orelse continue;
        for (methods.items) |method| {
            for (method.arguments) |argument| if (typeUsesGlobalEnum(argument.type, enum_name)) return true;
            if (method.return_value) |value| if (typeUsesGlobalEnum(value.type, enum_name)) return true;
        }
    }
    return false;
}

fn typeUsesGlobalEnum(type_name: []const u8, enum_name: []const u8) bool {
    const reference = enumReference(type_name) orelse return false;
    return reference.owner == null and std.mem.eql(u8, reference.name, enum_name);
}

fn relativeComponentPath(allocator: std.mem.Allocator, source: []const u8, target: []const u8) ![]const u8 {
    const source_is_class = std.mem.indexOf(u8, source, "/classes/") != null;
    const target_is_class = std.mem.indexOf(u8, target, "/classes/") != null;
    const basename = std.fs.path.basename(target);
    if (source_is_class == target_is_class) return allocator.dupe(u8, basename);
    return std.fmt.allocPrint(allocator, "../{s}/{s}", .{ if (target_is_class) "classes" else "cycles", basename });
}

fn renderResolvedClass(writer: *std.Io.Writer, allocator: std.mem.Allocator, bindings: *ResolvedBindings, class_name: []const u8) !void {
    try writer.print(
        \\pub const {s} = extern struct {{
        \\    owner: u64,
        \\
        \\    pub const godot_class = "{s}";
        \\    pub const emitSignal = support.emitSignal;
    , .{ class_name, class_name });
    try writer.writeByte('\n');
    if (bindings.class_enums.get(class_name)) |entries| {
        for (entries.items) |entry| {
            try writer.writeByte('\n');
            try renderEnum(writer, allocator, entry, "    ");
        }
    }
    if (!bindings.shell_set.contains(class_name)) {
        var chain = try bindings.api.inheritanceChain(allocator, class_name);
        defer chain.deinit(allocator);
        for (chain.items[0 .. chain.items.len - 1]) |ancestor| {
            if (!bindings.root_set.contains(ancestor.name)) continue;
            try writer.print("\n    pub fn as{s}(self: @This()) {s} {{ return .{{ .owner = self.owner }}; }}\n", .{ ancestor.name, ancestor.name });
        }
        const methods = bindings.methods_by_class.get(class_name).?;
        for (methods.items) |method| {
            const declaring = try bindings.api.findDeclaringClass(allocator, method, class_name);
            if (!std.mem.eql(u8, declaring, class_name)) continue;
            try writer.writeByte('\n');
            try renderMethod(writer, allocator, method, class_name, &bindings.generated_set, &bindings.enum_types);
        }
        for (methods.items) |method| {
            const declaring = try bindings.api.findDeclaringClass(allocator, method, class_name);
            if (std.mem.eql(u8, declaring, class_name)) continue;
            try writer.writeByte('\n');
            try renderForwardedMethod(writer, allocator, method, declaring, &bindings.generated_set, &bindings.enum_types);
        }
    }
    try writer.writeAll("};\n");
}

fn renderGeneratedIndex(allocator: std.mem.Allocator, bindings: *const ResolvedBindings, components: []const ClassComponent, class_components: *const std.StringHashMap(usize)) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll("// Generated by tools/generate_bindings.zig. Do not edit.\n\n");
    for (bindings.global_enums.items) |entry| try output.writer.print("pub const {s} = @import(\"global_enums.zig\").{s};\n", .{ entry.name, entry.name });
    if (bindings.global_enums.items.len != 0) try output.writer.writeByte('\n');
    for (bindings.generated_names.items) |class_name| {
        const path = components[class_components.get(class_name).?].path["generated_classes/".len..];
        try output.writer.print("pub const {s} = @import(\"{s}\").{s};\n", .{ class_name, path, class_name });
    }
    return allocator.dupe(u8, output.writer.buffered());
}

fn renderClassFacade(allocator: std.mem.Allocator, bindings: *const ResolvedBindings) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    try output.writer.writeAll(
        \\// Generated by tools/generate_bindings.zig. Do not edit.
        \\const generated = @import("generated_classes/index.zig");
        \\
        \\pub const Vector = @import("abi.zig").Vector;
        \\pub const Color = @import("abi.zig").Color;
        \\pub const Transform2D = @import("abi.zig").Transform2D;
        \\pub const Transform3D = @import("abi.zig").Transform3D;
        \\pub const Rect2 = @import("abi.zig").Rect2;
        \\
    );
    for (bindings.global_enums.items) |entry| try output.writer.print("pub const {s} = generated.{s};\n", .{ entry.name, entry.name });
    try output.writer.writeByte('\n');
    for (bindings.generated_names.items) |class_name| try output.writer.print("pub const {s} = generated.{s};\n", .{ class_name, class_name });
    return allocator.dupe(u8, output.writer.buffered());
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn generatedFileLessThan(_: void, lhs: GeneratedFile, rhs: GeneratedFile) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

fn automaticMethods(allocator: std.mem.Allocator, api: *const extension_api.ExtensionApi, class_name: []const u8, roots: *const StringSet) !std.ArrayList(*const extension_api.Method) {
    var result: std.ArrayList(*const extension_api.Method) = .empty;
    var selected = std.StringHashMap(usize).init(allocator);
    var chain = try api.inheritanceChain(allocator, class_name);
    defer chain.deinit(allocator);
    for (chain.items) |class_entry| {
        if (!roots.contains(class_entry.name)) continue;
        for (class_entry.methods) |*method| {
            if (!methodSupported(api, method)) continue;
            if (selected.get(method.name)) |index| result.items[index] = method else {
                try selected.put(method.name, result.items.len);
                try result.append(allocator, method);
            }
        }
    }
    return result;
}

fn methodSupported(api: *const extension_api.ExtensionApi, method: *const extension_api.Method) bool {
    if (method.is_virtual or method.is_static or method.is_vararg) return false;
    for (method.arguments) |*argument| {
        if (!typeSupported(api, argument.typeRef(), false)) return false;
    }
    if (method.return_value) |*return_value| {
        if (!typeSupported(api, return_value.typeRef(), true)) return false;
    }
    return true;
}

fn typeSupported(api: *const extension_api.ExtensionApi, type_ref: extension_api.TypeRef, returning: bool) bool {
    const name = type_ref.name;
    if (std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float") or
        std.mem.eql(u8, name, "Vector2") or std.mem.eql(u8, name, "Vector3") or std.mem.eql(u8, name, "Color") or
        std.mem.eql(u8, name, "Transform2D") or std.mem.eql(u8, name, "Transform3D") or std.mem.eql(u8, name, "Rect2")) return true;
    if (!returning and (std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "StringName") or std.mem.eql(u8, name, "NodePath"))) return true;
    if (enumReference(name)) |reference| {
        if (reference.owner) |owner| {
            const class_entry = api.class(owner) orelse return false;
            return class_entry.apiEnum(reference.name) != null;
        }
        return api.globalEnum(reference.name) != null;
    }
    return api.class(name) != null;
}

const EnumReference = struct { owner: ?[]const u8, name: []const u8 };

fn enumReference(type_name: []const u8) ?EnumReference {
    const prefix = if (std.mem.startsWith(u8, type_name, "enum::")) "enum::" else if (std.mem.startsWith(u8, type_name, "bitfield::")) "bitfield::" else return null;
    const qualified = type_name[prefix.len..];
    if (std.mem.indexOfScalar(u8, qualified, '.')) |separator| return .{
        .owner = qualified[0..separator],
        .name = qualified[separator + 1 ..],
    };
    return .{ .owner = null, .name = qualified };
}

fn collectTypeDependencies(
    allocator: std.mem.Allocator,
    api: *const extension_api.ExtensionApi,
    type_ref: extension_api.TypeRef,
    generated_names: *std.ArrayList([]const u8),
    generated_set: *StringSet,
    shell_set: *StringSet,
    enum_types: *TypeMap,
    global_enums: *std.ArrayList(*const extension_api.ApiEnum),
    global_enum_set: *StringSet,
    class_enums: *std.StringHashMap(std.ArrayList(*const extension_api.ApiEnum)),
    class_enum_set: *StringSet,
) !void {
    if (enumReference(type_ref.name)) |reference| {
        if (reference.owner) |owner| {
            const class_entry = api.class(owner) orelse return error.EnumOwnerNotGenerated;
            const entry = class_entry.apiEnum(reference.name) orelse return error.EnumNotFound;
            try addShell(allocator, owner, generated_names, generated_set, shell_set);
            const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ owner, reference.name });
            if (!class_enum_set.contains(key)) {
                try class_enum_set.put(key, {});
                const result = try class_enums.getOrPut(owner);
                if (!result.found_existing) result.value_ptr.* = .empty;
                try result.value_ptr.append(allocator, entry);
            }
            try enum_types.put(type_ref.name, key);
        } else {
            const entry = api.globalEnum(reference.name) orelse return error.EnumNotFound;
            if (!global_enum_set.contains(reference.name)) {
                try global_enum_set.put(reference.name, {});
                try global_enums.append(allocator, entry);
            }
            try enum_types.put(type_ref.name, reference.name);
        }
        return;
    }
    if (api.class(type_ref.name) != null) try addShell(allocator, type_ref.name, generated_names, generated_set, shell_set);
}

fn addShell(allocator: std.mem.Allocator, name: []const u8, generated_names: *std.ArrayList([]const u8), generated_set: *StringSet, shell_set: *StringSet) !void {
    if (generated_set.contains(name)) return;
    try generated_set.put(name, {});
    try shell_set.put(name, {});
    try generated_names.append(allocator, name);
}

fn renderEnum(writer: *std.Io.Writer, allocator: std.mem.Allocator, entry: *const extension_api.ApiEnum, indent: []const u8) !void {
    const enum_name = entry.name;
    const enum_id = try identifier(allocator, enum_name);
    var values = std.AutoHashMap(i64, []const u8).init(allocator);
    var aliases: std.ArrayList(struct { []const u8, []const u8 }) = .empty;

    try writer.print("{s}pub const {s} = enum(i64) {{\n", .{ indent, enum_id });
    for (entry.values) |value| {
        const number = value.value;
        const clean_name = try cleanEnumFieldName(allocator, value.name, enum_name);
        if (values.get(number)) |canonical| {
            try aliases.append(allocator, .{ clean_name, canonical });
        } else {
            try values.put(number, clean_name);
            const field_id = try identifier(allocator, clean_name);
            try writer.print("{s}    {s} = {d},\n", .{ indent, field_id, number });
        }
    }
    if (entry.is_bitfield) try writer.print("{s}    _,\n", .{indent});
    for (aliases.items) |alias| {
        const alias_id = try identifier(allocator, alias[0]);
        const canonical_id = try identifier(allocator, alias[1]);
        try writer.print("{s}    pub const {s}: @This() = .{s};\n", .{ indent, alias_id, canonical_id });
    }
    try writer.print("{s}}};\n", .{indent});
}

fn renderMethod(writer: *std.Io.Writer, allocator: std.mem.Allocator, method: *const extension_api.Method, class_name: []const u8, generated_classes: *const StringSet, enum_types: *const TypeMap) !void {
    if (method.is_virtual or method.is_static or method.is_vararg)
        return error.UnsupportedMethodKind;
    const name = method.name;
    const method_id = try identifier(allocator, try camelCase(allocator, name));
    try writer.print("    pub fn {s}(self: @This()", .{method_id});

    var arguments: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    for (method.arguments) |*argument| {
        const argument_name = try identifier(allocator, argument.name);
        const argument_type = try zigType(allocator, argument.type, false, generated_classes, enum_types, argument.meta);
        try arguments.append(allocator, .{ argument_name, argument_type orelse return error.UnsupportedArgumentType });
        try writer.print(", {s}: {s}", .{ argument_name, argument_type.? });
    }
    const return_type = try methodReturnType(allocator, method, generated_classes, enum_types);
    try writer.print(") !{s} {{ return ", .{return_type orelse "void"});
    const ptrcall = try methodUsesPtrcall(allocator, method, class_name, generated_classes, enum_types);
    if (return_type != null) {
        if (ptrcall) {
            try writer.print("support.ptrcallMethod(self, {s}, \"{s}\", \"{s}\", {d}, ", .{ return_type.?, class_name, name, method.hash });
        } else {
            try writer.print("support.call(self, {s}, \"{s}\", ", .{ return_type.?, name });
        }
    } else if (ptrcall) {
        try writer.print("support.ptrcallMethodVoid(self, \"{s}\", \"{s}\", {d}, ", .{ class_name, name, method.hash });
    } else {
        try writer.print("support.callVoid(self, \"{s}\", ", .{name});
    }
    try renderTuple(writer, arguments.items);
    try writer.writeAll("); }\n");
}

fn renderForwardedMethod(writer: *std.Io.Writer, allocator: std.mem.Allocator, method: *const extension_api.Method, declaring_class: []const u8, generated_classes: *const StringSet, enum_types: *const TypeMap) !void {
    const name = method.name;
    const method_id = try identifier(allocator, try camelCase(allocator, name));
    try writer.print("    pub inline fn {s}(self: @This()", .{method_id});
    var arguments: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    for (method.arguments) |*argument| {
        const argument_name = try identifier(allocator, argument.name);
        const argument_type = (try zigType(allocator, argument.type, false, generated_classes, enum_types, argument.meta)) orelse return error.UnsupportedArgumentType;
        try arguments.append(allocator, .{ argument_name, argument_type });
        try writer.print(", {s}: {s}", .{ argument_name, argument_type });
    }
    const return_type = try methodReturnType(allocator, method, generated_classes, enum_types);
    try writer.print(") !{s} {{ return self.as{s}().{s}(", .{ return_type orelse "void", declaring_class, method_id });
    for (arguments.items, 0..) |argument, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(argument[0]);
    }
    try writer.writeAll("); }\n");
}

fn renderTuple(writer: *std.Io.Writer, arguments: []const struct { []const u8, []const u8 }) !void {
    if (arguments.len > 1) try writer.writeAll(".{ ") else try writer.writeAll(".{");
    for (arguments, 0..) |argument, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(argument[0]);
    }
    if (arguments.len > 1) try writer.writeAll(" }") else try writer.writeAll("}");
}

fn methodUsesPtrcall(allocator: std.mem.Allocator, method: *const extension_api.Method, class_name: []const u8, generated_classes: *const StringSet, enum_types: *const TypeMap) !bool {
    if (class_name.len == 0 or method.hash == 0) return false;
    if (method.return_value) |*return_value| {
        if (!typeUsesPtrcall(return_value.typeRef(), generated_classes)) return false;
    }
    const return_type = try methodReturnType(allocator, method, generated_classes, enum_types);
    if (!isPtrcallSafe(return_type)) return false;
    for (method.arguments) |*argument| {
        if (!typeUsesPtrcall(argument.typeRef(), generated_classes)) return false;
        const argument_type = try zigType(allocator, argument.type, false, generated_classes, enum_types, argument.meta);
        if (!isPtrcallSafe(argument_type)) return false;
    }
    return true;
}

fn typeUsesPtrcall(type_ref: extension_api.TypeRef, generated_classes: *const StringSet) bool {
    if (generated_classes.contains(type_ref.name)) return false;
    const meta = type_ref.meta orelse return true;
    if (std.mem.eql(u8, type_ref.name, "int")) return std.mem.eql(u8, meta, "int64");
    if (std.mem.eql(u8, type_ref.name, "float")) return std.mem.eql(u8, meta, "double");
    return true;
}

fn methodReturnType(allocator: std.mem.Allocator, method: *const extension_api.Method, generated_classes: *const StringSet, enum_types: *const TypeMap) !?[]const u8 {
    const return_value = if (method.return_value) |*value| value else return null;
    return (try zigType(allocator, return_value.type, true, generated_classes, enum_types, return_value.meta)) orelse error.UnsupportedReturnType;
}

fn zigType(allocator: std.mem.Allocator, type_name: []const u8, returning: bool, generated_classes: *const StringSet, enum_types: *const TypeMap, meta: ?[]const u8) !?[]const u8 {
    if (std.mem.eql(u8, type_name, "bool")) return "bool";
    if (std.mem.eql(u8, type_name, "int")) return "i64";
    if (std.mem.eql(u8, type_name, "float")) return "f64";
    if (std.mem.eql(u8, type_name, "Vector2")) return "abi.Vector(2, f64)";
    if (std.mem.eql(u8, type_name, "Vector3")) return "abi.Vector(3, f64)";
    if (std.mem.eql(u8, type_name, "Color")) return "abi.Color";
    if (std.mem.eql(u8, type_name, "Transform2D")) return "abi.Transform2D";
    if (std.mem.eql(u8, type_name, "Transform3D")) return "abi.Transform3D";
    if (std.mem.eql(u8, type_name, "Rect2")) return "abi.Rect2";
    if (!returning and (std.mem.eql(u8, type_name, "String") or std.mem.eql(u8, type_name, "StringName") or std.mem.eql(u8, type_name, "NodePath"))) return "[]const u8";
    if (std.mem.startsWith(u8, type_name, "enum::") or std.mem.startsWith(u8, type_name, "bitfield::")) return enum_types.get(type_name);
    if (generated_classes.contains(type_name)) {
        if (meta != null and std.mem.eql(u8, meta.?, "required")) return type_name;
        const optional_type: []const u8 = try std.fmt.allocPrint(allocator, "?{s}", .{type_name});
        return optional_type;
    }
    return null;
}

fn cleanEnumFieldName(allocator: std.mem.Allocator, field_name: []const u8, enum_name: []const u8) ![]const u8 {
    const upper_field = try std.ascii.allocUpperString(allocator, field_name);
    const snake_enum = try camelToSnake(allocator, enum_name);
    const upper_enum = try std.ascii.allocUpperString(allocator, snake_enum);
    var prefixes: std.ArrayList([]const u8) = .empty;
    if (std.mem.indexOf(u8, upper_field, "PRESET_MODE_") == 0) try prefixes.append(allocator, "PRESET_MODE_");
    if (std.mem.indexOf(u8, upper_field, "PRESET_") == 0) try prefixes.append(allocator, "PRESET_");
    try prefixes.append(allocator, try std.fmt.allocPrint(allocator, "{s}_", .{upper_enum}));
    const suffixes = [_][]const u8{ "Mode", "Flags", "Direction", "Preset", "Order", "Filter", "Repeat" };
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, enum_name, suffix) and enum_name.len > suffix.len) {
            const base_snake = try camelToSnake(allocator, enum_name[0 .. enum_name.len - suffix.len]);
            const upper_base = try std.ascii.allocUpperString(allocator, base_snake);
            try prefixes.append(allocator, try std.fmt.allocPrint(allocator, "{s}_", .{upper_base}));
            if (std.mem.eql(u8, suffix, "Flags")) {
                const singular = try camelToSnake(allocator, enum_name[0 .. enum_name.len - 1]);
                try prefixes.append(allocator, try std.fmt.allocPrint(allocator, "{s}_", .{try std.ascii.allocUpperString(allocator, singular)}));
            } else if (std.mem.eql(u8, suffix, "Filter") or std.mem.eql(u8, suffix, "Repeat") or std.mem.eql(u8, suffix, "Preset")) {
                try prefixes.append(allocator, try std.fmt.allocPrint(allocator, "{s}_", .{try std.ascii.allocUpperString(allocator, suffix)}));
            }
        }
    }
    for (prefixes.items) |prefix| {
        if (std.mem.startsWith(u8, upper_field, prefix) and field_name.len > prefix.len)
            return std.ascii.allocLowerString(allocator, field_name[prefix.len..]);
    }
    return std.ascii.allocLowerString(allocator, field_name);
}

fn camelToSnake(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    for (name, 0..) |character, index| {
        if (std.ascii.isUpper(character) and index > 0 and (std.ascii.isLower(name[index - 1]) or (index + 1 < name.len and std.ascii.isLower(name[index + 1]))))
            try result.append(allocator, '_');
        try result.append(allocator, std.ascii.toLower(character));
    }
    return result.toOwnedSlice(allocator);
}

fn isPtrcallSafe(type_name: ?[]const u8) bool {
    const name = type_name orelse return true;
    if (std.mem.indexOf(u8, name, "Array") != null or std.mem.indexOf(u8, name, "Dictionary") != null) return false;
    return std.mem.indexOf(u8, name, "[]") == null and std.mem.indexOfScalar(u8, name, '?') == null;
}

fn objectField(value: *const Value, name: []const u8) !*const Value {
    return switch (value.*) {
        .object => |*object| object.getPtr(name) orelse error.MissingField,
        else => error.ExpectedObject,
    };
}
fn arrayField(value: *const Value, name: []const u8) !*const std.json.Array {
    return arrayValue(try objectField(value, name));
}
fn optionalArrayField(value: *const Value, name: []const u8) ?*const std.json.Array {
    return arrayField(value, name) catch null;
}
fn arrayValue(value: *const Value) !*const std.json.Array {
    return switch (value.*) {
        .array => |*array| array,
        else => error.ExpectedArray,
    };
}
fn stringValue(value: *const Value) ![]const u8 {
    return switch (value.*) {
        .string => |string| string,
        else => error.ExpectedString,
    };
}
