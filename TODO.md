# TODO

## Recreate "The LLM Extension" ("Ubi Chat") — Local-Only Contextual AI Workspace

Recreate the **LLM Extension / Ubi Chat** experience natively in Kea using **local-device-only storage** (`Store.file(...)` under Application Support, zero server sync or telemetry) and the **same configured LLM connections** (`AIProvider`, `AIClient`, `AIKeys`, `AICatalog`) used by Page Summary (`AIAssist`) and Bookmark Organize (`AIBookmarks`).

### 1. Core Interface & Multi-View Architecture
- **Three View Modes** (switchable from the `⋯` menu in the chat header):
  1. **Side Panel (Default):** Docked browser side panel that persists across tab switches and can sit on the left or right side of the window.
  2. **Floating Window (PiP):** Always-on-top utility panel that floats above all application windows for multi-window / multi-monitor workflows.
  3. **Dedicated Browser Tab:** Full-width standalone tab view with expanded room for browsing workspaces, long outputs, code blocks, and diffs.
- **Navigation & Workspace Sidebar:**
  - Top navigation items: **Search** (across saved chats/messages), **Agents** (custom system prompts / personas, default **Ubi Chat**), and **Skills** (reusable prompt templates/workflows).
  - **Chats List:**
    - **Starred** section (collapsible, "Show all (N)").
    - **Tasks** section: Right-clicking a conversation or opening its `⋯` menu offers **"Make it a Task"**, moving it into a top `Tasks` section with a clipboard icon; hovering and clicking the check mark marks it done (`✓`) and returns it to the date-grouped history.
    - **Date-grouped history** (e.g., by day) with filter and new-workspace buttons.
  - **Empty / Welcome State:**
    - Quick-start instructions (toggle shortcut, `@` / `+` context attachment, `📌` multi-tab pinning).
    - **Quick Settings Model Cards:** One-click cards for configured/favorite models showing measured/estimated latency.
    - **Quick Action Chips:** Contextual starter pills above the composer (`✦ Summarize`, `✦ Create a diagram for this document`, `✦ Tutorial`).
- **Prompt Bar & Controls:**
  - **Activation Shortcuts:** Global/app toggle (`⇧⌘Y` / `⇧⌘X`, configurable in `Settings › Shortcuts`), plus configurable shortcuts for pinning the active tab and opening a new workspace.
  - **Model & Provider Selector:** Inline picker in the prompt bar backed by `prefs.aiProvider`, `prefs.aiModels`, and `AIProvider.all`, allowing one-click switching between fast and deep-reasoning models.
  - **Local Workstation / Code Bridge (`<> Code`):** Optional local command/workspace bridge toggle next to the model selector for running local builds, linters, or reading local project files.
  - **Slash Commands:** Typing `/` in the prompt field opens an autocomplete menu for actions: `/help`, `/rename-ws`, `/clear-pins`, `/copy-workspace`, `/summarize`, `/clear`.
- **Smart Clipboard (Dual-Format Copy):**
  - The copy button on an answer and standard selection copy (`⌘C`) write both **rich HTML** (`NSPasteboard.PasteboardType.html`) and **clean Markdown** (`.string`) to `NSPasteboard.general`, preserving headings, bold text, lists, tables, and code blocks in rich editors while pasting plain Markdown into code editors.

### 2. Context Gathering & Pinning
- **Active Browser Tab Awareness:**
  - Automatically extracts structured text and metadata from the active tab via `AIPage`.
  - **Eye Visibility Toggle:** Eye button in the context bar above the prompt to exclude/include the current active tab from the context payload.
- **Multi-Resource Pinning (`Pins: N 📌`):**
  - Persist reference pages, tabs, bookmarks, or local files across tab switches within a workspace; each pin can be individually toggled (eye icon) or removed.
  - **Ways to Pin:**
    - **Pin Button (`📌`)** in the context bar above the prompt box.
    - **Keyboard Shortcut** to pin the active tab immediately.
    - **Page Context Menu:** Right-clicking a page offers `Pin Page to Chat`.
    - **Past Conversational Links:** Clicking a resource link mentioned in earlier prompts pins it to the active workspace.
- **Autocomplete (`@`, `+`, and Prefix Triggers):**
  - Typing `@` or pressing `+`, or typing prefixes in the prompt bar, opens real-time local autocomplete:
    - `tabs/`: Search open and sleeping browser tabs (`Ctrl+P` or click pin icon to pin directly).
    - `bookmarks/`: Search saved bookmarks and folders from `Bookmarks`.
    - `history/`: Search visited pages from `History`.
    - `files/`: Attach or reference local files/directories chosen by the user.
- **Visual Screen Understanding:**
  - Capture button in the context bar snapshots the active `WKWebView` (`takeSnapshot`) and attaches the image for multimodal vision models.

### 3. Context Assembly, Normalization & Local Spooling
- **Context Assembly Hierarchy (per turn):**
  1. **Pinned Resources:** Always included in full unless hidden with the eye toggle.
  2. **Current Active Tab:** Included automatically unless hidden with the eye toggle.
  3. **Links in Questions:** URLs mentioned in user prompts are fetched/extracted and included.
  4. **Links in Model Answers:** URLs cited in prior assistant turns can be pulled in on follow-up questions when relevant.
  5. **Agentic Exploration Tools:** Model tool calls (`open_url`, `read_tab`, `search_bookmarks`, `search_history`, `grep_resource`, `read_resource`) to gather additional context on demand.
- **Resource Normalization:**
  - Convert HTML pages, tables, code views, and JSON/Markdown documents into clean structured Markdown/code extracts rather than raw DOM markup before sending to the model.
- **Context Window Protection & Ephemeral Local Spooling:**
  - Large pages, logs, or file outputs exceeding a token/byte threshold are spooled to local ephemeral storage rather than stuffed inline into the prompt; the model inspects slices via `grep_resource` and `read_resource(offset, limit)`.
- **Local-Only Storage & Privacy:**
  - All workspaces, chat turns, starred/task states, agents, skills, and pinned resources are stored strictly on-device in Kea's profile folder (`Store.file("chats.json")` / local SQLite or JSON).
  - Requests go directly from the Mac to the user's chosen `AIProvider` (or local Ollama / LM Studio / Custom server) using `AIClient` and `AIKeys`.
