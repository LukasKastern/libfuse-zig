const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const libfuse = b.dependency("fuse", .{});

    // An abstraction to make using translate-c as simple as possible.
    const Translator = @import("translate_c").Translator;

    const translator = b.dependency("translate_c", .{
        .target = target,
        .optimize = optimize,
    });

    // Add translator
    const translate_c: Translator = .init(translator, .{
        .c_source_file = libfuse.path("include/fuse_lowlevel.h"),
        .target = target,
        .optimize = optimize,
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
    translate_c.addIncludePath(libfuse_config.getOutputFile().dirname());
    translate_c.addIncludePath(libfuse.path("include"));

    const patch_step = try b.allocator.create(PatchStep);
    patch_step.step = .init(.{
        .name = "Patch-Timespec",
        .owner = b,
        .makeFn = PatchStep.make,
        .id = .custom,
    });

    patch_step.step.dependOn(&translate_c.run.step);
    patch_step.fuse_file = translate_c.output_file;
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

        const content = file_path.root_dir.handle.readFileAlloc(b.graph.io, file_path.sub_path, b.allocator, .unlimited) catch |e| {
            std.debug.print("Failed to read file {}", .{e});
            return e;
        };

        var man = b.graph.cache.obtain();
        defer man.deinit();
        man.hash.add(@as(u32, 0xdef08d30));
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
        self.output_file.path = b.cache_root.join(b.allocator, &.{
            "o", &digest, "patched",
        }) catch |e| {
            std.debug.print("Faield to join file {}", .{e});
            return e;
        };

        const sub_path = b.pathJoin(&.{ "o", &digest, "patched" });
        const sub_path_dirname = std.fs.path.dirname(sub_path).?;
        b.cache_root.handle.createDirPath(b.graph.io, sub_path_dirname) catch |err| {
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

        var fixed: std.ArrayList(u8) = .empty;
        defer fixed.deinit(b.allocator);
        try fixed.ensureUnusedCapacity(b.allocator, content.len);

        // Only patch if timespec was not created
        if (std.mem.indexOf(u8, content, "pub const struct_timespec = opaque {};") != null) {
            var iter = std.mem.splitSequence(u8, content, "pub const struct_timespec = opaque {};");
            if (iter.next()) |before| try fixed.appendSlice(b.allocator, before);
            try fixed.appendSlice(b.allocator, replacement);
            if (iter.next()) |after| try fixed.appendSlice(b.allocator, after);

            // Write the fixed file
            b.cache_root.handle.writeFile(b.graph.io, .{ .sub_path = sub_path, .data = fixed.items }) catch |err| {
                return step.fail("unable to write file '{}{s}': {s}", .{
                    b.cache_root, sub_path, @errorName(err),
                });
            };
        } else {
            // Write the fixed file
            b.cache_root.handle.writeFile(b.graph.io, .{ .sub_path = sub_path, .data = content }) catch |err| {
                return step.fail("unable to write file '{}{s}': {s}", .{
                    b.cache_root, sub_path, @errorName(err),
                });
            };
        }

        man.writeManifest() catch |e| {
            std.debug.print("Faield to write manifest {}", .{e});
            return e;
        };
    }

    pub fn getOutput(step: *PatchStep) std.Build.LazyPath {
        return .{ .generated = .{ .file = &step.output_file } };
    }
};
