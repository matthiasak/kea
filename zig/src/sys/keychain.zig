//! Generic passwords in the keychain (`SecItem*` over a `CFDictionary`), as
//! AIKeys (AI.swift) and Sync.swift keep theirs. Callers keep tests away
//! from here: nothing in this file knows about test runs.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const CFType = *const anyopaque;
const CFDict = *anyopaque;

extern "c" const kSecClass: CFType;
extern "c" const kSecClassGenericPassword: CFType;
extern "c" const kSecAttrService: CFType;
extern "c" const kSecAttrAccount: CFType;
extern "c" const kSecAttrLabel: CFType;
extern "c" const kSecAttrComment: CFType;
extern "c" const kSecAttrAccessible: CFType;
extern "c" const kSecAttrAccessibleWhenUnlocked: CFType;
extern "c" const kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFType;
extern "c" const kSecAttrSynchronizable: CFType;
extern "c" const kSecUseDataProtectionKeychain: CFType;
extern "c" const kSecValueData: CFType;
extern "c" const kSecReturnData: CFType;
extern "c" const kSecReturnAttributes: CFType;
extern "c" const kSecMatchLimit: CFType;
extern "c" const kSecMatchLimitOne: CFType;
extern "c" const kCFBooleanTrue: CFType;
extern "c" const kCFBooleanFalse: CFType;
extern "c" var kCFTypeDictionaryKeyCallBacks: opaque {};
extern "c" var kCFTypeDictionaryValueCallBacks: opaque {};

extern "c" fn CFDictionaryCreate(alloc: ?*anyopaque, keys: [*]const CFType, values: [*]const CFType, n: isize, key_cb: *anyopaque, value_cb: *anyopaque) ?CFDict;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: CFType) ?CFType;
extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: isize) ?*anyopaque;
extern "c" fn CFDataGetBytePtr(data: *anyopaque) [*]const u8;
extern "c" fn CFDataGetLength(data: *anyopaque) isize;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" fn SecItemAdd(attributes: CFDict, result: ?*?*anyopaque) i32;
extern "c" fn SecItemCopyMatching(query: CFDict, result: ?*?*anyopaque) i32;
extern "c" fn SecItemUpdate(query: CFDict, changes: CFDict) i32;
extern "c" fn SecItemDelete(query: CFDict) i32;

pub const success: i32 = 0;
pub const missing_entitlement: i32 = -34018;

/// Which item: by service, and by account when given. `protected` asks for
/// the data protection keychain (`kSecUseDataProtectionKeychain`).
pub const Query = struct {
    service: []const u8,
    account: ?[]const u8 = null,
    protected: bool = false,
};

pub const Accessible = enum { when_unlocked, when_unlocked_this_device_only };

/// What goes with a new item besides its data; `.{}` is a bare add.
pub const Extra = struct {
    label: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    accessible: ?Accessible = null,
    synchronizable: ?bool = null,
};

/// At most this many pairs in one dictionary.
const most = 12;

