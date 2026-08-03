const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(
        b,
        b.dependency("native_sdk", .{}),
        .{ .name = "meeting-notes", .app_root = "." },
    );

    const objc_flags: []const []const u8 = if (b.sysroot) |sysroot| &.{
        "-fobjc-arc",
        "-fno-sanitize=builtin",
        "-ObjC",
        "-mmacosx-version-min=11.0",
        "-isysroot",
        sysroot,
        b.fmt("-I{s}/usr/include", .{sysroot}),
        b.fmt("-F{s}/System/Library/Frameworks", .{sysroot}),
    } else &.{
        "-fobjc-arc",
        "-fno-sanitize=builtin",
        "-ObjC",
        "-mmacosx-version-min=11.0",
    };
    artifacts.exe.root_module.addCSourceFile(.{
        .file = b.path("native/MeetingNotesKeychain.m"),
        .flags = objc_flags,
    });
    if (artifacts.tests.root_module != artifacts.exe.root_module) {
        artifacts.tests.root_module.addCSourceFile(.{
            .file = b.path("native/MeetingNotesKeychain.m"),
            .flags = objc_flags,
        });
    }
    inline for (.{ artifacts.exe.root_module, artifacts.tests.root_module }) |module| {
        if (b.sysroot) |sysroot| {
            module.addFrameworkPath(.{
                .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }),
            });
        }
        module.linkFramework("Foundation", .{});
        module.linkFramework("Security", .{});
    }
}
