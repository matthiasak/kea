//! A `.menu` `Picker` (SwiftUI's is an `NSPopUpButton`): the system's own
//! control, drawn by AppKit into a picture per title, appearance, scale and
//! press, and kept — so it is the pop-up button macOS draws, in either
//! appearance, not a look-alike. Pressed, it says where its menu goes.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const objc = nanoui.objc;
const Palette = @import("../design/palette.zig").Palette;

const Picture = struct { bytes: []u8, w: f32, h: f32 };

/// Pictures by hash, for the life of the app (main thread).
// ponytail: never evicted; a few titles (engines, providers, models) × 2 appearances × 2 presses.
var pictures: std.AutoHashMapUnmanaged(u64, Picture) = .empty;

/// The pop-up button showing `title`, named `label` for VoiceOver; where
/// its menu goes (just under it) when clicked.
pub fn popUpButton(c: *ui.Context, p: *const Palette, label: []const u8, title: []const u8) ?ui.Point {
    const i = c.open(.{ .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .menu_button, label, title, false, true);
    const held = it.pressed and c.input.down;
    if (picture(title, c.theme.dark, c.scale, held)) |pic| {
        const key = c.print("kea.popup.{x}", .{hash(title, c.theme.dark, c.scale, held)});
        _ = ui.image(c, .{ .key = key, .bytes = pic.bytes, .max_width = pic.w, .max_height = pic.h, .radius = 0, .scale = c.scale });
    } else {
        // No AppKit to draw it (never in practice): the title alone.
        ui.text(c, title, .{ .size = 13, .color = p.ink });
    }
    if (!it.clicked) return null;
    const r = it.rect orelse return null;
    return .{ .x = r.x, .y = r.y + r.h + 4 };
}

fn hash(title: []const u8, dark: bool, scale: f32, held: bool) u64 {
    var h = std.hash.Wyhash.init(0x706f_7075);
    h.update(title);
    inline for (.{ @as(u8, @intFromBool(dark)), scale, @as(u8, @intFromBool(held)) }) |v| h.update(std.mem.asBytes(&v));
    return h.final();
}

fn picture(title: []const u8, dark: bool, scale: f32, held: bool) ?Picture {
    const k = hash(title, dark, scale, held);
    if (pictures.get(k)) |pic| return pic;
    const pic = draw(title, dark, scale, held) orelse return null;
    pictures.put(std.heap.c_allocator, k, pic) catch {
        std.heap.c_allocator.free(pic.bytes);
        return null;
    };
    return pic;
}

fn draw(title: []const u8, dark: bool, scale: f32, held: bool) ?Picture {
    const pool = objc.Pool.push();
    defer pool.pop();
    const button = objc.msg(?objc.Object, objc.alloc("NSPopUpButton"), "initWithFrame:pullsDown:", .{ objc.CGRect{}, objc.NO }) orelse return null;
    objc.autorelease(button);
    const name = objc.nsString(if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua");
    objc.msg(void, button, "setAppearance:", .{objc.msg(?objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{name})});
    objc.msg(void, button, "addItemWithTitle:", .{objc.nsString(title)});
    objc.msg(void, button, "sizeToFit", .{});
    if (held) objc.msg(void, objc.msg(objc.Object, button, "cell", .{}), "setHighlighted:", .{objc.YES});
    const size = objc.msg(objc.CGRect, button, "bounds", .{}).size;
    if (size.width <= 0 or size.height <= 0) return null;
    const s: f64 = @floatCast(@max(scale, 1));
    const wide: objc.NSInteger = @intFromFloat(@ceil(size.width * s));
    const high: objc.NSInteger = @intFromFloat(@ceil(size.height * s));
    const rep = objc.msg(?objc.Object, objc.alloc("NSBitmapImageRep"), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null), wide, high, @as(objc.NSInteger, 8), @as(objc.NSInteger, 4), objc.YES, objc.NO, objc.nsString("NSDeviceRGBColorSpace"), @as(objc.NSInteger, 0), @as(objc.NSInteger, 0),
    }) orelse return null;
    objc.autorelease(rep);
    objc.msg(void, rep, "setSize:", .{size});
    objc.msg(void, button, "cacheDisplayInRect:toBitmapImageRep:", .{ objc.CGRect{ .size = size }, rep });
    // NSBitmapImageFileTypePNG
    const data = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) }) orelse return null;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const ptr = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return null;
    const bytes = std.heap.c_allocator.dupe(u8, ptr[0..len]) catch return null;
    return .{ .bytes = bytes, .w = @floatCast(size.width), .h = @floatCast(size.height) };
}

test "the system's pop-up button draws as a picture its own size" {
    const pic = picture("Google", false, 2, false) orelse return error.NotDrawn;
    try std.testing.expect(pic.w > 40 and pic.h >= 16 and pic.h <= 32);
    try std.testing.expectEqualStrings("\x89PNG", pic.bytes[0..4]);
    // Not blank: the title's letters are near-opaque dark pixels.
    try std.testing.expect(inked(pic.bytes) > 20);
    // Another appearance is another picture.
    const dark = picture("Google", true, 2, false) orelse return error.NotDrawn;
    try std.testing.expect(dark.bytes.ptr != pic.bytes.ptr);
}

/// Pixels of `png` at least half opaque.
fn inked(png: []const u8) usize {
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ png.ptr, @as(objc.NSUInteger, png.len) });
    const rep = objc.msg(?objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data}) orelse return 0;
    const w: usize = @intCast(objc.msg(objc.NSInteger, rep, "pixelsWide", .{}));
    const h: usize = @intCast(objc.msg(objc.NSInteger, rep, "pixelsHigh", .{}));
    var n: usize = 0;
    for (0..h) |y| for (0..w) |x| {
        const color = objc.msg(?objc.Object, rep, "colorAtX:y:", .{ @as(objc.NSInteger, @intCast(x)), @as(objc.NSInteger, @intCast(y)) }) orelse continue;
        if (objc.msg(f64, color, "alphaComponent", .{}) > 0.5) n += 1;
    };
    return n;
}
