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
