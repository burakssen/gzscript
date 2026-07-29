const std = @import("std");

pub fn build(b: *std.Build) void {
    const godot_cpp_dependency = b.dependency("godot_cpp", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const godot_debug = optimize == .Debug;
    const godot_configuration = if (godot_debug) "template_debug" else "template_release";

    const os = target.result.os.tag;
    const abi = target.result.abi;

    const platform_name = switch (os) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => @panic("gzscript currently supports macOS, Linux, and Windows"),
    };

    const arch_name = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => @panic("gzscript currently supports x86_64 and arm64"),
    };

    const suffix = b.fmt(
        "{s}.{s}.{s}",
        .{
            platform_name,
            godot_configuration,
            arch_name,
        },
    );

    const cxx_flags = getCxxFlags(os);

    const extension_api = godot_cpp_dependency.path(
        "gdextension/extension_api.json",
    );

    const gdextension_interface = godot_cpp_dependency.path(
        "gdextension/gdextension_interface.json",
    );

    const bindings_generator = b.addExecutable(.{
        .name = "generate-bindings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_bindings.zig"),
            .target = b.graph.host,
        }),
    });
    const check_bindings_run = b.addRunArtifact(bindings_generator);
    check_bindings_run.addArg("--check");
    check_bindings_run.addFileArg(extension_api);
    check_bindings_run.addFileArg(b.path("tools/bindings_profile.json"));
    check_bindings_run.addDirectoryArg(b.path("addons/gzscript/zig"));
    const check_bindings = b.step("check-bindings", "Verify checked-in Zig binding tree");
    check_bindings.dependOn(&check_bindings_run.step);

    const update_bindings = b.addRunArtifact(bindings_generator);
    update_bindings.setCwd(b.path("."));
    update_bindings.addFileArg(extension_api);
    update_bindings.addFileArg(b.path("tools/bindings_profile.json"));
    update_bindings.addArg("addons/gzscript/zig");
    const update_bindings_step = b.step("update-bindings", "Update checked-in Zig binding tree");
    update_bindings_step.dependOn(&update_bindings.step);

    const generator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_bindings_test.zig"),
            .target = b.graph.host,
        }),
    });
    const run_generator_tests = b.addRunArtifact(generator_tests);
    const class_support_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("addons/gzscript/zig/class_support_test.zig"),
            .target = b.graph.host,
        }),
    });
    const run_class_support_tests = b.addRunArtifact(class_support_tests);
    const godot_cpp_generator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/godot_cpp_generator/generator_test.zig"),
            .target = b.graph.host,
        }),
    });
    const run_godot_cpp_generator_tests = b.addRunArtifact(godot_cpp_generator_tests);
    const godot_sdk_module = b.createModule(.{
        .root_source_file = b.path("addons/gzscript/zig/godot.zig"),
        .target = b.graph.host,
    });
    const adapter_test_module = b.createModule(.{
        .root_source_file = b.path("tests/zig_adapter_test.zig"),
        .target = b.graph.host,
    });
    adapter_test_module.addImport("godot", godot_sdk_module);
    const adapter_tests = b.addTest(.{ .root_module = adapter_test_module });
    const run_adapter_tests = b.addRunArtifact(adapter_tests);
    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&check_bindings_run.step);
    test_step.dependOn(&run_generator_tests.step);
    test_step.dependOn(&run_class_support_tests.step);
    test_step.dependOn(&run_godot_cpp_generator_tests.step);
    test_step.dependOn(&run_adapter_tests.step);

    // -------------------------------------------------------------------------
    // Generate godot-cpp C++ bindings
    // -------------------------------------------------------------------------

    const godot_cpp_generator = b.addExecutable(.{
        .name = "generate-godot-cpp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/godot_cpp_generator/main.zig"),
            .target = b.graph.host,
        }),
    });
    const generate_godot_cpp = b.addRunArtifact(godot_cpp_generator);
    generate_godot_cpp.addFileArg(extension_api);
    generate_godot_cpp.addFileArg(gdextension_interface);

    const generated_godot_cpp_dir =
        generate_godot_cpp.addOutputDirectoryArg(
            "godot-cpp-generated",
        );

    // -------------------------------------------------------------------------
    // Build godot-cpp as a static library
    // -------------------------------------------------------------------------

    const godot_cpp_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });

    applyGodotConfiguration(
        godot_cpp_module,
        os,
        abi,
        godot_debug,
    );

    godot_cpp_module.addIncludePath(
        godot_cpp_dependency.path("include"),
    );

    godot_cpp_module.addIncludePath(
        generated_godot_cpp_dir.path(b, "gen/include"),
    );

    // This mirrors godot-cpp's own source globs:
    //
    // src/*.cpp
    // src/classes/*.cpp
    // src/core/*.cpp
    // src/variant/*.cpp

    const godot_cpp_source_dirs = [_]std.Build.LazyPath{
        godot_cpp_dependency.path("src"),
        godot_cpp_dependency.path("src/classes"),
        godot_cpp_dependency.path("src/core"),
        godot_cpp_dependency.path("src/variant"),
    };

    for (godot_cpp_source_dirs) |directory| {
        addTopLevelCppSources(
            b,
            godot_cpp_module,
            directory,
            cxx_flags,
        );
    }

    // The generated snapshot combines its source list into one stable
    // translation unit.
    godot_cpp_module.addCSourceFile(.{
        .file = generated_godot_cpp_dir.path(
            b,
            "gen/src/all_generated.cpp",
        ),
        .flags = cxx_flags,
        .language = .cpp,
    });

    const godot_cpp = b.addLibrary(.{
        .name = b.fmt("godot-cpp.{s}", .{suffix}),
        .linkage = .static,
        .root_module = godot_cpp_module,
    });

    // -------------------------------------------------------------------------
    // Build gzscript
    // -------------------------------------------------------------------------

    const gzscript_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });

    applyGodotConfiguration(
        gzscript_module,
        os,
        abi,
        godot_debug,
    );

    gzscript_module.addIncludePath(
        b.path("src"),
    );

    gzscript_module.addIncludePath(
        godot_cpp_dependency.path("include"),
    );

    gzscript_module.addIncludePath(
        generated_godot_cpp_dir.path(b, "gen/include"),
    );

    addTopLevelCppSources(
        b,
        gzscript_module,
        b.path("src"),
        cxx_flags,
    );

    gzscript_module.linkLibrary(godot_cpp);

    // Mirrors godot-cpp's Linux $ORIGIN rpath behavior.
    if (os == .linux) {
        gzscript_module.addRPathSpecial("$ORIGIN");
    }

    const gzscript = b.addLibrary(.{
        // Zig adds its own native platform prefix/suffix. The installation
        // step below renames the result to the exact Godot filename.
        .name = b.fmt("gzscript.{s}", .{suffix}),
        .linkage = .dynamic,
        .root_module = gzscript_module,
    });

    // -------------------------------------------------------------------------
    // Install using the exact names expected by gzscript.gdextension
    // -------------------------------------------------------------------------

    const binary_name = b.fmt(
        "libgzscript.{s}",
        .{suffix},
    );

    const install_path = switch (os) {
        .macos => b.fmt(
            "addons/gzscript/bin/{s}.framework/{s}",
            .{ binary_name, binary_name },
        ),

        .linux => b.fmt(
            "addons/gzscript/bin/{s}.so",
            .{binary_name},
        ),

        .windows => b.fmt(
            "addons/gzscript/bin/{s}.dll",
            .{binary_name},
        ),

        else => unreachable,
    };

    const install_source = if (os == .linux) source: {
        const elf_patcher = b.addExecutable(.{
            .name = "set-elf-nodelete",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/set_elf_nodelete.zig"),
                .target = b.graph.host,
            }),
        });
        const patch_elf = b.addRunArtifact(elf_patcher);
        patch_elf.addFileArg(gzscript.getEmittedBin());
        break :source patch_elf.addOutputFileArg(gzscript.out_filename);
    } else gzscript.getEmittedBin();

    const install_gzscript = b.addInstallFile(install_source, install_path);

    b.getInstallStep().dependOn(
        &install_gzscript.step,
    );
}

