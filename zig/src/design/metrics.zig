//! Kea's fixed sizes (`Metrics`, Design.swift:123-174), in points.

/// The tab strip; the title bar grows to match, bringing the lights down.
pub const strip: f32 = 52;
/// With the tabs down the side the page is a card this far from the edges.
pub const card_gap: f32 = 8;
pub const card_radius: f32 = 10;
/// Where the first tab starts: the traffic lights run from 19 to 79.
pub const lights: f32 = 100;
/// Back, forward and reload beside the bookmarks: three doors and the air.
pub const helm: f32 = 3 * 26 + 2 * 2 + 8;
/// The same three doors in the sidebar, right of the lights.
pub const side_lights: f32 = 72;
/// Tabs are a fixed width, giving way down to their mark alone.
pub const tab_width: f32 = 186;
pub const tab_titled: f32 = 80;
pub const tab_min_width: f32 = 36;
pub const tab_gap: f32 = 2;
/// A pinned tab: a square the height of the row.
pub const pin_width: f32 = 30;
/// The square at the end of the row that opens a new page.
pub const plus_width: f32 = 30;
/// The address field, in both the places it shows up.
pub const field_width: f32 = 560;
/// The column of titles down the side.
pub const side: f32 = 232;
pub const side_min: f32 = 176;
pub const side_max: f32 = 440;
/// Ubi Chat's column, until pulled wider or narrower.
pub const chat: f32 = 380;
pub const chat_min: f32 = 300;
pub const chat_max: f32 = 720;
/// The narrowest page the side panels leave in a small window.
pub const page_min: f32 = 320;
