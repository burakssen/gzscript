// SPDX-License-Identifier: MIT

const std = @import("std");

const Value = std.json.Value;
const bindings_archive = @embedFile("bindings_4_7_single_64.tar");

pub const godot_cpp_revision = "ba0edfed90512ec64aba51d4295a3e7e30112f86";
const extension_api_sha256 = "53d37f85be32b6d10fb2266ca51f6ef0c3a55728acdb7c8301b1458a93c00943";
const gdextension_interface_sha256 = "7d8c0a039d9743eb8ebf88681ae0c641d8d3aa5ffca11081745a84da803e09a1";
const bindings_archive_sha256 = "3c34b25c128f465869b405f907ea5de211c8d06c116f67f4b743128db9261694";

pub fn validateApi(allocator: std.mem.Allocator, source: []const u8) !void {
    var parsed = try std.json.parseFromSlice(Value, allocator, source, .{});
    defer parsed.deinit();
    const header = switch (parsed.value) {
        .object => |object| object.get("header") orelse return error.MissingHeader,
        else => return error.InvalidApi,
    };
    const object = switch (header) {
        .object => |value| value,
        else => return error.InvalidHeader,
    };
    const major = switch (object.get("version_major") orelse return error.InvalidHeader) {
        .integer => |value| value,
        else => return error.InvalidHeader,
    };
    const minor = switch (object.get("version_minor") orelse return error.InvalidHeader) {
        .integer => |value| value,
        else => return error.InvalidHeader,
    };
    const precision = switch (object.get("precision") orelse return error.InvalidHeader) {
        .string => |value| value,
        else => return error.InvalidHeader,
    };
    if (major != 4 or minor != 7) return error.UnsupportedGodotVersion;
    if (!std.mem.eql(u8, precision, "single")) return error.UnsupportedPrecision;
}

pub fn validatePinnedInputs(api_source: []const u8, interface_source: []const u8) !void {
    if (!hashMatches(api_source, extension_api_sha256)) return error.UnexpectedApiMetadata;
    if (!hashMatches(interface_source, gdextension_interface_sha256)) return error.UnexpectedInterfaceMetadata;
    if (!hashMatches(bindings_archive, bindings_archive_sha256)) return error.CorruptBindingsSnapshot;
}

fn hashMatches(source: []const u8, expected: *const [64:0]u8) bool {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &actual, expected);
}

pub fn extractSnapshot(io: std.Io, dir: std.Io.Dir, output_path: []const u8) !void {
    try dir.createDirPath(io, output_path);
    var output = try dir.openDir(io, output_path, .{});
    defer output.close(io);
    var reader: std.Io.Reader = .fixed(bindings_archive);
    try std.tar.extract(io, output, &reader, .{
        .mode_mode = .ignore,
        .exclude_empty_directories = true,
    });
}

pub fn generateTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    output_path: []const u8,
    api_source: []const u8,
    interface_source: []const u8,
) !void {
    try validateApi(allocator, api_source);
    if (!try std.json.validate(allocator, interface_source)) return error.InvalidInterface;
    try validatePinnedInputs(api_source, interface_source);
    try extractSnapshot(io, dir, output_path);
}
