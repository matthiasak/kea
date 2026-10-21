//! Per-wire JSON encoding of chat messages, images, tool definitions,
//! assistant tool calls, and tool results for OpenAI, Anthropic and Gemini.
const std = @import("std");
const ai = @import("ai.zig");
const client = @import("client.zig");
const tools = @import("tools.zig");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;
const A = std.mem.Allocator;

fn str(s: []const u8) Value {
    return .{ .string = s };
}

fn parseOrEmptyObject(a: A, raw: []const u8) !Value {
    if (raw.len > 0) {
        if (std.json.parseFromSliceLeaky(Value, a, raw, .{})) |v| {
            if (v == .object) return v;
        } else |_| {}
    }
    return .{ .object = .empty };
}

fn paramSchema(a: A, param: []const u8, desc: []const u8) !Value {
    var prop: ObjectMap = .empty;
    try prop.put(a, "type", str("string"));
    try prop.put(a, "description", str(desc));
    var props: ObjectMap = .empty;
    try props.put(a, param, .{ .object = prop });
    var req = Array.init(a);
    try req.append(str(param));
    var schema: ObjectMap = .empty;
    try schema.put(a, "type", str("object"));
    try schema.put(a, "properties", .{ .object = props });
    try schema.put(a, "required", .{ .array = req });
    return .{ .object = schema };
}

pub fn toolsFor(a: A, wire: ai.Wire) !Value {
    var list = Array.init(a);
    for (tools.specs) |s| {
        const schema = try paramSchema(a, s.param, s.param_description);
        switch (wire) {
            .openAI => {
                var fn_obj: ObjectMap = .empty;
                try fn_obj.put(a, "name", str(s.name));
                try fn_obj.put(a, "description", str(s.description));
                try fn_obj.put(a, "parameters", schema);
                var item: ObjectMap = .empty;
                try item.put(a, "type", str("function"));
                try item.put(a, "function", .{ .object = fn_obj });
                try list.append(.{ .object = item });
            },
            .anthropic => {
                var item: ObjectMap = .empty;
                try item.put(a, "name", str(s.name));
                try item.put(a, "description", str(s.description));
                try item.put(a, "input_schema", schema);
                try list.append(.{ .object = item });
            },
            .gemini => {
                var item: ObjectMap = .empty;
                try item.put(a, "name", str(s.name));
                try item.put(a, "description", str(s.description));
                try item.put(a, "parameters", schema);
                try list.append(.{ .object = item });
            },
        }
    }
    if (wire == .gemini) {
        var wrap = Array.init(a);
        var decls: ObjectMap = .empty;
        try decls.put(a, "functionDeclarations", .{ .array = list });
        try wrap.append(.{ .object = decls });
        return .{ .array = wrap };
    }
    return .{ .array = list };
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
        if (msg.role == .tool) {
            try obj.put(a, "tool_call_id", str(msg.call_id orelse ""));
            try obj.put(a, "content", str(msg.text));
        } else if (msg.calls.len > 0) {
            if (msg.text.len > 0) try obj.put(a, "content", str(msg.text));
            var tcs = Array.init(a);
            for (msg.calls) |c| {
                var fn_obj: ObjectMap = .empty;
                try fn_obj.put(a, "name", str(c.name));
                try fn_obj.put(a, "arguments", str(c.args));
                var tc: ObjectMap = .empty;
                try tc.put(a, "id", str(c.id));
                try tc.put(a, "type", str("function"));
                try tc.put(a, "function", .{ .object = fn_obj });
                try tcs.append(.{ .object = tc });
            }
            try obj.put(a, "tool_calls", .{ .array = tcs });
        } else if (msg.images.len == 0) {
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
    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        if (msg.role == .tool) {
            var blocks = Array.init(a);
            while (i < messages.len and messages[i].role == .tool) : (i += 1) {
                var tr: ObjectMap = .empty;
                try tr.put(a, "type", str("tool_result"));
                try tr.put(a, "tool_use_id", str(messages[i].call_id orelse ""));
                try tr.put(a, "content", str(messages[i].text));
                try blocks.append(.{ .object = tr });
            }
            var obj: ObjectMap = .empty;
            try obj.put(a, "role", str("user"));
            try obj.put(a, "content", .{ .array = blocks });
            try out.append(a, .{ .object = obj });
            continue;
        }
        i += 1;
        var obj: ObjectMap = .empty;
        try obj.put(a, "role", str(@tagName(msg.role)));
        if (msg.calls.len > 0) {
            var blocks = Array.init(a);
            if (msg.text.len > 0) {
                var txt: ObjectMap = .empty;
                try txt.put(a, "type", str("text"));
                try txt.put(a, "text", str(msg.text));
                try blocks.append(.{ .object = txt });
            }
            for (msg.calls) |c| {
                var tu: ObjectMap = .empty;
                try tu.put(a, "type", str("tool_use"));
                try tu.put(a, "id", str(c.id));
                try tu.put(a, "name", str(c.name));
                try tu.put(a, "input", try parseOrEmptyObject(a, c.args));
                try blocks.append(.{ .object = tu });
            }
            try obj.put(a, "content", .{ .array = blocks });
        } else if (msg.images.len == 0) {
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
    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        if (msg.role == .tool) {
            var parts = Array.init(a);
            while (i < messages.len and messages[i].role == .tool) : (i += 1) {
                var resp: ObjectMap = .empty;
                try resp.put(a, "result", str(messages[i].text));
                var fr: ObjectMap = .empty;
                try fr.put(a, "name", str(messages[i].name orelse ""));
                try fr.put(a, "response", .{ .object = resp });
                var p: ObjectMap = .empty;
                try p.put(a, "functionResponse", .{ .object = fr });
                try parts.append(.{ .object = p });
            }
            var obj: ObjectMap = .empty;
            try obj.put(a, "role", str("user"));
            try obj.put(a, "parts", .{ .array = parts });
            try out.append(a, .{ .object = obj });
            continue;
        }
        i += 1;
        var parts = Array.init(a);
        for (msg.images) |img| {
            var inline_data: ObjectMap = .empty;
            try inline_data.put(a, "mimeType", str(img.media_type));
            try inline_data.put(a, "data", str(img.b64));
            var p: ObjectMap = .empty;
            try p.put(a, "inlineData", .{ .object = inline_data });
            try parts.append(.{ .object = p });
        }
        if (msg.text.len > 0 or msg.calls.len == 0) {
            var tp: ObjectMap = .empty;
            try tp.put(a, "text", str(msg.text));
            try parts.append(.{ .object = tp });
        }
        for (msg.calls) |c| {
            var fc: ObjectMap = .empty;
            try fc.put(a, "name", str(c.name));
            try fc.put(a, "args", try parseOrEmptyObject(a, c.args));
            var p: ObjectMap = .empty;
            try p.put(a, "functionCall", .{ .object = fc });
            if (c.thought_sig) |sig| try p.put(a, "thoughtSignature", str(sig));
            try parts.append(.{ .object = p });
        }
        var obj: ObjectMap = .empty;
        try obj.put(a, "role", str(if (msg.role == .user) "user" else "model"));
        try obj.put(a, "parts", .{ .array = parts });
        try out.append(a, .{ .object = obj });
    }
    return out.items;
}
