//! Per-wire JSON encoding of chat messages (and images/tools) for OpenAI,
//! Anthropic and Gemini requests.
const std = @import("std");
const client = @import("client.zig");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;
const A = std.mem.Allocator;

fn str(s: []const u8) Value {
    return .{ .string = s };
}

pub fn openAI(a: A, system: []const u8, messages: []const client.Message) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    {
        var sys: ObjectMap = .empty;
        try sys.put(a, "role", str("system"));
        try sys.put(a, "content", str(system));
        try out.append(a, .{ .object = sys });
    }
    for (messages) |msg| {
        var obj: ObjectMap = .empty;
        try obj.put(a, "role", str(@tagName(msg.role)));
        if (msg.images.len == 0) {
            try obj.put(a, "content", str(msg.text));
        } else {
            var parts = Array.init(a);
            var text_part: ObjectMap = .empty;
            try text_part.put(a, "type", str("text"));
            try text_part.put(a, "text", str(msg.text));
            try parts.append(.{ .object = text_part });
            for (msg.images) |img| {
                const data_url = try std.fmt.allocPrint(a, "data:{s};base64,{s}", .{ img.media_type, img.b64 });
                var url_obj: ObjectMap = .empty;
                try url_obj.put(a, "url", str(data_url));
                var img_part: ObjectMap = .empty;
                try img_part.put(a, "type", str("image_url"));
                try img_part.put(a, "image_url", .{ .object = url_obj });
                try parts.append(.{ .object = img_part });
            }
            try obj.put(a, "content", .{ .array = parts });
        }
        try out.append(a, .{ .object = obj });
    }
    return out.items;
}

pub fn anthropic(a: A, messages: []const client.Message) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    for (messages) |msg| {
        var obj: ObjectMap = .empty;
        try obj.put(a, "role", str(@tagName(msg.role)));
        if (msg.images.len == 0) {
            try obj.put(a, "content", str(msg.text));
        } else {
            var blocks = Array.init(a);
            for (msg.images) |img| {
                var src: ObjectMap = .empty;
                try src.put(a, "type", str("base64"));
                try src.put(a, "media_type", str(img.media_type));
                try src.put(a, "data", str(img.b64));
                var blk: ObjectMap = .empty;
                try blk.put(a, "type", str("image"));
                try blk.put(a, "source", .{ .object = src });
                try blocks.append(.{ .object = blk });
            }
            var txt: ObjectMap = .empty;
            try txt.put(a, "type", str("text"));
            try txt.put(a, "text", str(msg.text));
            try blocks.append(.{ .object = txt });
            try obj.put(a, "content", .{ .array = blocks });
        }
        try out.append(a, .{ .object = obj });
    }
    return out.items;
}

pub fn gemini(a: A, messages: []const client.Message) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    for (messages) |msg| {
        var parts = Array.init(a);
        for (msg.images) |img| {
            var inline_data: ObjectMap = .empty;
            try inline_data.put(a, "mimeType", str(img.media_type));
            try inline_data.put(a, "data", str(img.b64));
            var p: ObjectMap = .empty;
            try p.put(a, "inlineData", .{ .object = inline_data });
            try parts.append(.{ .object = p });
        }
        var tp: ObjectMap = .empty;
        try tp.put(a, "text", str(msg.text));
        try parts.append(.{ .object = tp });
        var obj: ObjectMap = .empty;
        try obj.put(a, "role", str(if (msg.role == .user) "user" else "model"));
        try obj.put(a, "parts", .{ .array = parts });
        try out.append(a, .{ .object = obj });
    }
    return out.items;
}
