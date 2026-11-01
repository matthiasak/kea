//! Rich text: one paragraph whose spans change the font — bold, italics,
//! inline code in the monospaced font — shaped by CoreText as runs of an
//! attributed string, wrapped across them, and cached as plain text is.
//! Spans that only color text never come here: they keep the fast path.
const std = @import("std");
const cf = @import("cf.zig");
const types = @import("types.zig");
const text = @import("text_mac.zig");

extern "c" fn CFAttributedStringCreateMutable(alloc: ?*anyopaque, max: cf.CFIndex) ?cf.CFAttributedStringRef;
extern "c" fn CFAttributedStringReplaceString(s: cf.CFAttributedStringRef, range: cf.CFRange, with: cf.CFStringRef) void;
extern "c" fn CFAttributedStringSetAttribute(s: cf.CFAttributedStringRef, range: cf.CFRange, name: cf.CFStringRef, value: *const anyopaque) void;
extern "c" fn CFAttributedStringBeginEditing(s: cf.CFAttributedStringRef) void;
extern "c" fn CFAttributedStringEndEditing(s: cf.CFAttributedStringRef) void;
extern "c" const kCTKernAttributeName: cf.CFStringRef;
extern "c" fn CFNumberCreate(alloc: ?*anyopaque, kind: cf.CFIndex, value: *const anyopaque) ?*anyopaque;

const spans_mod = @import("spans.zig");
pub const mono_scale = spans_mod.mono_scale;
pub const styled = spans_mod.styled;
pub const spanStyle = spans_mod.spanStyle;
pub const spansHash = spans_mod.spansHash;

/// `s` (bytes `offset`… of the paragraph the spans index) as an
/// attributed string, each span in its font; release with CFRelease.
pub fn attributed(ts: *text.TextSystem, s: []const u8, base: types.TextStyle, spans: []const types.Span, offset: usize) cf.CFAttributedStringRef {
    const m = CFAttributedStringCreateMutable(null, 0) orelse return cf.attributed(s, ts.font(base).ref);
    const str = cf.string(s);
    defer cf.CFRelease(str);
    CFAttributedStringBeginEditing(m);
    CFAttributedStringReplaceString(m, .{ .location = 0, .length = 0 }, str);
    const str_len = cf.CFStringGetLength(str);
    const total = @min(cf.utf16Offset(s, s.len), str_len);
    CFAttributedStringSetAttribute(m, .{ .location = 0, .length = total }, cf.kCTFontAttributeName, ts.font(base).ref);
    CFAttributedStringSetAttribute(m, .{ .location = 0, .length = total }, cf.kCTForegroundColorFromContextAttributeName, cf.kCFBooleanTrue);
    const end = offset + s.len;
    for (spans) |sp| {
        // A pill's room: kerning after the glyph before it and after its last.
        if (sp.pad_x > 0 and sp.end > offset and sp.start <= end) {
            const pad: f64 = sp.pad_x;
            const n = CFNumberCreate(null, 6, &pad); // kCFNumberFloat64Type
            defer if (n) |v| cf.CFRelease(v);
            if (n) |num| for ([_]usize{ sp.start, sp.end }) |at| {
                if (at <= offset or at > end) continue;
                const u = @min(cf.utf16Offset(s, at - offset), total);
                if (u > 0) CFAttributedStringSetAttribute(m, .{ .location = u - 1, .length = 1 }, kCTKernAttributeName, num);
            };
        }
        if (!sp.styled() or sp.end <= offset or sp.start >= end) continue;
        const a = @max(sp.start, offset) - offset;
        const b = @min(sp.end, end) - offset;
        const from = @min(cf.utf16Offset(s, a), total);
        const to = @min(cf.utf16Offset(s, b), total);
        if (to <= from) continue;
        if (sp.weight == null and !sp.italic and !sp.mono) continue;
        CFAttributedStringSetAttribute(m, .{ .location = from, .length = to - from }, cf.kCTFontAttributeName, ts.font(spanStyle(base, sp)).ref);
    }
    CFAttributedStringEndEditing(m);
    return m;
}

/// `s` shaped on one line, with the spans of the paragraph it starts at
/// byte `offset` of.
pub fn layout(ts: *text.TextSystem, s: []const u8, base: types.TextStyle, spans: []const types.Span, offset: usize) text.Layout {
    if (s.len == 0) return .{ .width = 0, .glyphs = &.{} };
    const k = text.TextSystem.key(s, base, 3 ^ spansHash(spans, offset, offset + s.len));
    if (ts.cached(k)) |l| return l;
    const attr = attributed(ts, s, base, spans, offset);
    defer cf.CFRelease(attr);
    const ln = cf.CTLineCreateWithAttributedString(attr) orelse return .{ .width = 0, .glyphs = &.{} };
    defer cf.CFRelease(ln);
    return ts.keep(k, ts.glyphsOf(ln, s) catch return .{ .width = 0, .glyphs = &.{} });
}
