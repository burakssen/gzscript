const std = @import("std");
const gd = @import("godot");

pub const Base = gd.Node2D;
const Self = @This();

base: Base,
mode: i64 = 0,

pub const exports = .{
    .mode = gd.property(.{}),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}

pub fn ready(self: *Self) !void {
    _ = self;
}

pub fn process(self: *Self, delta: f64) !void {
    _ = delta;
    if (self.mode == 1) {
        // 1. Particle Physics Benchmark (500 boids x 20 steps = 5,000,000 interactions)
        const particle_count: usize = 500;
        const steps: usize = 20;

        var pos_x: [500]f32 = undefined;
        var pos_y: [500]f32 = undefined;
        var vel_x: [500]f32 = undefined;
        var vel_y: [500]f32 = undefined;

        for (0..particle_count) |idx| {
            const f = @as(f32, @floatFromInt(idx));
            pos_x[idx] = f * 1.5;
            pos_y[idx] = f * 2.5;
            vel_x[idx] = @as(f32, @floatFromInt(idx % 10)) - 5.0;
            vel_y[idx] = @as(f32, @floatFromInt(idx % 7)) - 3.0;
        }

        var total_dist: f32 = 0.0;

        for (0..steps) |_| {
            for (0..particle_count) |i| {
                const px = pos_x[i];
                const py = pos_y[i];
                var fx: f32 = 0.0;
                var fy: f32 = 0.0;

                for (0..particle_count) |j| {
                    if (i == j) continue;
                    const dx = px - pos_x[j];
                    const dy = py - pos_y[j];
                    const dist_sq = dx * dx + dy * dy;
                    if (dist_sq < 10000.0 and dist_sq > 0.0001) {
                        fx += dx / dist_sq;
                        fy += dy / dist_sq;
                    }
                }

                vel_x[i] += fx * 0.1;
                vel_y[i] += fy * 0.1;
                pos_x[i] += vel_x[i];
                pos_y[i] += vel_y[i];

                total_dist += @sqrt(pos_x[i] * pos_x[i] + pos_y[i] * pos_y[i]);
            }
        }

        if (total_dist == 0.0) return error.SimulationError;
        self.mode = 0;
    } else if (self.mode == 2) {
        // 2. Sorting Benchmark (Quicksort 10,000 elements)
        const size: usize = 10000;
        var arr: [10000]i64 = undefined;

        for (0..size) |idx| {
            const i = @as(i64, @intCast(idx));
            arr[idx] = @as(i64, @intCast((i * 1103515245 + 12345) & 0x7FFFFFFF));
        }

        quicksort(&arr, 0, @intCast(size - 1));

        if (arr[0] > arr[size - 1]) return error.SortError;
        self.mode = 0;
    } else if (self.mode == 3) {
        // 3. Engine API Call Overhead (100,000 calls)
        var target_x: f32 = 10.0;
        var target_y: f32 = 20.0;

        var j: u32 = 0;
        while (j < 100000) : (j += 1) {
            try self.base.setPosition(.{ target_x, target_y });
            const p = try self.base.getPosition();
            target_x = @as(f32, @floatCast(p[0] + 0.001));
            target_y = @as(f32, @floatCast(p[1] + 0.001));
        }
        self.mode = 0;
    } else if (self.mode == 4) {
        // 4. Batch Node Updates (2,000 nodes via parent container)
        const node = self.base.asNode();
        const parent = (try node.getParent()) orelse return error.MissingParent;
        const child_count = try parent.getChildCount(false);

        var c: i32 = 0;
        while (c < child_count) : (c += 1) {
            const child_node = (try parent.getChild(c, false)) orelse continue;
            const node2d = gd.Node2D{ .owner = child_node.owner };
            const fc = @as(f32, @floatFromInt(c));
            try node2d.setPosition(.{ fc * 1.5, fc * 2.5 });
            try node2d.setRotation(fc * 0.01);
            try node2d.asCanvasItem().setVisible(@rem(c, 2) == 0);
        }

        self.mode = 0;
    }
}

fn quicksort(arr: []i64, low: isize, high: isize) void {
    if (low < high) {
        const pivot = arr[@intCast(high)];
        var i = low - 1;
        var j = low;
        while (j < high) : (j += 1) {
            if (arr[@intCast(j)] <= pivot) {
                i += 1;
                const tmp = arr[@intCast(i)];
                arr[@intCast(i)] = arr[@intCast(j)];
                arr[@intCast(j)] = tmp;
            }
        }
        const tmp2 = arr[@intCast(i + 1)];
        arr[@intCast(i + 1)] = arr[@intCast(high)];
        arr[@intCast(high)] = tmp2;
        const p = i + 1;
        quicksort(arr, low, p - 1);
        quicksort(arr, p + 1, high);
    }
}
