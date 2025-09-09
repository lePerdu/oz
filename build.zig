const std = @import("std");

fn includeCpuQuery(base: *const std.Target.Query, query: std.Target.Query) std.Target.Query {
    var t = query;
    t.cpu_arch = base.cpu_arch;
    t.cpu_model = base.cpu_model;
    t.cpu_features_add = base.cpu_features_add;
    t.cpu_features_sub = base.cpu_features_sub;
    return t;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // b.enable_qemu = true;

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    // TODO: Use stripped down version of this to get j
    const base_query = b.standardTargetOptionsQueryOnly(.{
        .whitelist = &[_]std.Target.Query{.{ .cpu_arch = .x86_64 }},
        .default_target = .{ .cpu_arch = .x86_64 },
    });

    const uefi_target = b.resolveTargetQuery(includeCpuQuery(&base_query, .{
        .os_tag = .uefi,
    }));

    const kernel_target = b.resolveTargetQuery(includeCpuQuery(&base_query, .{
        // TODO: what's the difference between freestanding and other?
        .os_tag = .freestanding,
        .abi = .none,
        // Output as ELF then use ObjectCopy, since the .raw format isn't supported
        // in the linked yet
        // .ofmt = .elf,
    }));

    // Tests need to be run on the current platform
    // TODO: Figure out how to run tests for non-current platform
    const test_target = b.resolveTargetQuery(base_query);

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = std.builtin.OptimizeMode.Debug; // b.standardOptimizeOption(.{});

    // We will also create a module for our other entry point, 'main.zig'.
    const loader_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/loader/main.zig"),
        .target = uefi_target,
        .optimize = optimize,
    });

    const uefi_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = uefi_target,
        .optimize = optimize,
    });
    loader_mod.addImport("ozlib", uefi_lib_mod);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const loader_exe = b.addExecutable(.{
        .name = "ozloader",
        .root_module = loader_mod,
    });
    // At least 128KiB per UEFI spec
    loader_exe.stack_size = 128 * 1024;

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(loader_exe);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .single_threaded = true,
        .red_zone = false,
        .stack_check = true,
    });
    kernel_mod.addAssemblyFile(b.path("src/kernel/bootstrap.s"));

    // const zigimg_dependency = b.dependency("zigimg", .{
    //     .target = kernel_target,
    //     .optimize = optimize,
    // });
    // kernel_mod.addImport("zigimg", zigimg_dependency.module("zigimg"));

    // The lib module has to be compiled separately for the kernel since it uses
    // a different OS and ABI
    const kernel_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .stack_check = true,
    });
    kernel_mod.addImport("ozlib", kernel_lib_mod);

    const kernel_object = b.addExecutable(.{
        .name = "ozkernel",
        .root_module = kernel_mod,
        // TODO: See if the linker script can be updated for use with zig's native/debug backend
        .use_llvm = true,
    });
    // 1 page setup by boot loader
    kernel_object.stack_size = 4096;
    kernel_object.setLinkerScript(b.path("src/kernel/kernel.ld"));

    const objcopy_step = std.Build.Step.Run.create(b, "run objcopy");
    objcopy_step.addArg("objcopy");
    objcopy_step.addArg("-O");
    objcopy_step.addArg("binary");
    objcopy_step.addFileArg(kernel_object.getEmittedBin());
    objcopy_step.addArg(b.getInstallPath(.bin, "ozkernel"));
    b.getInstallStep().dependOn(&objcopy_step.step);

    // TODO: Figure out/report broken objcopy when using Zig's version
    // const kernel_exe_objcopy = b.addObjCopy(kernel_object.getEmittedBin(), .{
    //     .format = .bin,
    // });
    // const kernel_exe_artifact = b.addInstallBinFile(kernel_exe_objcopy.getOutput(), "ozkernel");
    // b.getInstallStep().dependOn(&kernel_exe_artifact.step);

    // TODO: Is there a way to just add debug info, without the full code?
    b.getInstallStep().dependOn(&b.addInstallBinFile(kernel_object.getEmittedBin(), "ozkernel.debug.elf").step);

    // Step to check without emitting a binary for in-editor diagnostics
    const loader_check = b.addExecutable(.{
        .name = "check-ozloader",
        .root_module = loader_mod,
    });
    const loader_lib_check = b.addLibrary(.{
        .name = "check-ozloader-lib",
        .root_module = uefi_lib_mod,
    });

    const kernel_check = b.addExecutable(.{
        .name = "check-ozkernel",
        .root_module = kernel_mod,
        // Without this, the LSP has errors because it can't handle interrupt callconv
        .use_llvm = true,
    });
    const kernel_lib_check = b.addLibrary(.{
        .name = "check-ozloader-lib",
        .root_module = kernel_lib_mod,
    });

    const check_step = b.step("check", "Check if the project compiles");
    check_step.dependOn(&loader_check.step);
    check_step.dependOn(&loader_lib_check.step);
    check_step.dependOn(&kernel_check.step);
    check_step.dependOn(&kernel_lib_check.step);

    const run_cmd = std.Build.Step.Run.create(b, "run");
    run_cmd.addArg("uefi-run");
    run_cmd.addArtifactArg(loader_exe);
    run_cmd.addArg("--add-file");
    // TODO: There has to be a cleaner way to do this
    // run_cmd.addArg(b.getInstallPath(.{ .bin = {} }, kernel_exe_artifact.dest_rel_path));
    run_cmd.addArg(b.getInstallPath(.{ .bin = {} }, "ozkernel"));
    run_cmd.addArgs(&[_][]const u8{ "--", "-debugcon", "stdio" });

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const debug_cmd = std.Build.Step.Run.create(b, "debug");
    debug_cmd.addArg("uefi-run");
    debug_cmd.addArtifactArg(loader_exe);
    debug_cmd.addArg("--add-file");
    // TODO: There has to be a cleaner way to do this
    // debug_cmd.addArg(b.getInstallPath(.{ .bin = {} }, kernel_exe_artifact.dest_rel_path));
    debug_cmd.addArg(b.getInstallPath(.{ .bin = {} }, "ozkernel"));
    debug_cmd.addArgs(&[_][]const u8{ "--", "-debugcon", "stdio", "-s", "-S" });
    if (b.args) |args| {
        debug_cmd.addArgs(args);
    }

    debug_cmd.step.dependOn(b.getInstallStep());

    const debug_step = b.step("debug", "Run the app in debug mode");
    debug_step.dependOn(&debug_cmd.step);

    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = test_target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{ .root_module = lib_test_mod });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // TODO: Figure out how to run tests for different platform
    // const loader_unit_tests = b.addTest(.{
    //     .root_module = loader_mod,
    // });
    // const run_loader_unit_tests = b.addRunArtifact(loader_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_lib_unit_tests.step);
}
