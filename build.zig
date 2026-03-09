const std = @import("std");

pub fn build(b: *std.Build) void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target CPU architecture") orelse .x86_64;
    const version = b.option([]const u8, "version", "Build version string") orelse "dev";

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = arch,
            .os_tag = .linux,
            .abi = .none,
        }),
        .optimize = .ReleaseSmall,
        .strip = true,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "vgi-injector",
        .root_module = root_module,
    });
    b.installArtifact(exe);
}
