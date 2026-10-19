# Investigating Kea on Zig + `nanoui`

## 1. Executive Summary

- **WebKit stays the web engine:** Neither `nanoui` nor `GPUI` includes an HTML/CSS/JS rendering engine. On macOS, `nanoui` embeds `WKWebView` directly via the Objective-C runtime (`src/page.zig`). Re-implementing Kea on `nanoui` means replacing the **browser shell and chrome UI** (currently SwiftUI + AppKit bridges) with `nanoui`'s GPU-drawn immediate-mode UI while keeping `WKWebView` for page rendering.
- **Why `nanoui` is faster for browser chrome:** `nanoui` builds an immediate-mode flexbox tree in a per-frame arena (`src/ui/context.zig`), shapes text once into a CoreText glyph/SF Symbol atlas (`src/ui/atlas.zig`), and renders the entire window chrome (rounded rects, borders, glyphs, images, analytical Gaussian shadows, and Liquid Glass) in **one instanced Metal draw call per frame** (`src/ui/metal.zig`, ~0.015–0.315 ms CPU/frame, 0% idle CPU). This eliminates SwiftUI's `AttributeGraph` invalidation cascades and `NSViewRepresentable` layout thrashing during panel drags and live window resizes.

---

## 2. Codebase Findings & Hard Technical Constraints in `justrach/nanoui`

Inspection of `justrach/nanoui` (`main`) surfaced six concrete constraints that govern any Kea implementation:

### 2.1 Window Composition (`Window.Content` is an exclusive union today)
- In `src/window_types.zig` and `src/window.zig:60-63`, a `nanoui.Window` holds **either** `.page` (a single full-window `WKWebView` in `src/page.zig`) **or** `.view` (a single full-window Metal `Surface` in `src/ui/surface.zig`), never both.
- In `src/ui/metal.zig:63` and `:247`, `Renderer` configures `CAMetalLayer` with `setOpaque(objc.YES)` and clears the render pass attachment with `ClearColor{ .r = c.r, .g = c.g, .b = c.b, .a = 1 }`.
- **Required change for a browser:** A browser window must show `nanoui`-drawn chrome (sidebar, top strip, omnibox dropdown, find bar, modal plates, toasts, Ubi Chat) **and** 1–2 live `WKWebView` panes (plus an optional `Peek` webview) simultaneously.
  - Place `PageStageView` (`NSView` hosting active `WKWebView` slots) at the back of `NSWindow.contentView`, and `NanoUIView` (`Surface.nsview`) in front of it.
  - Set `CAMetalLayer.setOpaque(objc.NO)` and `ClearColor{ .r = 0, .g = 0, .b = 0, .a = 0 }` when a transparent viewport hole is active, and leave the root `Node`'s background unset over the stage rect(s).
  - Because `NanoUIView` already declares `isFlipped = YES` (`src/ui/surface.zig:255`), the flexbox layout rect `c.rects.get(pane_id)` maps 1:1 in top-left window points to `WKWebView.setFrame:` inside the same run-loop turn.
  - Override `hitTest:` on `NanoUIView` so unobstructed stage rects (`c.hot == 0` or hit node is a stage placeholder) return `nil`, letting AppKit route mouse clicks, hover, trackpad momentum scrolling, pinch-zoom, and context menus directly to the underlying `WKWebView`.

### 2.2 No Accessibility in `nanoui`
- `nanoui`'s `README.md` (`:419-421`) explicitly notes: *"there's no accessibility, bundling, notifications, channels or plugins yet."*
- `NanoUIView` (`src/ui/surface.zig`) implements `NSTextInputClient` for IME, but exposes zero `NSAccessibility` elements for buttons, tabs, splitters, switches, or segmented controls.
- **Impact on Kea:** Kea's VoiceOver support (tab roles, `PaneDivider` / `EdgeStripView` splitters, `Switch` / `Segmented` representations, toast announcements) would regress unless we synthesize `NSAccessibilityElement` children from `Context.hits` / `Context.nodes` on `NanoUIView`.

