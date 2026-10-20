# KeaZig parity audit (`research/zig-nanoui`)

Source-by-source (`Sources/Kea/*.swift` vs `zig/src/**`) and snapshot (`$TMPDIR/keazig-snapshots/p*-{light,dark}.png`) audit across every section of the Swift feature inventory. Open visible differences: **0**.

| State | Difference | Fix commit |
|---|---|---|
| Window layout / Fold — fullscreen video (`tab.immersed`) | Room kept strip, column, bars and frame ground during a fullscreen page; Fold lacked the `immersed` guard | `d09ae07` (`chrome/room.zig`, `chrome/window_view.zig`, `chrome/fold.zig`, `chrome/split_stage.zig`) |
| Top strip — sidebar toggle / ⌘S fold | Strip popped in/out without Swift's `.move(.top) + .opacity` on `Motion.glide` | `d09ae07` (`chrome/window_view.zig`) |
| Chrome cursor | `c.interact` set the pointing hand over pills, rows, doors, pins and group headings; Swift plain buttons keep the arrow | `d09ae07` (`nanoui/src/ui/context.zig` `hand_cursor`, `chrome/window_view.zig`) |
| Card — blank / asleep / floating tab (`p3-cards-*`, `p4-column-*`) | Card interior showed `Palette.frame` when no web view was present instead of `Palette.ground` | `d09ae07` (`chrome/window_view.zig`, `chrome/split_stage.zig`) |
| Strip pill — leaving tab | Leaving pill drew only the title text and skipped private/moved tabs; Swift animates the whole pill out on every removal | `d09ae07` (`chrome/tab_bar.zig`, `chrome/tab_leaving.zig`, `chrome/tab_pill.zig`) |
| Strip pill — inline address edit | Width change used `settle` instead of `Motion.glide` | `d09ae07` (`chrome/tab_bar.zig`) |
| Fold — shadow offset & bookmarks-close peek | FoldShadow lacked the ±4 pt horizontal offset; closing the bookmarks overlay while peeking waited for pointer move | `d09ae07` (`chrome/fold.zig`) |
| DragStrip double-click | Always zoomed instead of reading `AppleActionOnDoubleClick` (Minimize / None / Maximize) | `d09ae07` (`chrome/lights.zig`) |
| Omnibox — ⌘K summon | Did not clear `reviewing` (hidden-elements panel); site chip lacked its 0.9 scale-in | `d09ae07` (`model/omni.zig`, `chrome/omnibox_list.zig`) |
| Site card — zoom % | Steps percentage lacked tabular digits (`monospacedDigit`) | `d09ae07` (`chrome/site_card.zig`) |
| Model — `visit()` / `arrive()` | Reused the current tab without checking `!active.floating` | `d09ae07` (`model/browser_tabs.zig`) |
| Split divider — drag, snap haptic, hover curve | Kept press offset instead of centring the gutter; no alignment haptic on snap; linear tween instead of default ease-in-ease-out | `d09ae07` (`chrome/pane_divider.zig`) |
| Pane question card | Host truncated at tail instead of middle; message was not selectable | `d09ae07` (`chrome/page_layers.zig`, `nanoui` `truncate_middle`) |
| Tab switcher | Card click and scrim dismiss fired on mouse-down instead of mouse-up | `d09ae07` (`chrome/tab_switcher_view.zig`) |
| Settings › General / AI / Import — menu pickers | Drawn as a custom box instead of AppKit `NSPopUpButton` | `d09ae07` (`chrome/pop_up_button.zig`, `chrome/settings/general.zig`, `chrome/settings/ai.zig`, `import/panel.zig`) |
| Settings / Welcome / About — typography & leave | Keyword templates tail-truncated instead of middle; key chips in system font instead of SF Rounded; Welcome caption lacked 0.6 tracking; leaving Welcome page sat at top instead of centred; AI "Key from" line said "Kea" instead of "KeaZig" | `d09ae07` (`nanoui` `TextStyle.rounded`/`tracking`/`truncate_middle`, `chrome/settings/*.zig`, `chrome/welcome.zig`) |
| Settings / groups text fields with placeholders | Unkeyed placeholder drawn before the field shifted the field id after the first keystroke and dropped focus | `d09ae07` (`chrome/settings/general.zig`, `chrome/settings/ai.zig`, `passwords/passwords_panel.zig`, `chrome/groups_view.zig`) |
| Bookmarks — popovers, menu ⌘-click, manager | Dropdown/card lacked popover shadow; menu open ignored ⌘ for new tab; Organize menu had an extra Export item; tree ⇄ search and outline `shown` wash lacked `Motion.settle`; organizer used `Ring` instead of the small system spinner; found-row path tail-truncated | `d09ae07` (`chrome/window_view.zig`, `chrome/bookmarks/*.zig`, `chrome/spinner.zig`) |
| Ubi Chat & Markdown | "PINS" lacked 0.6 tracking; Mermaid source header scaled with zoom instead of staying 12 pt; table divider used `faint` instead of `separatorColor`; newline/whitespace splitting was ASCII-only | `d09ae07` (`ai/composer.zig`, `ai/markdown*.zig`, `ai/ubi_chat.zig`, `ai/whitespace.zig`) |
| ⌘W with Peek open | `closeFront` skipped `peekTab` and closed a panel or the underlying tab | `d09ae07` (`model/browser_closed.zig`) |
| ⌘D duplicate tab | Used a 2048-byte stack buffer for the URL instead of heap copy | `d09ae07` (`model/browser_tabs.zig`) |
| Passwords panel | Revealed secret not selectable; disclosure chevron swapped symbol instead of rotating 90° on settle; expand and Add form had no settle/opacity transition | `d09ae07` (`nanoui` `IconOptions.rotation`, `chrome/disclose.zig`, `passwords/passwords_panel.zig`) |
| Sheets stacking | Opening History/Downloads closed Settings instead of stacking independent sheet flags in `ContentView.panels` order | `d09ae07` (`chrome/sheet.zig`) |
| History, Downloads, Import panels & bars | History clearing foot switched without fade; row initials ASCII-only (`std.ascii.toUpper`); download and import-progress names tail-truncated instead of middle; capture/keep bars vanished without leave transition; file-import history merged in one batch instead of 200 per turn; image menu buffered before checking the 50 MB cap; sync folder chooser was a sheet instead of modal | `d09ae07` (`chrome/history_panel.zig`, `chrome/mark.zig`, `chrome/downloads_panel.zig`, `chrome/bars.zig`, `import/progress.zig`, `model/browser_import.zig`, `web/image_menu.zig`, `sync/settings_page.zig`) |
| Extensions — native errors, popup fade, popup-window exclusions | Native host spawn/write errors used generic strings instead of Foundation's; popup appeared without its 0.12 s alpha fade; notification target lookup and Move to Window included extension popup windows | `d09ae07` (`ext/native.zig`, `ext/popup.zig`, `web/notifications.zig`, `chrome/tab_menu.zig`) |
| StageHost / `KeepLine` | `StageHost` detached subviews owned by another window's stage (Float/Little); web view layer corners were circular instead of `.continuous`; `KeepLine`'s Clear button appeared without its `Motion.quick` fade | `c4fbd0f` (`web/stage_host.zig`, `chrome/side_rows.zig`) |