fn applyGodotConfiguration(
    module: *std.Build.Module,
    os: std.Target.Os.Tag,
    abi: std.Target.Abi,
    godot_debug: bool,
) void {
    module.addCMacro("GDEXTENSION", "1");
    module.addCMacro("THREADS_ENABLED", "1");

    // godot-cpp defines NDEBUG for normal non-dev builds, including
    // template_debug builds.
    module.addCMacro("NDEBUG", "1");

    if (godot_debug) module.addCMacro("DEBUG_ENABLED", "1");

    switch (os) {
        .macos => {
            module.addCMacro("MACOS_ENABLED", "1");
            module.addCMacro("UNIX_ENABLED", "1");
        },

        .linux => {
            module.addCMacro("LINUX_ENABLED", "1");
            module.addCMacro("UNIX_ENABLED", "1");
        },

        .windows => {
            module.addCMacro("WINDOWS_ENABLED", "1");
            module.addCMacro("NOMINMAX", "1");

            if (abi == .msvc) {
                module.addCMacro("TYPED_METHOD_BIND", "1");
                module.addCMacro("_HAS_EXCEPTIONS", "0");
            }
        },

        else => unreachable,
    }
}

fn getCxxFlags(
    os: std.Target.Os.Tag,
) []const []const u8 {
    return switch (os) {
        .windows => &.{
            "-std=c++17",
            "-fno-exceptions",
            "-Wwrite-strings",
        },

        .linux => &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-c++-static-destructors",
            "-fvisibility=hidden",
            "-Wwrite-strings",
        },

        else => &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fvisibility=hidden",
            "-Wwrite-strings",
        },
    };
}

