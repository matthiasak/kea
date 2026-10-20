//! tts.* on the Mac's own voices (ExtensionShims.swift 3714-3741): one
//! AVSpeechSynthesizer, kept on `answer.speaker`, for every extension.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");

extern "c" const AVSpeechUtteranceDefaultSpeechRate: f32;
extern "c" const AVSpeechUtteranceMinimumSpeechRate: f32;
extern "c" const AVSpeechUtteranceMaximumSpeechRate: f32;

/// AVSpeechBoundaryImmediate.
const immediate: objc.NSInteger = 0;

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    if (!std.mem.startsWith(u8, api, "tts.")) return null;
    const name = api["tts.".len..];
    const pool = objc.Pool.push();
    defer pool.pop();
    if (eql(name, "speak")) {
        const options = c.arg(1);
        const sp = speaker(c);
        // Swift's `as? Bool` takes an NSNumber 1 too.
        const enqueue = ans.field(options, "enqueue");
        if (!(ans.flag(enqueue) orelse (ans.int(enqueue) == 1))) _ = objc.msg(objc.BOOL, sp, "stopSpeakingAtBoundary:", .{immediate});
        const utterance = objc.msg(objc.Object, objc.class("AVSpeechUtterance"), "speechUtteranceWithString:", .{objc.nsString(ans.str(c.first()) orelse "")});
        if (ans.str(ans.field(options, "voiceName"))) |wanted| {
            const voices = allVoices();
            var voice: ?objc.Object = null;
            for (0..objc.msg(objc.NSUInteger, voices, "count", .{})) |i| {
                const v = objc.msg(objc.Object, voices, "objectAtIndex:", .{i});
                if (eql(objc.fromNSString(objc.msg(?objc.Object, v, "name", .{})), wanted)) {
                    voice = v;
                    break;
                }
            }
            objc.msg(void, utterance, "setVoice:", .{voice});
        }
        if (ans.num(ans.field(options, "rate"))) |rate| {
            const r = AVSpeechUtteranceDefaultSpeechRate * @as(f32, @floatCast(rate));
            objc.msg(void, utterance, "setRate:", .{@min(@max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)});
        }
        objc.msg(void, sp, "speakUtterance:", .{utterance});
        return ans.none;
    }
    if (eql(name, "stop")) {
        _ = objc.msg(objc.BOOL, speaker(c), "stopSpeakingAtBoundary:", .{immediate});
        return ans.none;
    }
    if (eql(name, "pause")) {
        _ = objc.msg(objc.BOOL, speaker(c), "pauseSpeakingAtBoundary:", .{immediate});
        return ans.none;
    }
    if (eql(name, "resume")) {
        _ = objc.msg(objc.BOOL, speaker(c), "continueSpeaking", .{});
        return ans.none;
    }
    if (eql(name, "isSpeaking")) return .{ .value = .{ .bool = objc.msg(objc.BOOL, speaker(c), "isSpeaking", .{}) } };
    if (eql(name, "getVoices")) {
        const voices = allVoices();
        const Voice = struct { voiceName: []const u8, lang: []const u8, remote: bool = false, eventTypes: [2][]const u8 = .{ "start", "end" } };
        const out = try c.a.alloc(Voice, objc.msg(objc.NSUInteger, voices, "count", .{}));
        for (out, 0..) |*v, i| {
            const voice = objc.msg(objc.Object, voices, "objectAtIndex:", .{i});
            v.* = .{
                .voiceName = objc.fromNSString(objc.msg(?objc.Object, voice, "name", .{})),
                .lang = objc.fromNSString(objc.msg(?objc.Object, voice, "language", .{})),
            };
        }
        return try c.give(out);
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn allVoices() objc.Object {
    return objc.msg(objc.Object, objc.class("AVSpeechSynthesisVoice"), "speechVoices", .{});
}

/// The one synthesizer, made when first asked for.
fn speaker(c: *ans.Call) objc.Object {
    if (c.owner.answer.speaker) |sp| return sp;
    const sp = objc.new("AVSpeechSynthesizer");
    c.owner.answer.speaker = sp;
    return sp;
}
