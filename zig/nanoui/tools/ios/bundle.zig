//! iOS app bundles from build.zig: an executable and its Info.plist in a
//! `Name.app` folder, which the Simulator installs as is and a device
//! installs once signed. nanoui's build.zig bundles its examples with it,
//! and exports it for apps (`@import("nanoui").ios.app(b, exe, .{...})`).
const std = @import("std");

pub const Options = struct {
    /// The name under the icon ("Gallery").
    name: []const u8,
    /// The bundle identifier ("dev.nanoui.gallery"): yours, reverse DNS.
    id: []const u8,
    version: []const u8 = "1.0",
    /// Files the Files app shows (the app's Documents).
    file_sharing: bool = false,
};

/// The folder `<name>.app` holding `exe` and an Info.plist made for its
/// target (the Simulator's or a device's), as a path in the cache.
pub fn app(b: *std.Build, exe: *std.Build.Step.Compile, opts: Options) std.Build.LazyPath {
    const target = exe.root_module.resolved_target.?.result;
    if (target.abi != .simulator) linkDeviceSdk(b, exe, target);
    const dir = b.fmt("{s}.app", .{opts.name});
    const wf = b.addWriteFiles();
    _ = wf.add(b.fmt("{s}/Info.plist", .{dir}), infoPlist(b, exe.name, target, opts));
    _ = wf.addCopyFile(stripped(b, exe), b.fmt("{s}/{s}", .{ dir, exe.name }));
    return wf.getDirectory().path(b, dir);
}

/// A release's executable without its local symbols (about a tenth of
/// it), which Zig's linker keeps however it is asked; a debug build's as
/// it is. Xcode's strip: any iOS build has Xcode for the SDK.
fn stripped(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    if (exe.root_module.optimize.? == .debug) return exe.getEmittedBin();
    const strip = b.addSystemCommand(&.{ "xcrun", "strip", "-x", "-o" });
    const out = strip.addOutputFileArg(exe.name);
    strip.addArtifactArg(exe);
    return out;
}

/// Zig 0.17.0 has no libc of its own for iOS: without a libc file it links
/// every iOS program against its own libSystem.tbd, which is macOS's. The
/// Simulator gets by (Zig lets it use macOS's symbols); a device finds
/// none. A libc file naming the iPhoneOS SDK links the SDK's libSystem.
/// (Not for the Simulator: Zig can't read its SDK's version.)
fn linkDeviceSdk(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Target) void {
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target) orelse return;
    const libc = b.addWriteFiles().add("libc.txt", b.fmt(
        \\include_dir={0s}/usr/include
        \\sys_include_dir={0s}/usr/include
        \\crt_dir={0s}/usr/lib
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\cc_dir=
        \\darwin_sdk_dir={0s}
        \\
    , .{sdk}));
    exe.setLibCFile(libc);
}

/// A step that installs `bundle` in the booted Simulator and runs it,
/// its output in the terminal (`tools/ios/sim.sh`).
pub fn runInSimulator(b: *std.Build, bundle: std.Build.LazyPath, opts: Options, nanoui_root: std.Build.LazyPath) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(nanoui_root.path(b, "tools/ios/sim.sh"));
    run.addDirectoryArg(bundle);
    run.addArg(opts.id);
    run.has_side_effects = true;
    return run;
}

/// The Info.plist: a full screen app (a launch screen), scenes from code
/// (nanoui's scene delegate), ProMotion's 120 Hz, every orientation.
pub fn infoPlist(b: *std.Build, exe_name: []const u8, target: std.Target, opts: Options) []const u8 {
    const simulator = target.abi == .simulator;
    const min = target.os.version_range.semver.min;
    return b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleDevelopmentRegion</key><string>en</string>
        \\  <key>CFBundleExecutable</key><string>{s}</string>
        \\  <key>CFBundleIdentifier</key><string>{s}</string>
        \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        \\  <key>CFBundleName</key><string>{s}</string>
        \\  <key>CFBundleDisplayName</key><string>{s}</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>{s}</string>
        \\  <key>CFBundleVersion</key><string>{s}</string>
        \\  <key>CFBundleSupportedPlatforms</key><array><string>{s}</string></array>
        \\  <key>LSRequiresIPhoneOS</key><true/>
        \\  <key>MinimumOSVersion</key><string>{d}.{d}</string>
        \\  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
        \\  <key>UILaunchScreen</key><dict/>
        \\  <key>UIApplicationSceneManifest</key>
        \\  <dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
        \\  <key>UIApplicationSupportsIndirectInputEvents</key><true/>
        \\  <key>CADisableMinimumFrameDurationOnPhone</key><true/>
        \\  <key>UIFileSharingEnabled</key><{s}/>
        \\  <key>LSSupportsOpeningDocumentsInPlace</key><{s}/>
        \\  <key>UISupportedInterfaceOrientations</key>
        \\  <array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
        \\  <key>UISupportedInterfaceOrientations~ipad</key>
        \\  <array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
        \\</dict>
        \\</plist>
        \\
    , .{
        exe_name,
        opts.id,
        opts.name,
        opts.name,
        opts.version,
        opts.version,
        if (simulator) "iPhoneSimulator" else "iPhoneOS",
        min.major,
        min.minor,
        if (opts.file_sharing) "true" else "false",
        if (opts.file_sharing) "true" else "false",
    });
}
