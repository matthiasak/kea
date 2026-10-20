//! Kea's motion (`Motion`, Design.swift:181-199): one spring for what moves
//! between two places, one for what arrives or leaves, one short ease.
//! Under Reduce Motion each is its target at once (nanoui's motion does it).
const ui = @import("nanoui").ui;

pub const glide: ui.Spring = .{ .response = 0.34, .damping = 0.82 };
pub const settle: ui.Spring = .{ .response = 0.30, .damping = 0.86 };
pub const bounce: ui.Spring = .{ .response = 0.42, .damping = 0.68 };
pub const lift: ui.Spring = .{ .response = 0.24, .damping = 0.80 };
pub const live: ui.Spring = .{ .response = 0.36, .damping = 0.74 };
/// `.easeOut(duration: 0.14)`.
pub const quick_duration: f32 = 0.14;
pub const quick_curve: ui.Curve = .ease_out;

pub fn glideTo(c: *ui.Context, id: u64, salt: u32, target: f32) f32 {
    return ui.spring(c, id, salt, target, glide);
}

pub fn settleTo(c: *ui.Context, id: u64, salt: u32, target: f32) f32 {
    return ui.spring(c, id, salt, target, settle);
}

pub fn bounceTo(c: *ui.Context, id: u64, salt: u32, target: f32) f32 {
    return ui.spring(c, id, salt, target, bounce);
}

pub fn liftTo(c: *ui.Context, id: u64, salt: u32, target: f32) f32 {
    return ui.spring(c, id, salt, target, lift);
}

pub fn liveTo(c: *ui.Context, id: u64, salt: u32, target: f32) f32 {
    return ui.spring(c, id, salt, target, live);
}

pub fn quickTo(c: *ui.Context, id: u64, salt: u32, target: f32) f32 {
    return ui.tween(c, id, salt, target, quick_duration, quick_curve);
}
