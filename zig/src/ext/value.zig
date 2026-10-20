//! What crosses between an extension and the browser: Foundation objects
//! (NSDictionary/NSArray/NSString/NSNumber/NSNull, as WebKit hands a
//! message over) ↔ `std.json.Value`, and WebKit's reply handlers, answered
//! once with a value or an error whose `localizedDescription` the
//! extension's promise rejects with (Swift's `LocalizedError`s).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

extern "c" fn _Block_copy(block: ?*const anyopaque) ?objc.Object;
extern "c" fn _Block_release(block: objc.Object) void;

/// NSJSONReadingFragmentsAllowed / NSJSONWritingFragmentsAllowed.
const fragments: objc.NSUInteger = 4;

/// A Foundation object as JSON, on `gpa` (the caller deinits). Null for nil
/// or anything JSON can't say (NSURL, NSDate, NSData).
pub fn toJson(gpa: std.mem.Allocator, obj: ?objc.Object) ?std.json.Parsed(std.json.Value) {
    const o = obj orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.class("NSJSONSerialization");
    // A bare string or number is valid only wrapped; write it as a fragment.
    const wrapped = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{o});
    if (!objc.msg(objc.BOOL, cls, "isValidJSONObject:", .{wrapped})) return null;
    const d = objc.msg(?objc.Object, cls, "dataWithJSONObject:options:error:", .{ o, fragments, @as(?*anyopaque, null) }) orelse return null;
    return std.json.parseFromSlice(std.json.Value, gpa, bytes(d), .{ .allocate = .alloc_always }) catch null;
}

/// JSON text as a Foundation object, autoreleased (push a Pool around it);
/// null when it doesn't parse.
pub fn fromText(text: []const u8) ?objc.Object {
    const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ text.ptr, text.len });
    return objc.msg(?objc.Object, objc.class("NSJSONSerialization"), "JSONObjectWithData:options:error:", .{ d, fragments, @as(?*anyopaque, null) });
}

/// A JSON value as a Foundation object, autoreleased; `null` → NSNull.
pub fn toObject(v: std.json.Value) ?objc.Object {
    const text = std.json.Stringify.valueAlloc(std.heap.c_allocator, v, .{}) catch return null;
    defer std.heap.c_allocator.free(text);
    return fromText(text);
}

/// Any value `std.json` can write (structs, slices, optionals) as a
/// Foundation object, autoreleased; nil optionals are left out.
pub fn objectOf(value: anytype) ?objc.Object {
    const text = std.json.Stringify.valueAlloc(std.heap.c_allocator, value, .{ .emit_null_optional_fields = false }) catch return null;
    defer std.heap.c_allocator.free(text);
    return fromText(text);
}

pub fn bytes(data: objc.Object) []const u8 {
    const n = objc.msg(objc.NSUInteger, data, "length", .{});
    if (n == 0) return "";
    const p = objc.msg([*]const u8, data, "bytes", .{});
    return p[0..n];
}

/// `NSError` with `why` as its localized description (domain "Kea", code
/// 1), autoreleased.
pub fn nsError(why: []const u8) objc.Object {
    const info = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ objc.nsString(why), objc.nsString("NSLocalizedDescription") });
    return objc.msg(objc.Object, objc.class("NSError"), "errorWithDomain:code:userInfo:", .{ objc.nsString("Kea"), @as(objc.NSInteger, 1), info });
}

/// A WebKit `(id reply, NSError *error)` completion, copied so it can be
/// answered later: exactly once, by `ok` or `fail`.
pub const Reply = struct {
    block: objc.Object,

    pub fn take(handler: *const anyopaque) Reply {
        return .{ .block = _Block_copy(handler).? };
    }

    /// `replyHandler(value, nil)`; `value` may be nil (JS `undefined`).
    pub fn ok(self: Reply, value: ?objc.Object) void {
        defer _Block_release(self.block);
        call(self.block, value, null);
    }

    /// `ok` with a JSON value.
    pub fn json(self: Reply, v: std.json.Value) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.ok(toObject(v));
    }

    /// `replyHandler(nil, error)`: the extension's promise rejects with `why`.
    pub fn fail(self: Reply, why: []const u8) void {
        defer _Block_release(self.block);
        const pool = objc.Pool.push();
        defer pool.pop();
        call(self.block, null, nsError(why));
    }

    fn call(block: objc.Object, a: ?objc.Object, b: ?objc.Object) void {
        const raw: [*]const *const anyopaque = @ptrCast(@alignCast(block));
        const invoke: *const fn (objc.Object, ?objc.Object, ?objc.Object) callconv(.c) void = @ptrCast(@alignCast(raw[2]));
        invoke(block, a, b);
    }
};

/// A WebKit `(NSError *error)` completion (the async `throws` methods that
/// return nothing), copied; answered exactly once.
pub const Done = struct {
    block: objc.Object,

    pub fn take(handler: *const anyopaque) Done {
        return .{ .block = _Block_copy(handler).? };
    }

    pub fn ok(self: Done) void {
        self.finish(null);
    }

    pub fn fail(self: Done, why: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.finish(nsError(why));
    }

    fn finish(self: Done, err: ?objc.Object) void {
        defer _Block_release(self.block);
        const raw: [*]const *const anyopaque = @ptrCast(@alignCast(self.block));
        const invoke: *const fn (objc.Object, ?objc.Object) callconv(.c) void = @ptrCast(@alignCast(raw[2]));
        invoke(self.block, err);
    }
};

test "json round-trips through Foundation" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const o = fromText("{\"a\":[1,\"x\",null,true]}").?;
    const back = toJson(std.testing.allocator, o).?;
    defer back.deinit();
    const arr = back.value.object.get("a").?.array.items;
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
    try std.testing.expectEqualStrings("x", arr[1].string);
    try std.testing.expect(arr[2] == .null);
    const s = toJson(std.testing.allocator, objc.nsString("plain")).?;
    defer s.deinit();
    try std.testing.expectEqualStrings("plain", s.value.string);
}
