const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zonde",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zonde: print one scrape to stdout");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    addReleaseMatrix(b);
}

/// `zig build release`: build stripped ReleaseSmall binaries for the Linux
/// target matrix into zig-out/release/, then fail the build if any artifact
/// exceeds the size budget (so a dependency creep can't silently bloat the
/// "tiny binary" promise).
fn addReleaseMatrix(b: *std.Build) void {
    const release_step = b.step("release", "Build stripped ReleaseSmall binaries for all targets into zig-out/release/");

    const targets = [_][]const u8{
        "x86_64-linux-gnu",
        "x86_64-linux-musl",
        "aarch64-linux-gnu",
        "aarch64-linux-musl",
    };

    // Fail if any zonde-* artifact exceeds 2 MiB.
    const size_gate = b.addSystemCommand(&.{ "sh", "-c", size_gate_script, "size-gate" });

    inline for (targets) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            @panic("invalid release target: " ++ triple));
        const rexe = b.addExecutable(.{
            .name = "zonde-" ++ triple,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSmall,
                .strip = true,
            }),
        });
        const inst = b.addInstallArtifact(rexe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        });
        size_gate.step.dependOn(&inst.step);
    }

    size_gate.addArg(b.getInstallPath(.{ .custom = "release" }, ""));
    release_step.dependOn(&size_gate.step);
}

const size_gate_script =
    \\dir="$1"
    \\budget=2097152
    \\fail=0
    \\for f in "$dir"/zonde-*; do
    \\  [ -f "$f" ] || continue
    \\  sz=$(stat -c%s "$f")
    \\  human=$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")
    \\  if [ "$sz" -gt "$budget" ]; then
    \\    echo "  FAIL $(basename "$f") = $human (> 2MiB budget)"
    \\    fail=1
    \\  else
    \\    echo "  ok   $(basename "$f") = $human"
    \\  fi
    \\done
    \\if [ "$fail" != 0 ]; then echo "size budget exceeded"; exit 1; fi
    \\echo "all release artifacts within 2MiB budget"
;