### 2.3 `objc.Block` 2-Argument Limit
- `src/objc.zig:207-247` implements Apple's ABI blocks (`_NSConcreteStackBlock`) for completion handlers, but hard-stops at 2 arguments (`else => @compileError("objc.Block: up to 2 arguments")`).
- **Impact on Kea:** WebKit and system APIs used by Kea require 3-argument blocks or specific non-object block parameter encodings (e.g., `WKNavigationDelegate` policy decision blocks with `WKWebpagePreferences`, `NSAnimationContext`, `SecItem` / `ASAuthorizationController` callbacks). `objc.Block` in `src/objc.zig` must be extended to support 3–4 arguments and non-void return types where needed.

### 2.4 Linux & Windows Webviews Do Not Exist Yet in `nanoui`
- `nanoui` supports Linux (GTK 3 + CPU rasterizer) and Windows (Win32 + CPU rasterizer) for **Native UI**, but `page.zig` (`WKWebView`) is macOS-only (`README.md:353`). Moving Kea to `nanoui` does not automatically make Kea cross-platform without writing WebKitGTK / WebView2 backends.

### 2.5 Line-Count Discipline (`<= 600` lines per file)
- `nanoui` enforces a strict 600-line ceiling per file (`zig build lines`). Kea's current Swift codebase is **57,637 lines across 86 files**, with 15 files exceeding 600 lines (topped by `Browser.swift` at 5,173 lines, `ExtensionShims.swift` at 4,449 lines, and `Bench.swift` at 3,608 lines). Any Zig port must decompose those monoliths by responsibility.

### 2.6 Toolchain Prerequisite
- `nanoui` targets **Zig 0.17.0** (`std.process.Init`, `std.Io`, `@Fn`). Zig is not currently installed on this workstation (`which zig` returns nothing) and must be installed before building Phase 0.

---

## 3. Architectural Tradeoff: Full Zig Rewrite vs. Hybrid (`nanoui` Chrome + Swift WebKit Host)

| Dimension | Option A: Hybrid (`nanoui` static library in Swift Kea) | Option B: Full Zig + `nanoui` Rewrite |
|---|---|---|
| **Scope** | ~3,500 lines of Zig for hot chrome (`SideBar`, `TabBar`, `Omnibox`, `SidePanels`, `Find`), linked into `Package.swift` as a `libnanoui_chrome.a` C-ABI target. | Port all ~57.6k lines of Swift (`Browser`, `Tab`, `Extensions`, `ExtensionShims`, `Passkeys`, `Vault`, `Sync`, `AIAssist`, `Bench`) to Zig. |
| **Risk** | **Low.** Keeps battle-tested Swift implementations of `WKWebExtensionController` (6.4k lines), `Passkeys`/`Vault` (1.5k lines), `Sync` (1.5k lines), and `Import` (2k lines). | **High.** Re-implementing 4,449 lines of `ExtensionShims.swift` and 1,159 lines of `Passkeys.swift` via raw `objc.msg` is months of high-surface-area work with zero speed gain (extensions and passkeys are I/O-bound, not UI-bound). |
| **Performance** | Captures **95%+ of the UI speed win**: 0-cascade Metal rendering for tab bars, sidebar, omnibox, and panel edge drags. | Captures 100% of the UI speed win + smaller binary (~1–2 MB vs ~7 MB) and faster process startup. |
| **Testability** | Existing `./bench` and all Python suites (`Tests/*.py`) keep running without porting `Bench.swift` (3,608 lines). | Requires porting `Bench.swift`'s UNIX socket server before existing UI regression suites can run. |

**Recommendation:** Execute a **Phase-0 Spike** first that builds the hybrid `Surface` + `WKWebView` stage compositor in Zig (`nanoui`), measures frame/drag latency against the current Swift build, and exposes a clean C ABI so it can either be embedded into the Swift app immediately (Option A) or serve as the foundation of a standalone Zig binary (Option B).

---

## 4. Implementation Plan

### Phase 0 — Toolchain & Hybrid Compositor Spike (Go/No-Go Gate)
1. **Install Zig 0.17.0** and vendor/fetch `justrach/nanoui` under `zig/`.
2. **Patch `nanoui` for Browser Hosting (`zig/src/stage_host.zig`):**
   - Add transparent-clear support to `metal.Renderer` (`setOpaque(NO)`, `ClearColor.a = 0`).
   - Implement `HostContentView` containing `PageStageView` (1–2 `WKWebView` slots + `Peek` slot) underneath `NanoUIView` (`Surface`).
   - Implement `NanoUIView.hitTest:` passthrough over unobstructed stage rects and synchronous `WKWebView.setFrame:` updates at the end of `Surface.frame()`.
