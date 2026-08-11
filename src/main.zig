const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());

    // Skip process
    _ = args.next();

    const input = args.next() orelse return error.InvalidInput;
    const output = args.next() orelse return error.InvalidInput;

    var cwd = std.Io.Dir.cwd();
    const in_content = try cwd.readFileAlloc(init.io, input, init.arena.allocator(), .unlimited);

    const replacement =
        \\pub const struct_timespec = extern struct {
        \\    tv_sec: c_long,
        \\    tv_nsec: c_long,
        \\};
        \\
    ;

    var fixed: std.ArrayList(u8) = .empty;
    defer fixed.deinit(init.arena.allocator());
    try fixed.ensureUnusedCapacity(init.arena.allocator(), in_content.len);

    // Only patch if timespec was not created
    if (std.mem.indexOf(u8, in_content, "pub const struct_timespec = opaque {};") != null) {
        var iter = std.mem.splitSequence(u8, in_content, "pub const struct_timespec = opaque {};");
        if (iter.next()) |before| try fixed.appendSlice(init.arena.allocator(), before);
        try fixed.appendSlice(init.arena.allocator(), replacement);
        if (iter.next()) |after| try fixed.appendSlice(init.arena.allocator(), after);
    } else {
        try fixed.appendSlice(init.arena.allocator(), in_content);
    }

    try cwd.writeFile(init.io, .{
        .sub_path = output,
        .data = fixed.items,
    });
}
