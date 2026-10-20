//! A page's request as AuthenticationServices takes it (Passkeys.swift
//! "requests" and the PRF inputs): platform passkeys and security keys,
//! with the client data Kea writes. Main thread, inside an `objc.Pool`;
//! everything returned is autoreleased.
const std = @import("std");
const objc = @import("nanoui").objc;
const reply = @import("passkeys_reply.zig");

/// A request body, as the page's script sent it (`[String: Any]`).
pub const Body = std.json.Value;

pub fn field(v: Body, key: []const u8) ?Body {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// `body[key] as? String`.
pub fn str(v: Body, key: []const u8) ?[]const u8 {
    return switch (field(v, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// `body[key] as? Bool`.
pub fn boolean(v: Body, key: []const u8) ?bool {
    return switch (field(v, key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

/// `body[key] as? [String: Any]`.
pub fn object(v: Body, key: []const u8) ?Body {
    const f = field(v, key) orelse return null;
    return if (f == .object) f else null;
}

extern "c" const ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialUserVerificationPreferenceRequired: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialUserVerificationPreferenceDiscouraged: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialAttestationKindNone: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialAttestationKindDirect: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialAttestationKindIndirect: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialAttestationKindEnterprise: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialResidentKeyPreferenceDiscouraged: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialResidentKeyPreferencePreferred: objc.Object;
extern "c" const ASAuthorizationPublicKeyCredentialResidentKeyPreferenceRequired: objc.Object;
extern "c" const ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportUSB: objc.Object;
extern "c" const ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportNFC: objc.Object;
extern "c" const ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportBluetooth: objc.Object;
extern "c" fn ASAuthorizationAllSupportedPublicKeyCredentialDescriptorTransports() objc.Object;

const OsVersion = extern struct { major: objc.NSInteger, minor: objc.NSInteger, patch: objc.NSInteger };

/// `#available(macOS major.minor, *)`.
pub fn atLeast(major: objc.NSInteger, minor: objc.NSInteger) bool {
    const want: OsVersion = .{ .major = major, .minor = minor, .patch = 0 };
    return objc.msg(objc.BOOL, objc.msg(objc.Object, objc.class("NSProcessInfo"), "processInfo", .{}), "isOperatingSystemAtLeastVersion:", .{want});
}

/// Whether this Mac can derive keys from a passkey (`prfAvailable`).
pub fn prfAvailable() bool {
    return atLeast(15, 0);
}

pub fn nsData(bytes: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) });
}

fn array() objc.Object {
    return objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
}

fn add(list: objc.Object, item: objc.Object) void {
    objc.msg(void, list, "addObject:", .{item});
}

/// `ASPublicKeyCredentialClientData(challenge:origin:)`, retained.
pub fn clientData(challenge: []const u8, origin: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.alloc("ASPublicKeyCredentialClientData"), "initWithChallenge:origin:", .{ nsData(challenge), objc.nsString(origin) });
}

pub fn verification(value: ?[]const u8) objc.Object {
    const v = value orelse "";
    if (std.mem.eql(u8, v, "required")) return ASAuthorizationPublicKeyCredentialUserVerificationPreferenceRequired;
    if (std.mem.eql(u8, v, "discouraged")) return ASAuthorizationPublicKeyCredentialUserVerificationPreferenceDiscouraged;
    return ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred;
}

fn attestation(value: ?[]const u8) objc.Object {
    const v = value orelse "";
    if (std.mem.eql(u8, v, "direct")) return ASAuthorizationPublicKeyCredentialAttestationKindDirect;
    if (std.mem.eql(u8, v, "indirect")) return ASAuthorizationPublicKeyCredentialAttestationKindIndirect;
    if (std.mem.eql(u8, v, "enterprise")) return ASAuthorizationPublicKeyCredentialAttestationKindEnterprise;
    return ASAuthorizationPublicKeyCredentialAttestationKindNone;
}

pub const Descriptor = struct { id: []u8, transports: objc.Object };

/// `descriptors(_:)`: each entry with an id; its transports, or all.
pub fn descriptors(a: std.mem.Allocator, value: ?Body) ![]Descriptor {
    var out: std.ArrayList(Descriptor) = .empty;
    const items = switch (value orelse return out.toOwnedSlice(a)) {
        .array => |l| l.items,
        else => return out.toOwnedSlice(a),
    };
    for (items) |item| {
        if (item != .object) continue;
        const id = reply.data(a, str(item, "id") orelse continue) orelse continue;
        const named = array();
        if (field(item, "transports")) |t| if (t == .array) for (t.array.items) |n| {
            if (n != .string) continue;
            if (std.mem.eql(u8, n.string, "usb")) add(named, ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportUSB);
            if (std.mem.eql(u8, n.string, "nfc")) add(named, ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportNFC);
            if (std.mem.eql(u8, n.string, "ble")) add(named, ASAuthorizationSecurityKeyPublicKeyCredentialDescriptorTransportBluetooth);
        };
        const none = objc.msg(objc.NSUInteger, named, "count", .{}) == 0;
        try out.append(a, .{ .id = id, .transports = if (none) ASAuthorizationAllSupportedPublicKeyCredentialDescriptorTransports() else named });
    }
    return out.toOwnedSlice(a);
}

fn platformDescriptors(list: []const Descriptor) objc.Object {
    const out = array();
    for (list) |d| add(out, objc.msg(objc.Object, objc.msg(objc.Object, objc.alloc("ASAuthorizationPlatformPublicKeyCredentialDescriptor"), "initWithCredentialID:", .{nsData(d.id)}), "autorelease", .{}));
    return out;
}

fn keyDescriptors(list: []const Descriptor) objc.Object {
    const out = array();
    for (list) |d| add(out, objc.msg(objc.Object, objc.msg(objc.Object, objc.alloc("ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor"), "initWithCredentialID:transports:", .{ nsData(d.id), d.transports }), "autorelease", .{}));
    return out;
}

fn provider(comptime cls: [:0]const u8, rp: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.msg(objc.Object, objc.alloc(cls), "initWithRelyingPartyIdentifier:", .{objc.nsString(rp)}), "autorelease", .{});
}

// MARK: PRF

/// `prfValues`: the salts, as AuthenticationServices takes them.
fn prfValues(a: std.mem.Allocator, value: ?Body) ?objc.Object {
    const v = value orelse return null;
    if (v != .object) return null;
    const first = reply.data(a, str(v, "first") orelse return null) orelse return null;
    const second: ?objc.Object = if (str(v, "second")) |s| if (reply.data(a, s)) |d| nsData(d) else null else null;
    return objc.msg(objc.Object, objc.msg(objc.Object, objc.alloc("ASAuthorizationPublicKeyCredentialPRFAssertionInputValues"), "initWithSaltInput1:saltInput2:", .{ nsData(first), second }), "autorelease", .{});
}

/// `prfAssertion`: `eval`, and `byCredential` for the allowed passkeys only.
pub fn prfAssertion(a: std.mem.Allocator, value: ?Body, allowed: []const []const u8) ?objc.Object {
    if (!prfAvailable()) return null;
    const prf = value orelse return null;
    if (prf != .object) return null;
    const by = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    if (object(prf, "byCredential")) |m| {
        var it = m.object.iterator();
        while (it.next()) |e| {
            const id = reply.data(a, e.key_ptr.*) orelse continue;
            const ok = for (allowed) |x| {
                if (std.mem.eql(u8, x, id)) break true;
            } else false;
            if (!ok) continue;
            const values = prfValues(a, e.value_ptr.*) orelse continue;
            objc.msg(void, by, "setObject:forKey:", .{ values, nsData(id) });
        }
    }
    const empty = objc.msg(objc.NSUInteger, by, "count", .{}) == 0;
    const eval = prfValues(a, field(prf, "eval"));
    if (eval == null and empty) return null;
    return objc.msg(objc.Object, objc.msg(objc.Object, objc.alloc("ASAuthorizationPublicKeyCredentialPRFAssertionInput"), "initWithInputValues:perCredentialInputValues:", .{ eval, if (empty) null else by }), "autorelease", .{});
}

fn setPrf(request: objc.Object, prf: ?objc.Object) void {
    if (!prfAvailable() or !objc.msg(objc.BOOL, request, "respondsToSelector:", .{objc.sel("setPrf:")})) return;
    objc.msg(void, request, "setPrf:", .{prf});
}

// MARK: requests

fn ids(a: std.mem.Allocator, list: []const Descriptor) ![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |d, *o| o.* = d.id;
    return out;
}

/// `assertion`: the Mac's passkeys, and from 14.4 a security key's too.
/// `a` is an arena.
pub fn assertion(a: std.mem.Allocator, body: Body, rp: []const u8, client: objc.Object) !objc.Object {
    const allowed = try descriptors(a, field(body, "allowCredentials"));
    const uv = verification(str(body, "userVerification"));
    const platform = objc.msg(objc.Object, provider("ASAuthorizationPlatformPublicKeyCredentialProvider", rp), "createCredentialAssertionRequestWithClientData:", .{client});
    objc.msg(void, platform, "setAllowedCredentials:", .{platformDescriptors(allowed)});
    objc.msg(void, platform, "setUserVerificationPreference:", .{uv});
    setPrf(platform, prfAssertion(a, field(body, "prf"), try ids(a, allowed)));
    const requests = array();
    add(requests, platform);
    if (atLeast(14, 4)) {
        const key = objc.msg(objc.Object, provider("ASAuthorizationSecurityKeyPublicKeyCredentialProvider", rp), "createCredentialAssertionRequestWithClientData:", .{client});
        objc.msg(void, key, "setAllowedCredentials:", .{keyDescriptors(allowed)});
        objc.msg(void, key, "setUserVerificationPreference:", .{uv});
        add(requests, key);
    }
    return requests;
}

/// The Mac's sheet for one passkey picked under the field (`sign(in:with:)`).
pub fn picked(a: std.mem.Allocator, body: Body, rp: []const u8, client: objc.Object, id: []const u8) objc.Object {
    const request = objc.msg(objc.Object, provider("ASAuthorizationPlatformPublicKeyCredentialProvider", rp), "createCredentialAssertionRequestWithClientData:", .{client});
    const one = [_]Descriptor{.{ .id = @constCast(id), .transports = undefined }};
    objc.msg(void, request, "setAllowedCredentials:", .{platformDescriptors(&one)});
    objc.msg(void, request, "setUserVerificationPreference:", .{verification(str(body, "userVerification"))});
    setPrf(request, prfAssertion(a, field(body, "prf"), &.{id}));
    const requests = array();
    add(requests, request);
    return requests;
}

/// `registration`: null when the request names no user, or one too long.
pub fn registration(a: std.mem.Allocator, body: Body, rp: []const u8, client: objc.Object) !?objc.Object {
    const user = object(body, "user") orelse return null;
    const user_id = reply.data(a, str(user, "id") orelse return null) orelse return null;
    if (user_id.len < 1 or user_id.len > 64) return null;
    const name = str(user, "name") orelse return null;
    const display = if (str(user, "displayName")) |d| (if (d.len == 0) name else d) else name;
    const uv = verification(str(body, "userVerification"));
    const kind = attestation(str(body, "attestation"));
    const excluded = try descriptors(a, field(body, "excludeCredentials"));
    const attachment = str(body, "authenticatorAttachment");
    // No list means ES256 or RS256, as the standard has it.
    var algorithms: std.ArrayList(objc.NSInteger) = .empty;
    if (field(body, "algorithms")) |list| if (list == .array) for (list.array.items) |n| {
        if (n != .integer) {
            algorithms.clearRetainingCapacity();
            break;
        }
        try algorithms.append(a, @intCast(n.integer));
    };
    if (algorithms.items.len == 0) try algorithms.appendSlice(a, &.{ -7, -257 });
    const requests = array();
    const es256 = std.mem.indexOfScalar(objc.NSInteger, algorithms.items, -7) != null;
    if (!eql(attachment, "cross-platform") and es256) {
        const platform = objc.msg(objc.Object, provider("ASAuthorizationPlatformPublicKeyCredentialProvider", rp), "createCredentialRegistrationRequestWithClientData:name:userID:", .{ client, objc.nsString(name), nsData(user_id) });
        objc.msg(void, platform, "setDisplayName:", .{objc.nsString(display)});
        objc.msg(void, platform, "setUserVerificationPreference:", .{uv});
        objc.msg(void, platform, "setAttestationPreference:", .{kind});
        if (atLeast(14, 4)) objc.msg(void, platform, "setExcludedCredentials:", .{platformDescriptors(excluded)});
        if (prfAvailable()) if (object(body, "prf")) |prf| {
            const cls = objc.class("ASAuthorizationPublicKeyCredentialPRFRegistrationInput");
            const input = if (prfValues(a, field(prf, "eval"))) |values|
                objc.msg(objc.Object, objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithInputValues:", .{values}), "autorelease", .{})
            else
                objc.msg(objc.Object, cls, "checkForSupport", .{});
            setPrf(platform, input);
        };
        add(requests, platform);
    }
    if (!eql(attachment, "platform") and atLeast(14, 4)) {
        const key = objc.msg(objc.Object, provider("ASAuthorizationSecurityKeyPublicKeyCredentialProvider", rp), "createCredentialRegistrationRequestWithClientData:displayName:name:userID:", .{ client, objc.nsString(display), objc.nsString(name), nsData(user_id) });
        const params = array();
        for (algorithms.items) |alg| add(params, objc.msg(objc.Object, objc.msg(objc.Object, objc.alloc("ASAuthorizationPublicKeyCredentialParameters"), "initWithAlgorithm:", .{alg}), "autorelease", .{}));
        objc.msg(void, key, "setCredentialParameters:", .{params});
        objc.msg(void, key, "setUserVerificationPreference:", .{uv});
        objc.msg(void, key, "setAttestationPreference:", .{kind});
        const resident = str(body, "residentKey") orelse "";
        objc.msg(void, key, "setResidentKeyPreference:", .{if (std.mem.eql(u8, resident, "required"))
            ASAuthorizationPublicKeyCredentialResidentKeyPreferenceRequired
        else if (std.mem.eql(u8, resident, "preferred"))
            ASAuthorizationPublicKeyCredentialResidentKeyPreferencePreferred
        else
            ASAuthorizationPublicKeyCredentialResidentKeyPreferenceDiscouraged});
        objc.msg(void, key, "setExcludedCredentials:", .{keyDescriptors(excluded)});
        add(requests, key);
    }
    return requests;
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    return std.mem.eql(u8, a orelse return false, b);
}
