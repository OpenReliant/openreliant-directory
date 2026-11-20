const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    options.addOption([]const u8, "describe", describe(b));
    module.addOptions("build_options", options);
    const service = b.addExecutable(.{ .name = "openreliant-directory", .root_module = module });
    b.installArtifact(service);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run directory tests").dependOn(&b.addRunArtifact(tests).step);
}

fn describe(b: *std.Build) []const u8 {
    // Git tags, commits and working tree edits can change the version between builds.
    b.graph.poisonCache();
    const root = b.root.toString(b.allocator) catch @panic("out of memory");
    return switch (b.runFallible(&.{ "git", "-C", root, "describe", "--tags", "--match", "v*", "--long", "--dirty", "--abbrev=7" }, .{ .stderr_behavior = .ignore })) {
        .success => |out| std.mem.trimEnd(u8, out, "\n"),
        else => "",
    };
}
