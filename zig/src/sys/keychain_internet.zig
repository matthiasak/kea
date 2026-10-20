//! Internet passwords in the keychain (`SecItem*`, Vault.swift): items of
//! `kSecClassInternetPassword` tagged with one label, keyed by server and
//! account. Callers keep tests away from here: nothing in this file knows
//! about test runs. Dictionaries are `NSMutableDictionary`, toll-free
//! `CFDictionary`; call everything inside an `objc.Pool`.
const std = @import("std");
const objc = @import("nanoui").objc;

const CFType = objc.Object;

extern "c" const kSecClass: CFType;
extern "c" const kSecClassInternetPassword: CFType;
extern "c" const kSecAttrServer: CFType;
extern "c" const kSecAttrAccount: CFType;
extern "c" const kSecAttrLabel: CFType;
extern "c" const kSecAttrComment: CFType;
extern "c" const kSecAttrProtocol: CFType;
extern "c" const kSecAttrProtocolHTTP: CFType;
extern "c" const kSecAttrProtocolHTTPS: CFType;
extern "c" const kSecAttrAuthenticationType: CFType;
extern "c" const kSecAttrAuthenticationTypeHTMLForm: CFType;
extern "c" const kSecAttrAccessible: CFType;
extern "c" const kSecAttrAccessibleWhenUnlocked: CFType;
extern "c" const kSecValueData: CFType;
extern "c" const kSecReturnData: CFType;
extern "c" const kSecReturnAttributes: CFType;
extern "c" const kSecMatchLimit: CFType;
extern "c" const kSecMatchLimitOne: CFType;
extern "c" const kSecMatchLimitAll: CFType;
extern "c" const kCFBooleanTrue: CFType;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" fn SecItemAdd(attributes: CFType, result: ?*?*anyopaque) i32;
extern "c" fn SecItemCopyMatching(query: CFType, result: ?*?*anyopaque) i32;
extern "c" fn SecItemUpdate(query: CFType, changes: CFType) i32;
extern "c" fn SecItemDelete(query: CFType) i32;

pub const success: i32 = 0;
pub const item_not_found: i32 = -25300;

/// One item's attributes, borrowed from the keychain's answer (valid until
/// the pool pops).
pub const Row = struct {
    /// Null for an item with no server: not one of a site's.
    server: ?[]const u8,
    /// An item kept under no name has no account at all, not an empty one.
    account: []const u8,
    comment: ?[]const u8,
    /// Kept with `kSecAttrProtocolHTTP`.
    clear: bool,
};

fn dict() objc.Object {
    return objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
}

fn put(d: objc.Object, key: CFType, value: CFType) void {
    objc.msg(void, d, "setObject:forKey:", .{ value, key });
}

fn str(s: []const u8) CFType {
    return objc.nsString(s);
}

fn ours(label: []const u8) objc.Object {
    const d = dict();
    put(d, kSecClass, kSecClassInternetPassword);
    put(d, kSecAttrLabel, str(label));
    return d;
}

fn text(attrs: objc.Object, key: CFType) ?[]const u8 {
    const v = objc.msg(?objc.Object, attrs, "objectForKey:", .{key}) orelse return null;
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) return null;
    return objc.fromNSString(v);
}

/// `rows(where:)`: every item with `label`, narrowed to `server` when given,
/// as attributes without secrets, handed to `each` one by one. The status
/// when the keychain refused (not found reads as none).
pub fn rows(label: []const u8, server: ?[]const u8, ctx: anytype, comptime each: fn (@TypeOf(ctx), Row) void) i32 {
    const q = ours(label);
    put(q, kSecReturnAttributes, kCFBooleanTrue);
    put(q, kSecMatchLimit, kSecMatchLimitAll);
    if (server) |s| put(q, kSecAttrServer, str(s));
    var out: ?*anyopaque = null;
    const status = SecItemCopyMatching(q, &out);
    const list: objc.Object = @ptrCast(out orelse return if (status == item_not_found) success else status);
    defer CFRelease(list);
    if (status != success) return status;
    if (!objc.msg(objc.BOOL, list, "isKindOfClass:", .{objc.class("NSArray")})) return success;
    for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
        const attrs = objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const protocol = objc.msg(?objc.Object, attrs, "objectForKey:", .{kSecAttrProtocol});
        each(ctx, .{
            .server = text(attrs, kSecAttrServer),
            .account = text(attrs, kSecAttrAccount) orelse "",
            .comment = text(attrs, kSecAttrComment),
            .clear = if (protocol) |p| objc.msg(objc.BOOL, p, "isEqual:", .{kSecAttrProtocolHTTP}) else false,
        });
    }
    return success;
}

/// `secret(host:user:)`: one item's data on `gpa`, or null (with the status).
pub fn secret(gpa: std.mem.Allocator, label: []const u8, server: []const u8, account: []const u8, status: *i32) ?[]u8 {
    const q = ours(label);
    put(q, kSecAttrServer, str(server));
    put(q, kSecAttrAccount, str(account));
    put(q, kSecReturnData, kCFBooleanTrue);
    put(q, kSecMatchLimit, kSecMatchLimitOne);
    var out: ?*anyopaque = null;
    status.* = SecItemCopyMatching(q, &out);
    const data: objc.Object = @ptrCast(out orelse return null);
    defer CFRelease(data);
    if (status.* != success) return null;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const bytes = gpa.alloc(u8, len) catch return null;
    if (len > 0) objc.msg(void, data, "getBytes:length:", .{ bytes.ptr, len });
    return bytes;
}

/// `Vault.save`'s keychain half: update ours, else add it. `comment` is the
/// last use (`String(used.timeIntervalSince1970)`), null to leave it be.
pub fn save(label: []const u8, server: []const u8, account: []const u8, password: []const u8, comment: ?[]const u8, clear: bool) bool {
    // Ours only: server and account alone also match what other apps keep.
    const identity = ours(label);
    put(identity, kSecAttrServer, str(server));
    put(identity, kSecAttrAccount, str(account));
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ password.ptr, @as(objc.NSUInteger, password.len) });
    const fields = dict();
    put(fields, kSecValueData, data);
    put(fields, kSecAttrLabel, str(label));
    put(fields, kSecAttrAuthenticationType, kSecAttrAuthenticationTypeHTMLForm);
    put(fields, kSecAttrProtocol, if (clear) kSecAttrProtocolHTTP else kSecAttrProtocolHTTPS);
    if (comment) |c| put(fields, kSecAttrComment, str(c));
    const status = SecItemUpdate(identity, fields);
    if (status == success) return true;
    if (status != item_not_found) return false;
    const fresh = objc.msg(objc.Object, identity, "mutableCopy", .{});
    defer objc.release(fresh);
    objc.msg(void, fresh, "addEntriesFromDictionary:", .{fields});
    put(fresh, kSecAttrAccessible, kSecAttrAccessibleWhenUnlocked);
    return SecItemAdd(fresh, null) == success;
}

pub fn forget(label: []const u8, server: []const u8, account: []const u8) void {
    const q = ours(label);
    put(q, kSecAttrServer, str(server));
    put(q, kSecAttrAccount, str(account));
    _ = SecItemDelete(q);
}

test "internet keychain compiles; never called in tests" {
    std.testing.refAllDecls(@This());
}
