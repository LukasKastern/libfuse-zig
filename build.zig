const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const libfuse = b.dependency("fuse", .{});

    const translate_c = b.addTranslateC(.{
        .link_libc = true,
        .optimize = optimize,
        .root_source_file = libfuse.path("include/fuse_lowlevel.h"),
        .target = target,
        .use_clang = true,
    });
    translate_c.defineCMacro("FUSE_USE_VERSION", "312");
    translate_c.defineCMacro("_FILE_OFFSET_BITS", "64");

    // Build fuse config
    const libfuse_config = b.addConfigHeader(.{
        .style = .blank,
        .include_path = "libfuse_config.h",
    }, .{
        .FUSE_MAJOR_VERSION = 3,
        .FUSE_MINOR_VERSION = 18,
        .FUSE_HOTFIX_VERSION = 0,
    });
    translate_c.addIncludePath(libfuse_config.getOutput().dirname());
    translate_c.addIncludePath(libfuse.path("include"));

    const patch_step = try b.allocator.create(PatchStep);
    patch_step.step = .init(.{
        .name = "Patch-Timespec",
        .owner = b,
        .makeFn = PatchStep.make,
        .id = .custom,
    });
    patch_step.step.dependOn(&translate_c.step);
    patch_step.fuse_file = translate_c.getOutput();
    patch_step.output_file = .{ .step = &patch_step.step };

    const fuse_module = b.addModule("fuse", .{
        .root_source_file = b.path("src/fuse.zig"),
    });
    fuse_module.addAnonymousImport("fuse_lowlevel", .{
        .root_source_file = patch_step.getOutput(),
    });
}

const PatchStep = struct {
    fuse_file: std.Build.LazyPath,
    step: std.Build.Step,
    output_file: std.Build.GeneratedFile,

    pub fn make(step: *std.Build.Step, make_options: std.Build.Step.MakeOptions) anyerror!void {
        const self: *PatchStep = @fieldParentPtr("step", step);

        _ = make_options;
        const b = step.owner;

        const file_path = self.fuse_file.getPath3(b, step);

        const in_file = try file_path.openFile("", .{ .mode = .read_write });
        defer in_file.close();

        const content = try in_file.readToEndAlloc(b.allocator, 1024 * 1024 * 1024);

        var man = b.graph.cache.obtain();
        defer man.deinit();
        man.hash.add(@as(u32, 0xdef08d29));
        man.hash.addBytes(content);

        if (try step.cacheHit(&man)) {
            // Cant cache this outside cause of side effects yippie
            const digest = man.final();
            self.output_file.path = try b.cache_root.join(b.allocator, &.{
                "o", &digest, "patched",
            });
            return;
        }

        const digest = man.final();
        self.output_file.path = try b.cache_root.join(b.allocator, &.{
            "o", &digest, "patched",
        });

        const sub_path = b.pathJoin(&.{ "o", &digest, "patched" });
        const sub_path_dirname = std.fs.path.dirname(sub_path).?;
        b.cache_root.handle.makePath(sub_path_dirname) catch |err| {
            return step.fail("unable to make path '{}{s}': {s}", .{
                b.cache_root, sub_path_dirname, @errorName(err),
            });
        };

        const replacement =
            \\pub const struct_timespec = extern struct {
            \\    tv_sec: c_long,
            \\    tv_nsec: c_long,
            \\};
            \\
        ;

        var fixed = std.ArrayListUnmanaged(u8){};
        defer fixed.deinit(b.allocator);
        try fixed.ensureUnusedCapacity(b.allocator, content.len);

        // Only patch if timespec was not created
        if (std.mem.indexOf(u8, content, "pub const struct_timespec = opaque {};") != null) {
            var iter = std.mem.splitSequence(u8, content, "pub const struct_timespec = opaque {};");
            if (iter.next()) |before| try fixed.appendSlice(b.allocator, before);
            try fixed.appendSlice(b.allocator, replacement);
            if (iter.next()) |after| try fixed.appendSlice(b.allocator, after);

            // Write the fixed file
            b.cache_root.handle.writeFile(.{ .sub_path = sub_path, .data = fixed.items }) catch |err| {
                return step.fail("unable to write file '{}{s}': {s}", .{
                    b.cache_root, sub_path, @errorName(err),
                });
            };
        } else {
            // Write the fixed file
            b.cache_root.handle.writeFile(.{ .sub_path = sub_path, .data = content }) catch |err| {
                return step.fail("unable to write file '{}{s}': {s}", .{
                    b.cache_root, sub_path, @errorName(err),
                });
            };
        }

        try man.writeManifest();
    }

    pub fn getOutput(step: *PatchStep) std.Build.LazyPath {
        return .{ .generated = .{ .file = &step.output_file } };
    }
};
