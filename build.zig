const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.15.2")) {
        @panic("KasirKu requires Zig 0.15.2. Use tools/zig.ps1 after tools/setup.ps1.");
    }
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    if (target.result.os.tag != .windows or target.result.cpu.arch != .x86_64) @panic("KasirKu supports Windows x64 only.");
    const optimize = b.standardOptimizeOption(.{});
    const app_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    addSqlite(b, app_module);
    app_module.addIncludePath(b.path("vendor/webview2/build/native/include"));
    app_module.addCSourceFile(.{ .file = b.path("src/infra/webview/host.cpp"), .flags = &.{ "-std=c++17", "-fms-extensions", "-fno-exceptions", "-fno-rtti", "-DUNICODE", "-D_UNICODE", "-D_WIN32_WINNT=0x0A00" } });
    for ([_][]const u8{ "user32", "ole32", "shell32", "shlwapi", "gdi32", "advapi32", "uuid", "winspool", "ws2_32" }) |library| app_module.linkSystemLibrary(library, .{});
    const exe = b.addExecutable(.{ .name = "KasirKu", .root_module = app_module });
    exe.subsystem = .Windows;
    b.installArtifact(exe);
    b.installFile("vendor/webview2/build/native/x64/WebView2Loader.dll", "bin/WebView2Loader.dll");
    b.installDirectory(.{ .source_dir = b.path("ui"), .install_dir = .bin, .install_subdir = "ui" });
    b.installFile("vendor/webview2/LICENSE.txt", "bin/licenses/WebView2.txt");
    b.installFile("vendor/webview2/NOTICE.txt", "bin/licenses/WebView2-NOTICE.txt");

    const tests_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = .Debug, .link_libc = true });
    addSqlite(b, tests_module);
    for ([_][]const u8{ "winspool", "ws2_32" }) |library| tests_module.linkSystemLibrary(library, .{});
    const golden_options = b.addOptions();
    golden_options.addOptionPath("dir", b.path("testdata/receipt"));
    tests_module.addImport("golden_options", golden_options.createModule());
    const tests = b.addTest(.{ .root_module = tests_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run domain, database and bridge tests").dependOn(&run_tests.step);

    const golden_module = b.createModule(.{ .root_source_file = b.path("src/domain/receipt_golden_gen.zig"), .target = target, .optimize = .Debug, .link_libc = true });
    const gen_options = b.addOptions();
    gen_options.addOptionPath("dir", b.path("testdata/receipt"));
    golden_module.addImport("golden_options", gen_options.createModule());
    const golden_exe = b.addExecutable(.{ .name = "receipt-golden", .root_module = golden_module });
    const run_golden = b.addRunArtifact(golden_exe);
    run_golden.addDirectoryArg(b.path("testdata/receipt"));
    b.step("golden", "Regenerate receipt ESC/POS golden reference bytes").dependOn(&run_golden.step);

    const run = b.addSystemCommand(&.{b.getInstallPath(.bin, "KasirKu.exe")});
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run KasirKu desktop").dependOn(&run.step);
    const smoke = b.addSystemCommand(&.{ b.getInstallPath(.bin, "KasirKu.exe"), "--smoke-test" });
    smoke.step.dependOn(b.getInstallStep());
    b.step("smoke", "Verify a real WebView2 to Zig round trip in an isolated profile").dependOn(&smoke.step);
}

fn addSqlite(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{ "-std=c99", "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_FOREIGN_KEYS=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_ENABLE_API_ARMOR" } });
}
