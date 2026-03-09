// Copyright 2026 Query.Farm LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