## Smoothness, idle cost, and leaks

- **Drag benchmark (`zig build perf`, 40 tabs, 80-step sidebar drag at 1440×900 @2×):** CPU median `0.109 ms`, p90 `0.463 ms` (gate `< 4.0 ms`); GPU median `0.761 ms`, p90 `1.505 ms`.
- **Idle blank tab (`quality.zig` e2e case, 3 s after settle):** `30.7 fps` (Breath capped at 30 fps), `1.66%` of one core (`50.0 ms` CPU over `3.00 s`), `0` heap allocations across 92 frames in both strip and sidebar layouts.
- **Leaks (`leaks --atExit` on `open and close 20 tabs`, plus the per-run `std.heap.DebugAllocator` check across all 48 e2e cases):** `0` leaked allocations attributable to `zig/src` or `zig/nanoui` frames.

## Polish baseline (P0, before P1–P7 fixes)

### 1. On-screen smoothness (`zig build smooth`, 120 Hz built-in display, ReleaseFast)

| # | Scenario | Frames | Anim | Missed % | Int p50 | Int p90 | Int p99 | Int max | CPU p50 | CPU p99* | CPU max* | Wait p99 | GPU p50 | GPU p99 | Sync % | Gate |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| S1 | Sidebar on/off x4 (slide plus room) | 684 | 684 | 1.2% | 8.34 | 8.96 | 13.69 | 20.87 | 0.25 | 0.68 | 1.12 | 10.68 | 1.28 | 4.23 | 100% | wait p99 10.68ms > 1ms |
| S2 | Open 5 tabs and close them (strip + column) | 1173 | 1172 | 1.9% | 8.33 | 9.16 | 15.73 | 1018.32 | 0.15 | 1.32 | 1.89 | 10.61 | 0.90 | 4.05 | 100% | wait p99 10.61ms > 1ms |
| S3 | Drag a tab across the strip at 120 Hz | 897 | 897 | 2.5% | 8.33 | 8.92 | 20.98 | 1009.37 | 0.15 | 0.52 | 2.03 | 14.92 | 0.33 | 1.09 | 100% | missed 2.5% > 2%; wait p99 14.92ms > 1ms |
| S4 | Split enter, swap, leave | 402 | 402 | 1.7% | 8.34 | 9.48 | 12.66 | 20.88 | 0.23 | 0.71 | 0.77 | 10.68 | 0.61 | 1.58 | 100% | wait p99 10.68ms > 1ms |
| S5 | Split divider drag | 260 | 191 | 16.3% | 6.02 | 1006.02 | 1008.34 | 1008.61 | 0.18 | 0.75 | 0.85 | 1005.86 | 0.64 | 1.65 | 100% | missed 16.3% > 2%; wait p99 1005.86ms > 1ms |
| S6 | Omnibox open, type 6 chars, Esc | 214 | 208 | 3.4% | 8.33 | 9.25 | 14.57 | 15.44 | 0.26 | 0.65 | 1.57 | 11.48 | 1.67 | 3.09 | 100% | missed 3.4% > 2%; wait p99 11.48ms > 1ms |
| S7 | Ubi Chat open, expand, edge drag 300->700 pt | 519 | 289 | 2.4% | 8.33 | 9.10 | 227.37 | 1008.75 | 0.24 | 1.16 | 2.96 | 1005.86 | 0.96 | 1.86 | 100% | missed 2.4% > 2%; wait p99 1005.86ms > 1ms |
| S8 | Fold peek/unpeek | 315 | 309 | 1.6% | 8.33 | 8.89 | 14.94 | 20.86 | 0.17 | 0.29 | 0.49 | 10.17 | 2.25 | 4.52 | 100% | wait p99 10.17ms > 1ms |
| S9 | Live window resize, 16 ms steps | 151 | 83 | 4.9% | 8.80 | 1007.09 | 1008.93 | 1008.93 | 0.14 | 0.42 | 0.67 | 1006.10 | 1.77 | 4.04 | 100% | REPORT |
| S10 | Scroll history (2000), bookmarks (2000), chat (200) | 802 | 561 | 98.2% | 28.51 | 29.24 | 34.27 | 1038.85 | 28.24 | 34.08 | 46.11 | 0.06 | 1.27 | 4.08 | 100% | missed 98.2% > 2%; cpu p99 34.08ms > 6ms; cpu max 46.11ms > 16ms |
| S11 | Mock-stream a 4 KB answer at 30 chunks/s | 131 | 0 | 0.0% | 31.67 | 34.74 | 40.19 | 40.93 | 0.57 | 1.09 | 1.55 | 4.19 | 0.53 | 1.32 | 100% | wait p99 4.19ms > 1ms |
| S12 | Loading tab with a ring (slow loopback reply) | 222 | 176 | 0.6% | 8.33 | 8.77 | 10.66 | 20.82 | 0.17 | 0.92 | 1.05 | 9.11 | 2.32 | 3.85 | 100% | wait p99 9.11ms > 1ms; fps 73.9 > 61 |
| S13 | Idle blank tab for 3 s | 271 | 0 | 0.0% | 33.25 | 35.02 | 35.38 | 35.42 | 0.20 | 0.35 | 1.58 | 0.08 | 0.66 | 1.36 | 100% | cpu 2.44% >= 2%; allocs 16 != 0 |

