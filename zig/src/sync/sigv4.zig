//! AWS Signature Version 4, as the bucket wants every request signed
//! (`SigV4` in SyncCore.swift).
const std = @import("std");
const json = @import("../data/json.zig");
const core = @import("core.zig");
const Parts = @import("../data/url.zig").Parts;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Header = [2][]const u8;

fn unreserved(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~';
}

/// Every byte but A–Z a–z 0–9 - _ . ~ (and `/` unless `encode_slash`) as %XX.
pub fn uriEncode(a: std.mem.Allocator, s: []const u8, encode_slash: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| {
        if (unreserved(b) or (!encode_slash and b == '/')) {
            try out.append(a, b);
        } else try out.print(a, "%{X:0>2}", .{b});
    }
    return out.toOwnedSlice(a);
}

/// `yyyyMMdd'T'HHmmss'Z'`, in UTC.
pub fn amzDate(date: json.SwiftDate) [16]u8 {
    const secs: u64 = @intFromFloat(@floor(json.toUnix(date)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

/// `removingPercentEncoding`, leaving a bad escape as it is.
fn percentDecode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(a, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, s[i]);
    }
    return out.toOwnedSlice(a);
}

const Pair = struct { k: []const u8, v: []const u8 };

fn pairLess(_: void, x: Pair, y: Pair) bool {
    const o = std.mem.order(u8, x.k, y.k);
    return if (o == .eq) std.mem.order(u8, x.v, y.v) == .lt else o == .lt;
}

/// The `Authorization` header's value. `headers` are every header signed;
/// strings go on `a` (an arena).
pub fn authorization(
    a: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    headers: []const Header,
    payload_hash: []const u8,
    access: []const u8,
    secret: []const u8,
    region: []const u8,
    service: []const u8,
    date: json.SwiftDate,
) ![]u8 {
    const amz = amzDate(date);
    const short = amz[0..8];
    const parts = Parts.parse(url) orelse Parts{};
    const path = if (parts.path.len == 0) "/" else parts.path;

    // URLComponents.queryItems: names and values decoded, then encoded again.
    var pairs: std.ArrayList(Pair) = .empty;
    if (parts.query) |q| if (q.len > 0) {
        var it = std.mem.splitScalar(u8, q, '&');
        while (it.next()) |item| {
            const eq = std.mem.indexOfScalar(u8, item, '=');
            const name = if (eq) |e| item[0..e] else item;
            const value = if (eq) |e| item[e + 1 ..] else "";
            try pairs.append(a, .{
                .k = try uriEncode(a, try percentDecode(a, name), true),
                .v = try uriEncode(a, try percentDecode(a, value), true),
            });
        }
    };
    std.mem.sort(Pair, pairs.items, {}, pairLess);
    var query: std.ArrayList(u8) = .empty;
    for (pairs.items, 0..) |p, i| try query.print(a, "{s}{s}={s}", .{ if (i > 0) "&" else "", p.k, p.v });

    var hs = try a.alloc(Pair, headers.len);
    for (headers, 0..) |h, i| hs[i] = .{ .k = try std.ascii.allocLowerString(a, h[0]), .v = std.mem.trim(u8, h[1], " \t") };
    std.mem.sort(Pair, hs, {}, struct {
        fn less(_: void, x: Pair, y: Pair) bool {
            return std.mem.order(u8, x.k, y.k) == .lt;
        }
    }.less);
    var canonical_headers: std.ArrayList(u8) = .empty;
    var signed: std.ArrayList(u8) = .empty;
    for (hs, 0..) |h, i| {
        try canonical_headers.print(a, "{s}:{s}\n", .{ h.k, h.v });
        try signed.print(a, "{s}{s}", .{ if (i > 0) ";" else "", h.k });
    }

    const request = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ method, path, query.items, canonical_headers.items, signed.items, payload_hash });
    const scope = try std.fmt.allocPrint(a, "{s}/{s}/{s}/aws4_request", .{ short, region, service });
    const to_sign = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ &amz, scope, &core.hash(request) });

    var k_date: [32]u8 = undefined;
    Hmac.create(&k_date, short, try std.fmt.allocPrint(a, "AWS4{s}", .{secret}));
    var k_region: [32]u8 = undefined;
    Hmac.create(&k_region, region, &k_date);
    var k_service: [32]u8 = undefined;
    Hmac.create(&k_service, service, &k_region);
    var k_signing: [32]u8 = undefined;
    Hmac.create(&k_signing, "aws4_request", &k_service);
    var sig: [32]u8 = undefined;
    Hmac.create(&sig, to_sign, &k_signing);
    return std.fmt.allocPrint(a, "AWS4-HMAC-SHA256 Credential={s}/{s},SignedHeaders={s},Signature={s}", .{ access, scope, signed.items, &std.fmt.bytesToHex(sig, .lower) });
}

test "sigv4 matches AWS example" {
    // "Example: GET Object", Amazon S3 API reference, Signature Version 4
    // (sig-v4-header-based-auth): examplebucket, 20130524T000000Z, us-east-1.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try std.testing.expectEqualStrings(empty, &core.hash(""));
    const date = json.fromUnix(1369353600);
    try std.testing.expectEqualStrings("20130524T000000Z", &amzDate(date));
    const auth = try authorization(a, "GET", "https://examplebucket.s3.amazonaws.com/test.txt", &.{
        .{ "Host", "examplebucket.s3.amazonaws.com" },
        .{ "Range", "bytes=0-9" },
        .{ "x-amz-content-sha256", empty },
        .{ "x-amz-date", "20130524T000000Z" },
    }, empty, "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "us-east-1", "s3", date);
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        auth,
    );
    const enc = try uriEncode(a, "a b/ü~", true);
    try std.testing.expectEqualStrings("a%20b%2F%C3%BC~", enc);
}
