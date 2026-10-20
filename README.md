<p align="center">
  <img src="Icon/kea.gif" width="440" alt="A pixel-art kea in flight">
</p>

<h1 align="center">Kea</h1>

<p align="center">
  <b>A small, cheeky Mac browser with nothing in the way.</b><br>
  Native WebKit · Zig + Metal · Contextual AI (Ubi Chat) · Chrome Extensions · Built from source.<br>
  <i>Named after New Zealand's alpine parrot — curious, quick, and hard to keep out of anything.</i>
</p>

<p align="center">
  <img src="Icon/screenshot.png" width="960" alt="Kea showing the tab sidebar, an article page, and Ubi Chat on the right">
</p>

---

## Why Kea?

Most browsers have become operating systems that want an account, a cloud sync, a start-page news feed, and a 300 MB Chromium binary. **Kea** is a ~5 MB native macOS app, written in Zig and drawn on the GPU with Metal, built on the **WebKit** engine already inside your Mac:

- **Nothing around the page.** A strip of tabs across the top or a column down the side (`⇧⌘S`), one address field (`⌘L`), and your page.
- **Ubi Chat (`⇧⌘Y`) — contextual AI on your terms.** Summarize the active page, pin multiple tabs/bookmarks/history items with `@` or `tabs/`, and chat against **Ollama**, **LM Studio**, any **Custom OpenAI-compatible server** on this Mac or your LAN (`llama-server`, `vLLM`, `Jan`), or cloud models (**Anthropic**, **OpenAI**, **Google Gemini**, **OpenRouter**, and the **models.dev** catalog).
- **Chrome extensions, without Chrome.** Install directly from the Chrome Web Store or load unpacked folders (`WKWebExtension` on macOS 15.4+, with Kea's native Chrome API shims).
- **DIY by design.** No installer binary, no background updater, no telemetry. You clone it, run `./build.sh`, and own the binary running on your machine.

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="Icon/new-tab.png" alt="Kea New Tab with sidebar, address field, and daily kea fact">
      <p align="center"><sub><b>New Tab:</b> one field and a daily fact about the bird (switchable in Settings › General).</sub></p>
    </td>
    <td width="50%" valign="top">
      <img src="Icon/home.png" alt="Kea reading Wikipedia with pinned tabs in the sidebar">
      <p align="center"><sub><b>Sidebar & Pins:</b> pinned tabs wear their site icons; sleeping tabs cost zero processes until clicked.</sub></p>
    </td>
  </tr>
</table>

---

## Build & Install

**Requirements:** macOS 14 or later (Chrome extensions need 15.4+); Zig 0.17.0 (`zig` on your `PATH`; `build.sh` also looks in `~/.local/bin`); and Apple's Command Line Tools (`xcode-select --install`) for the macOS SDK and `codesign`.

```sh
git clone https://github.com/matthiasak/kea.git
cd kea
./build.sh
```

`./build.sh` checks that every Zig file stays within 600 lines, compiles a ReleaseFast binary, strips symbols, adds the icon (`Icon/AppIcon.icns`, drawn from `Icon/kea.png`), signs the bundle (Developer ID if one is in your keychain, otherwise ad-hoc), and installs `/Applications/Kea.app`. Quit Kea first: the script won't replace a running copy.

To update later:

```sh
git pull && ./build.sh
```

| Command | What it does |
|---|---|
| `./build.sh` | Release build, installed to `/Applications/Kea.app` |
| `./build.sh debug` | Debug build, installed to `/Applications/Kea.app` |
| `./build.sh release test` | Builds `build/Kea.app` and stops without touching `/Applications` |
| `KEA_INSTALL=0 ./build.sh` | Same as `release test` |
| `KEA_SIGN_IDENTITY="…" ./build.sh` | Sign with a specific Developer ID identity |

---

## Features

### Browsing & Layout
- **One field (`⌘L`).** Type an address or search terms, or type `red` / `yout` + `Tab` to search a site directly via OpenSearch. Optional address bar commands (`settings`, `new tab`) take you straight there.
- **Tabs & Spaces.** Hold tabs across the top or in a left/right sidebar (`⇧⌘S`), fold the sidebar away (`⌘S`), group tabs, or separate work and personal sign-ins into isolated **Spaces** (`⌃1`–`⌃9`).
- **Split View (`⌥⌘N`).** Pair two pages side by side in one tab slot, drag the gutter to resize, and jump between panes with `⌃⌘←` and `⌃⌘→`.
- **Bookmarks sidebar (`⌃⌘B`), bar & manager (`⌥⌘B`).** Full bookmark manager with multi-select, batch move/delete, undo (`⌘Z`), and **Organize with AI**.
- **Reading mode (`⇧⌘R`) & Floating video (`⇧⌘P`).** Strip clutter to the article, or float a playing video over every space when you switch tabs or apps.
- **Peek (`Shift-click`) & Little Kea (`⌘O`).** Preview links in a sheet over the page; press `esc` to dismiss or keep them as a tab.

### Ubi Chat & AI (`⇧⌘Y`)
- **Multi-resource context.** Automatically reads the visible text of the active tab (toggleable via the eye icon) plus any tabs, bookmarks, or history pages you pin via `@`, `tabs/`, `bookmarks/`, or `history/`.
- **Hallucination guard.** Links or domains in an AI answer that weren't in the shared pages are flagged inline (`⚠ Not in the pages shared`).
- **Local, LAN, or Cloud.**
  - **On this Mac / LAN:** Ollama (`127.0.0.1:11434`), LM Studio (`127.0.0.1:1234`), or **Custom server** (any `http`/`https` OpenAI-compatible server on `localhost`, private RFC1918 IPv4, link-local, `.local`, or `.home.arpa`, with optional API key).
  - **Cloud:** Anthropic, OpenAI, Google Gemini, OpenRouter (one-click OAuth PKCE sign-in), plus providers from the `models.dev` catalog.
  - **Key sources:** Store keys in the macOS Keychain, read from an `$ENV_VAR`, or fetch on demand from a shell command (e.g. `op read …`).
- **Dual-format copy.** Copying an answer puts both rich HTML and clean Markdown on the pasteboard.
- **Sessions.** A list of chats beside the conversation (search, Starred, Tasks, by day) to rename, star, clone or delete; the model names each chat; Compact folds earlier turns into a summary and keeps them; answers render Markdown and Mermaid diagrams (flowchart, sequence, pie, state, class) drawn by Kea itself; the transcript zooms on its own (⋯ › Zoom).

### Privacy, Security & Extensions
- **Zero-cost ad blocking.** Compiles a `WKContentRuleList` enforced inside WebKit's network layer before requests leave the Mac. Toggle per site from the address bar's site card.
- **Hide anything (`⇧⌘H`).** Click cookie banners, overlays, or side rails to hide them permanently on that site via an injected document-start stylesheet.
- **Keychain passwords & Passkeys.** Saved logins live in your macOS login keychain tagged `Kea` and unlock with Touch ID; nothing is stored in plaintext on disk. One-click import from Chrome, Arc, Brave, Edge, Firefox, or Safari exports.
- **Chrome extensions (`macOS 15.4+`).** Click **Add to Kea** on any Chrome Web Store page or load an unpacked extension folder. Kea's own shims (`zig/src/ext/`) bridge `bookmarks`, `history`, `downloads`, `sidePanel`, `offscreen`, `tabGroups`, `userScripts`, `privacy`, `browsingData`, `tts`, `identity`, and native messaging.

---

## Where Everything Lives

| Data | Location | Access |
|---|---|---|
| Passwords | macOS login keychain (`Kea`) | Kea (via macOS Keychain / Touch ID) |
| AI API keys | Keychain (`app.kea.browser.ai`), `$ENV`, or shell command | Read only at request time; never logged or written to disk |
| Bookmarks, history, session, hidden rules, Ubi Chat | `~/Library/Application Support/Kea/*.json` (Ubi Chat: `Kea/chats/`, an index and a file per chat) | Local files on your Mac |
| Cookies & site storage | `~/Library/WebKit/app.kea.browser/` | WebKit's per-space data stores |
| Extensions | `~/Library/Application Support/Kea/Extensions/` | Each extension within its granted permissions |

---

## Keyboard Shortcuts

| Navigation & Tabs | Page, Panels & AI |
|---|---|
| `⌘L` Open address field | `⇧⌘Y` Open Ubi Chat (AI sidebar) |
| `⌘K` Switch tab by name | `⇧⌘R` Toggle Reading Mode |
| `⌘T` / `⇧⌘N` New tab / Private tab | `⇧⌘P` Float video (Picture-in-Picture) |
| `⌘W` / `⇧⌘T` Close / Reopen tab | `⇧⌘H` / `⇧⌘U` Hide element / Review hidden on site |
| `⇧⌘[` / `⇧⌘]` / `⌃Tab` Previous / Next tab | `⌃⌘B` / `⌥⌘B` Bookmarks sidebar / Bookmarks manager |
| `⌘1`–`⌘9` / `⌃1`–`⌃9` Jump to tab / Space | `⌘Y` / `⇧⌘J` / `⌥⌘L` History / Downloads / Passwords |
| `⇧⌘S` / `⌘S` Toggle sidebar / Fold sidebar | `⌘F` Find on page · `⇧⌘⌫` Clear browsing data |
| `⌥⌘N` / `⌃⌘←` `⌃⌘→` Split page / Focus split pane | `⇧⌘C` / `⇧⌘V` Copy address / Paste and go |

Every shortcut can be customized in **Settings › Shortcuts**.

---

## Architecture & Testing

`zig/src/` is ~86,000 lines of Zig 0.17 with no C or Objective-C files: AppKit and WebKit are reached through the Objective-C runtime. The interface is drawn by **nanoui** (`zig/nanoui/`, ~23,000 lines), an immediate-mode UI library with flexbox layout, a glyph atlas, springs and a Metal renderer (plus a CPU rasterizer for tests); pages are real `WKWebView`s showing through holes in it.

- `app/`: launch, windows, menus, keys, commands
- `model/`: a window's tabs, spaces and splits
- `chrome/`: strip, column, omnibox, sheets, settings, bookmarks
- `web/`: tabs and WebKit delegates, the page stage, favicons, downloads
- `data/`: store, prefs, history, bookmarks, session files
- `ai/`: Ubi Chat, providers, Markdown, Mermaid
- `ext/`: Chrome extensions and their API shims
- `passwords/`: keychain vault, passkeys, autofill
- `sync/`: your Macs in step, Send to Device
- `import/`: bringing things over from other browsers
- `design/`: palette, motion
- `sys/`: keychain, URLSession, CoreGraphics
- `tests/`: headless UI, WebKit end-to-end, perf, smoothness, snapshots

### Running Tests

```sh
export PATH="$HOME/.local/bin:$PATH"   # if Zig 0.17.0 isn't already on your PATH
(cd zig/nanoui && zig build test)      # nanoui: layout, text, Metal against the CPU rasterizer
cd zig
zig build lines       # every Zig file within 600 lines
zig build test        # unit tests
zig build ui-test     # the chrome, driven headless through ui.Tester
zig build e2e         # real WebKit in process, windows hidden (KEA_E2E=<text> runs matching cases)
zig build perf        # frame cost at scale (KEA_PERF_STRICT=1 enforces the gates)
zig build smooth      # on-screen 120 Hz smoothness; shows windows (KEA_SMOOTH=S4 runs one scenario)
zig build snapshots   # chrome states as PNGs in $KEA_SNAPSHOTS or $TMPDIR/kea-snapshots
```

Kea began as a Swift/SwiftUI app. That implementation was retired for this one and is in git history up to commit `85beef0` (`Sources/Kea/`); comments in `zig/src` that cite `*.swift` files point there.

---

## License

MIT. Kea began as a fork of an MIT-licensed Mac browser; the original copyright notice is kept in [LICENSE](LICENSE).