3. **Build the Chrome Spike (`zig/src/chrome_spike.zig`):**
   - Render a 40-tab sidebar (`SideBar`), top toolbar, draggable Ubi Chat panel (`EdgeHandle`), and a floating Omnibox overlay over two split `WKWebView` panes.
4. **Measured Go/No-Go Gate:**
   - **Frame time:** 80-step panel edge drag with 40 visible tabs must keep median `Surface.frame()` CPU (`build_ms + layout_ms + paint_ms`) **< 0.30 ms** and GPU encode + render **< 0.50 ms** (measured via `Renderer.drawTimed` and `FrameStats`), with zero frame drops at 120 Hz.
   - **Input passthrough:** Trackpad scroll, text selection, IME input, and `WKWebView` context menus inside both split panes must work identically to native `PaneStage`, while an open Omnibox dropdown over the webview captures clicks and draws its Gaussian shadow over the live page.
   - **Decision point:** If `CAMetalLayer` (`opaque = NO`) over `WKWebView` exhibits WindowServer promotion/compositing artifacts with video or WebGL pages, switch the stage host to the split-surface layout (docked chrome `Surface`s around `PageStageView`, plus a transient `OverlaySurface` attached only while an overlay is open).

### Phase 1 — C-ABI Bridge into Swift Kea (Hybrid Cutover)
1. Export a C header (`include/kea_nanoui.h`) from Zig with:
   - `kea_chrome_create(NSWindow*, const KeaChromeCallbacks*)`
   - `kea_chrome_set_state(KeaChrome*, const KeaChromeSnapshot*)` (flat C structs for tabs, pins, groups, active IDs, omnibox offers, panel widths, and stage rects)
   - `kea_chrome_request_frame(KeaChrome*)`
2. Replace SwiftUI's `ContentView` (`SideBar`, `TabBar`, `Omnibox`, `Find`, `SidePanels`) with `kea_chrome_*` while keeping `Browser`, `Tab`, `History`, `Bookmarks`, `Sync`, `AIAssist`, `Extensions`, `Passkeys`, and `Bench` in Swift.
3. Verify all 11 UI test suites (`Tests/panels.py`, `split_view.py`, `ubi_chat.py`, `ubi_render.py`, `sync.py`, `fresh_window.py`, `bookmarks_manager.py`, `site_search.py`, `close_panel.py`, `tab_switcher.py`) pass without modification.

### Phase 2 — Accessibility & `objc.Block` Parity in `nanoui`
1. Extend `src/objc.zig` `objc.Block` to support 0–4 arguments and non-void return values.
2. Add an `NSAccessibility` bridge to `NanoUIView` (`src/ui/a11y.zig`, `<= 600` lines) mapping interactive `Node`s (buttons, text fields, splitters, switches, segmented pickers) to `NSAccessibilityElement` children so VoiceOver and automated accessibility queries work.

### Phase 3 — Core Data & Storage in Zig (If pursuing standalone Zig binary)
1. Port `Store` + `Disk` (`src/store.zig`), `Preferences` (`src/prefs.zig`), `History` (`src/history.zig`), `Bookmarks` (`src/bookmarks.zig`), `Session` / `Spaces` / `Pins` (`src/session.zig`), and `SiteSearch` (`src/site_search.zig`), preserving 100% on-disk JSON compatibility with `~/Library/Application Support/Kea/`.
2. Port `Tests/HistoryRegression` to `zig build test`.

### Phase 4 — Standalone WebKit Host, Bench Server, Sync & AI in Zig (Optional Full Cutover)
1. Port `Tab` + `Web.pool` (`src/tab.zig`), `Dialogs` (`src/dialogs.zig`), `Fetching` (`src/downloads.zig`), and `Bench`'s UNIX socket server (`src/bench/*.zig`).
2. Port `SyncCore` / `Sync` (`src/sync/*.zig`) using `std.crypto` (PBKDF2-HMAC-SHA256 + AES-256-GCM) and SigV4 S3 requests.
3. Port `AIClient`, `Chats`, `Markdown`, and `Mermaid` (`src/ai/*.zig`) rendering directly into `nanoui` primitives.
