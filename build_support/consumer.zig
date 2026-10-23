// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.MissingBuildArguments;

    // The build graph resolves these directories only at make time.
    try init.environ_map.put("ZIG_LIB_DIR", args[1]);
    try init.environ_map.put("ZIG_GLOBAL_CACHE_DIR", args[2]);
    var child = try std.process.spawn(init.io, .{
        .argv = args[3..],
        .environ_map = init.environ_map,
    });
    switch (try child.wait(init.io)) {
        .exited => |status| std.process.exit(status),
        else => return error.ConsumerTerminated,
    }
}
