const std = @import("std");

const pt_dynamic = 2;
const dt_null = 0;
const dt_flags_1 = 0x6ffffffb;
const df_1_nodelete = 0x8;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;

    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, args[1], allocator, .unlimited);
    if (input.len < 64 or !std.mem.eql(u8, input[0..4], "\x7fELF") or input[4] != 2 or input[5] != 1) {
        return error.UnsupportedElf;
    }

    const bytes = try allocator.dupe(u8, input);
    const program_offset = try toUsize(readU64(bytes, 32));
    const program_entry_size = readU16(bytes, 54);
    const program_count = readU16(bytes, 56);
    if (program_entry_size < 56) return error.InvalidElf;

    for (0..program_count) |program_index| {
        const header_offset = try add(program_offset, try multiply(program_index, program_entry_size));
        try require(bytes, header_offset, program_entry_size);
        if (readU32(bytes, header_offset) != pt_dynamic) continue;

        const dynamic_offset = try toUsize(readU64(bytes, header_offset + 8));
        const dynamic_size = try toUsize(readU64(bytes, header_offset + 32));
        try require(bytes, dynamic_offset, dynamic_size);

        var offset = dynamic_offset;
        const end = try add(dynamic_offset, dynamic_size);
        while (offset + 16 <= end) : (offset += 16) {
            const tag = readU64(bytes, offset);
            if (tag == dt_null) break;
            if (tag == dt_flags_1) {
                writeU64(bytes, offset + 8, readU64(bytes, offset + 8) | df_1_nodelete);
                try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = bytes });
                return;
            }
        }
        return error.MissingFlags1;
    }
    return error.MissingDynamicSegment;
}

fn require(bytes: []const u8, offset: usize, size: usize) !void {
    if (offset > bytes.len or size > bytes.len - offset) return error.InvalidElf;
}

fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.InvalidElf;
}

fn multiply(a: usize, b: anytype) !usize {
    return std.math.mul(usize, a, @as(usize, b)) catch error.InvalidElf;
}

fn toUsize(value: u64) !usize {
    return std.math.cast(usize, value) orelse error.InvalidElf;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | @as(u16, bytes[offset + 1]) << 8;
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, readU16(bytes, offset)) | @as(u32, readU16(bytes, offset + 2)) << 16;
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, readU32(bytes, offset)) | @as(u64, readU32(bytes, offset + 4)) << 32;
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    for (0..8) |index| bytes[offset + index] = @truncate(value >> @intCast(index * 8));
}