fn addTopLevelCppSources(
    b: *std.Build,
    module: *std.Build.Module,
    directory: std.Build.LazyPath,
    flags: []const []const u8,
) void {
    const files = collectTopLevelCppFiles(
        b,
        directory,
    );

    module.addCSourceFiles(.{
        .root = directory,
        .files = files,
        .flags = flags,
        .language = .cpp,
    });
}

fn collectTopLevelCppFiles(
    b: *std.Build,
    directory: std.Build.LazyPath,
) []const []const u8 {
    const io = b.graph.io;
    const directory_path = directory.getPath(b);

    var dir = std.Io.Dir.cwd().openDir(
        io,
        directory_path,
        .{ .iterate = true },
    ) catch |err| {
        std.debug.panic(
            "unable to open '{s}': {s}",
            .{ directory_path, @errorName(err) },
        );
    };
    defer dir.close(io);

    var walker = dir.walk(
        b.allocator,
    ) catch @panic("unable to create directory walker");
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;

    while (walker.next(io) catch |err| {
        std.debug.panic(
            "unable to walk '{s}': {s}",
            .{ directory_path, @errorName(err) },
        );
    }) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        if (!std.mem.endsWith(
            u8,
            entry.basename,
            ".cpp",
        )) {
            continue;
        }

        // Only compile sources directly inside this directory.
        if (std.mem.indexOfScalar(
            u8,
            entry.path,
            std.fs.path.sep,
        ) != null) {
            continue;
        }

        const copied_path = b.allocator.dupe(
            u8,
            entry.path,
        ) catch @panic("out of memory");

        files.append(
            b.allocator,
            copied_path,
        ) catch @panic("out of memory");
    }

    std.mem.sortUnstable(
        []const u8,
        files.items,
        {},
        pathLessThan,
    );

    // The build allocator is arena-backed, so this storage remains valid for
    // the lifetime of the build graph.
    return files.items;
}

fn pathLessThan(
    _: void,
    lhs: []const u8,
    rhs: []const u8,
) bool {
    return std.mem.lessThan(
        u8,
        lhs,
        rhs,
    );
}