- **S12 extra:** `73.9 fps`, `0.00%` CPU, `0` steady allocations
- **S13 extra:** `30.1 fps`, `2.44%` CPU, `16` steady allocations

### 2. Performance at scale (`zig build perf`, 120 Hz Tester, ReleaseFast)

| Scenario | Cold CPU (ms) | CPU p50 (ms) | CPU p90 (ms) | CPU p99 (ms) | CPU max (ms) | GPU p50 (ms) | GPU p90 (ms) | Nodes | Steady Allocs/f (max) | Gate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1. Tabs hover-sweep & edge drag (200 tabs) | 13.81 | 3.72 | 7.82 | 7.89 | 8.05 | 0.49 | 2.97 | 1452 | 115.6 (499) | FAIL |
| 2. Bookmarks sidebar scroll & hover (2000) | 35.60 | 28.86 | 29.57 | 30.34 | 31.61 | 2.52 | 4.94 | 10476 | 8.6 (21) | FAIL |
| 3. Manager search type 1-5 chars (2000 bm) | 1.82 | 1.64 | 17.81 | 24.24 | 45.28 | 1.11 | 2.90 | 13287 | 258.0 (18158) | FAIL |
| 4. History panel open, scroll & hunt (2000) | 8.98 | 0.31 | 0.44 | 3.18 | 4.36 | 1.01 | 1.70 | 1756 | 28.0 (349) | FAIL |
| 5. Chat scroll, hover, resize & stream (200) | 35.41 | 6.78 | 7.03 | 8.42 | 11.01 | 1.07 | 2.71 | 17412 | 2.1 (42) | FAIL |
| 6. Chat list hover & search (300 chats) | 7.09 | 1.34 | 1.78 | 1.93 | 2.08 | 0.48 | 0.65 | 1470 | 0.4 (10) | FAIL |
| 7. Omnibox typing (2000 hist, 2000 bm, 200 tabs) | 10.69 | 7.28 | 7.41 | 7.73 | 8.37 | 1.45 | 2.31 | 1467 | 1.0 (36) | FAIL |
| 8. Composer @ and history/ (200 tabs, 2000 hist) | 18.56 | 7.85 | 8.05 | 9.27 | 13.42 | 1.24 | 2.32 | 1544 | 9.4 (209) | FAIL |
| 9. Settings > Shortcuts with search | 7.15 | 0.08 | 0.14 | 0.22 | 0.44 | 0.96 | 1.58 | 591 | 0.7 (42) | FAIL |
| 10. Downloads panel idle (50 kept + 3 active) | 4.60 | 0.37 | 0.38 | 0.43 | 0.43 | 0.96 | 1.66 | 581 | 0.0 (0) | PASS |
| 11. Ctrl+Tab switcher (120 candidates) | 14.27 | 8.75 | 8.91 | 9.21 | 9.26 | 1.80 | 3.18 | 1759 | 0.1 (1) | FAIL |

### 3. Reference compare and film baseline (`zig build compare`)

- **Snapshot compare (`/tmp/kea-ref` vs `$TMPDIR/keazig-snapshots`):** 27 state pairs compared in light and dark; differences dominated by circular vs `.continuous` corner curvature, glyph smoothing weight, un-snapped 1 pt hairlines, and sheet/panel hole masking.
- **Film motion compare (`film-peek`, `film-unpeek`, `film-fold`):**
  - `film-peek-light`: max $|\Delta x| = 98.00\text{ pt}$ (#2 at $t = 90\text{ ms}$)
  - `film-peek-dark`: max $|\Delta x| = 81.50\text{ pt}$ (#2 at $t = 100\text{ ms}$)
  - `film-unpeek-light`: max $|\Delta x| = 87.00\text{ pt}$ (#2 at $t = 119\text{ ms}$)
  - `film-unpeek-dark`: max $|\Delta x| = 71.00\text{ pt}$ (#1 at $t = 56\text{ ms}$)
  - `film-fold-light`: max $|\Delta x| = 76.00\text{ pt}$ (#2 at $t = 96\text{ ms}$)
  - `film-fold-dark`: max $|\Delta x| = 76.00\text{ pt}$ (#2 at $t = 95\text{ ms}$)