const Pairs = struct {
    keys: [most]CFType = undefined,
    values: [most]CFType = undefined,
    n: usize = 0,

    fn put(p: *Pairs, k: CFType, v: CFType) void {
        p.keys[p.n] = k;
        p.values[p.n] = v;
        p.n += 1;
    }

    fn of(q: Query) Pairs {
        var p: Pairs = .{};
        p.put(kSecClass, kSecClassGenericPassword);
        p.put(kSecAttrService, str(q.service));
        if (q.account) |a| p.put(kSecAttrAccount, str(a));
        if (q.protected) p.put(kSecUseDataProtectionKeychain, kCFBooleanTrue);
        return p;
    }

    /// The caller releases it.
    fn dict(p: *const Pairs) ?CFDict {
        return CFDictionaryCreate(null, &p.keys, &p.values, @intCast(p.n), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
};

/// An autoreleased NSString, toll-free a CFString; call inside a pool.
fn str(s: []const u8) CFType {
    return @ptrCast(objc.nsString(s));
}

fn boolean(b: bool) CFType {
    return if (b) kCFBooleanTrue else kCFBooleanFalse;
}

/// The item's data, or null; the caller frees it.
pub fn load(gpa: std.mem.Allocator, q: Query) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var p = Pairs.of(q);
    p.put(kSecReturnData, kCFBooleanTrue);
    p.put(kSecMatchLimit, kSecMatchLimitOne);
    const d = p.dict() orelse return null;
    defer CFRelease(d);
    var found: ?*anyopaque = null;
    if (SecItemCopyMatching(d, &found) != success) return null;
    const data = found orelse return null;
    defer CFRelease(data);
    const len: usize = @intCast(CFDataGetLength(data));
    return gpa.dupe(u8, CFDataGetBytePtr(data)[0..len]) catch null;
}

/// `SecItemAdd`: whether it was kept. An item already there stays; delete it first.
pub fn save(q: Query, data: []const u8, extra: Extra) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    var p = Pairs.of(q);
    const bytes = CFDataCreate(null, data.ptr, @intCast(data.len)) orelse return false;
    defer CFRelease(bytes);
    p.put(kSecValueData, bytes);
    if (extra.accessible) |a| p.put(kSecAttrAccessible, switch (a) {
        .when_unlocked => kSecAttrAccessibleWhenUnlocked,
        .when_unlocked_this_device_only => kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    });
    if (extra.synchronizable) |s| p.put(kSecAttrSynchronizable, boolean(s));
    if (extra.label) |l| p.put(kSecAttrLabel, str(l));
    if (extra.comment) |c| p.put(kSecAttrComment, str(c));
    const d = p.dict() orelse return false;
    defer CFRelease(d);
    return SecItemAdd(d, null) == success;
}

/// `SecItemUpdate`: the item's data replaced; whether it was there to change.
pub fn update(q: Query, data: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const p = Pairs.of(q);
    const d = p.dict() orelse return false;
    defer CFRelease(d);
    const bytes = CFDataCreate(null, data.ptr, @intCast(data.len)) orelse return false;
    defer CFRelease(bytes);
    var change: Pairs = .{};
    change.put(kSecValueData, bytes);
    const c = change.dict() orelse return false;
    defer CFRelease(c);
    return SecItemUpdate(d, c) == success;
}

/// Every item the query names, gone (no account: the whole service).
pub fn delete(q: Query) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const p = Pairs.of(q);
    const d = p.dict() orelse return;
    defer CFRelease(d);
    _ = SecItemDelete(d);
}

/// The item's comment without reading its data: "" when it has none, null
/// when there is no item. The caller frees it.
pub fn comment(gpa: std.mem.Allocator, q: Query) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var p = Pairs.of(q);
    p.put(kSecReturnAttributes, kCFBooleanTrue);
    const d = p.dict() orelse return null;
    defer CFRelease(d);
    var found: ?*anyopaque = null;
    if (SecItemCopyMatching(d, &found) != success) return null;
    const attrs = found orelse return null;
    defer CFRelease(attrs);
    const text = CFDictionaryGetValue(attrs, kSecAttrComment) orelse return gpa.dupe(u8, "") catch null;
    const ns: objc.Object = @ptrCast(@constCast(text));
    if (!objc.msg(objc.BOOL, ns, "isKindOfClass:", .{objc.class("NSString")})) return gpa.dupe(u8, "") catch null;
    return gpa.dupe(u8, objc.fromNSString(ns)) catch null;
}

/// Whether this copy may use the data protection keychain: a probe that
/// isn't refused for a missing entitlement (AIKeys.protected).
pub fn protectedAllowed(service: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    var p = Pairs.of(.{ .service = service, .account = "probe", .protected = true });
    p.put(kSecReturnAttributes, kCFBooleanTrue);
    const d = p.dict() orelse return false;
    defer CFRelease(d);
    var found: ?*anyopaque = null;
    const status = SecItemCopyMatching(d, &found);
    if (found) |f| CFRelease(f);
    return status != missing_entitlement;
}

test "keychain compiles; never called in tests" {
    std.testing.refAllDecls(@This());
}
