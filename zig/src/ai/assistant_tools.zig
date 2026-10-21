//! Tool-call accumulation and multi-round execution loop for `assistant_runs.Send`.
const std = @import("std");
const cs = @import("../data/chats_store.zig");
const client = @import("client.zig");
const sse = @import("client_sse.zig");
const page = @import("page_text.zig");
const ubi = @import("ubi_chat.zig");
const tools = @import("tools.zig");
const runs = @import("assistant_runs.zig");
const Send = runs.Send;
const A = std.mem.Allocator;

pub const AccCall = struct {
    index: usize,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
    thought_sig: ?[]const u8 = null,
};

pub const Round = struct {
    pending: std.ArrayList(AccCall) = .empty,
    extra: std.ArrayList(client.Message) = .empty,
    base_msgs: []const client.Message = &.{},
    system_prompt: []const u8 = "",
    count: usize = 0,
    next_call: usize = 0,
    asked_with_tools: bool = false,
};

pub fn onTool(raw: *anyopaque, ev: sse.ToolEvent) void {
    const r: *Send = @ptrCast(@alignCast(raw));
    const a = r.arena.allocator();
    var target: ?*AccCall = null;
    for (r.round.pending.items) |*c| {
        if (c.index == ev.index) {
            target = c;
            break;
        }
    }
    if (target == null) {
        r.round.pending.append(a, .{ .index = ev.index }) catch return;
        target = &r.round.pending.items[r.round.pending.items.len - 1];
    }
    const c = target.?;
    if (ev.id) |id| if (id.len > 0) {
        c.id.clearRetainingCapacity();
        c.id.appendSlice(a, id) catch {};
    };
    if (ev.name) |name| if (name.len > 0) {
        c.name.clearRetainingCapacity();
        c.name.appendSlice(a, name) catch {};
    };
    if (ev.args_delta.len > 0) {
        c.args.appendSlice(a, ev.args_delta) catch {};
    }
    if (ev.thought_sig) |sig| if (sig.len > 0) {
        c.thought_sig = a.dupe(u8, sig) catch null;
    };
}

pub fn ask(r: *Send) void {
    if (r.dead) return r.free();
    const a = r.arena.allocator();
    if (r.round.base_msgs.len == 0) {
        const fence = page.newFence(&r.fence);
        r.round.base_msgs = r.messages(a, fence) catch return r.fail();
        r.round.system_prompt = ubi.system(a, fence) catch return r.fail();
    }
    const msgs = std.mem.concat(a, client.Message, &.{ r.round.base_msgs, r.round.extra.items }) catch return r.fail();
    if (r.asking.failure) |f| r.gpa.free(f);
    r.asking.failure = null;
    r.asking.http_status = null;
    r.asking.over = false;
    r.asking.dropped = false;
    r.asking.text.clearRetainingCapacity();
    r.asking.chars = 0;
    r.round.pending.clearRetainingCapacity();

    const use_tools = r.m.prefs.ubi_tools and !r.m.isNoTools(r.provider.id, r.model) and r.round.count < 3;
    r.round.asked_with_tools = use_tools;
    r.phase = .streaming;
    r.asking.begin(r.m, .{
        .provider = r.provider,
        .model = r.model,
        .system = r.round.system_prompt,
        .messages = msgs,
        .key = r.key,
        .max_tokens = 4096,
        .thinking = 1024,
        .tools = use_tools,
    });
}

/// Returns true when the run continues into a fallback ask or a tool execution round.
pub fn ended(r: *Send) bool {
    if (r.asking.dropped or r.dead) return false;
    if (r.asking.failure != null) {
        if (r.asking.http_status == 400 and r.round.count == 0 and r.round.asked_with_tools) {
            r.m.rememberNoTools(r.provider.id, r.model);
            if (r.owner()) |self| if (self.live) |*l| l.answer.clearRetainingCapacity();
            ask(r);
            return true;
        }
        return false;
    }
    if (r.round.pending.items.len == 0) return false;
    const a = r.arena.allocator();
    const calls = a.alloc(client.Call, r.round.pending.items.len) catch return false;
    for (r.round.pending.items, 0..) |c, i| {
        const id = if (c.id.items.len > 0) c.id.items else (std.fmt.allocPrint(a, "call_{d}", .{i}) catch "call_0");
        const args = if (c.args.items.len > 0) c.args.items else "{}";
        calls[i] = .{ .id = id, .name = c.name.items, .args = args, .thought_sig = c.thought_sig };
    }
    const text = a.dupe(u8, r.asking.text.items) catch "";
    r.round.extra.append(a, .{ .role = .assistant, .text = text, .calls = calls }) catch return false;
    if (r.owner()) |self| if (self.live) |*l| l.answer.clearRetainingCapacity();
    r.phase = .tooling;
    r.round.next_call = 0;
    runNext(r);
    return true;
}

fn runNext(r: *Send) void {
    if (r.dead) return r.free();
    const self = r.owner() orelse return r.release();
    const b = self.browser orelse return r.release();
    if (r.round.next_call >= r.round.pending.items.len) {
        r.round.count += 1;
        return ask(r);
    }
    const idx = r.round.next_call;
    r.round.next_call += 1;
    const call = r.round.pending.items[idx];
    const args = if (call.args.items.len == 0) "{}" else call.args.items;
    tools.run(b, r.arena.allocator(), call.name.items, args, r, toolDone);
}

fn toolDone(raw: *anyopaque, res: tools.Result) void {
    const r: *Send = @ptrCast(@alignCast(raw));
    if (r.dead) return r.free();
    const a = r.arena.allocator();
    const idx = r.round.next_call - 1;
    const call = r.round.pending.items[idx];
    const id = if (call.id.items.len > 0) call.id.items else (std.fmt.allocPrint(a, "call_{d}", .{idx}) catch "call_0");
    var result_text = res.text;
    if (res.read) |rd| {
        r.reads.append(a, rd) catch {};
        if (rd.addressed) {
            if (r.owner()) |self| self.addressed = true;
        }
        result_text = page.fenced(a, rd, &r.fence) catch res.text;
    }
    r.round.extra.append(a, .{ .role = .tool, .text = result_text, .call_id = id, .name = call.name.items }) catch {};
    if (r.owner()) |self| if (self.live) |*l| {
        if (self.gpa.dupe(u8, res.said)) |dup| {
            l.tools.append(self.gpa, .{ .said = dup }) catch self.gpa.free(dup);
        } else |_| {}
        self.changed();
    };
    runNext(r);
}
