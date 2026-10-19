import SwiftUI

// Ubi Chat: the AI add-on as you meet it, a column beside the page. One chat
// at a time in each window, kept on your own Macs only (Chats.swift, Sync.swift), a private
// tab's never. A question goes with the page in front unless its eye is
// closed and with the pages pinned to the chat, fenced as the websites'
// words to read and never as orders (see AIPage); anything in the answer the
// shared pages didn't have is pointed out. Answers show Markdown's emphasis
// and code, never a link to follow or a picture to fetch.
//
// A provider off this Mac is shown what it will be sent the first time it is
// used, before anything goes. A private tab's chat uses only what runs on
// this Mac.

/// Ubi Chat in one window: the chat on screen, the answer coming in, what is
/// typed. The chats themselves are Shared.chats'.
@MainActor
final class Assistant: ObservableObject {
    struct Notice: Equatable { let provider: AIProvider; let text: String }
    weak var browser: Browser?
    /// Opened on a private tab: only an AI on this Mac, and never written.
    let shy: Bool
    @Published var chat = Chat()
    /// The answer coming in, until it is done and joins chat.turns.
    @Published private(set) var live: Chat.Turn?
    @Published var draft = ""
    @Published private(set) var notice: Notice?
    /// A shared page has words addressed to an AI (see AIPage.addressesAI).
    @Published private(set) var addressed = false
    @Published var listing = false
    @Published var helpShown = false
    @Published private(set) var compacting = false
    private var waiting: String?
    private var task: Task<Void, Never>?
    private var compactor: Task<Void, Never>?
    private var compactRun = 0
    private var naming: Set<Chat.ID> = []
    static let longest = 32_000
    init(browser: Browser, shy: Bool) { self.browser = browser; self.shy = shy }
    var busy: Bool { live != nil }
    var canCompact: Bool {
        !busy && !compacting && chat.turns.count - min(chat.compacted ?? 0, chat.turns.count) > 2
    }
    var turns: [Chat.Turn] { chat.turns + (live.map { [$0] } ?? []) }

    static func place(_ provider: AIProvider, _ model: String) -> String {
        provider == .custom ? "on \(provider.host) · \(model)" : provider.isLocal ? "on this Mac · \(provider.name) · \(model)" : "sent to \(provider.name) · \(model)"
    }

    func shareable(_ tab: Tab?) -> Bool {
        guard let tab, !tab.isBlank,
              let scheme = tab.pageAddress?.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return false }
        return shy || !tab.isPrivatePage
    }

    var sharesPage: Bool { !chat.pageHidden && shareable(browser?.active) }

    var suggestions: [UbiChat.Suggestion] {
        if draft.hasPrefix("/"), !draft.contains(" ") {
            let prefix = draft.lowercased()
            return UbiChat.commands
                .filter { $0.name.hasPrefix(prefix) }
                .map { UbiChat.Suggestion(source: .command, title: $0.name, detail: $0.hint, url: nil) }
        }
        guard !draft.isEmpty, !draft.hasSuffix(" "),
              let browser, let word = draft.split(separator: " ").last
        else { return [] }
        let lower = word.lowercased()
        let sources: [UbiChat.Suggestion.Source]
        let query: String
        if lower.hasPrefix("@") {
            sources = [.tab, .bookmark, .history]
            query = String(lower.dropFirst())
        } else if lower.hasPrefix("tabs/") {
            sources = [.tab]
            query = String(lower.dropFirst(5))
        } else if lower.hasPrefix("bookmarks/") {
            sources = [.bookmark]
            query = String(lower.dropFirst(10))
        } else if lower.hasPrefix("history/") {
            sources = [.history]
            query = String(lower.dropFirst(8))
        } else {
            return []
        }
        return UbiChat.pages(matching: query, in: sources, browser: browser, except: Set(chat.pins.map(\.url)))
    }

    func submit() {
        if let first = suggestions.first { pick(first); return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.hasPrefix("/") { run(text); return }
        if ask(String(text.prefix(2000))) { draft = "" }
    }

    @discardableResult
    func ask(_ question: String) -> Bool {
        guard live == nil, !compacting, notice == nil, let browser, let ready = browser.readyAI() else { return false }
        let provider = ready.provider, model = ready.model
        if shy && !provider.staysOnThisMac {
            browser.announce("In a private tab, only an AI on this Mac")
            return false
        }
        if !provider.isLocal && !Store.settings.bool(forKey: "chat.told.\(provider.id)") {
            waiting = question
            notice = Notice(provider: provider, text: AIAssist.notice(for: provider))
            return true
        }
        send(question, provider: provider, model: model)
        return true
    }

    func agree() {
        guard let notice else { return }
        Store.settings.set(true, forKey: "chat.told.\(notice.provider.id)")
        self.notice = nil
        if let question = waiting {
            waiting = nil
            ask(question)
        }
    }

    func decline() {
        notice = nil
        if let waiting { draft = waiting }
        waiting = nil
    }

    func summarize() {
        chat.pageHidden = false
        guard shareable(browser?.active) else {
            browser?.announce("AI works on web pages")
            return
        }
        listing = false
        ask(UbiChat.summary)
    }

    private func send(_ question: String, provider: AIProvider, model: String) {
        helpShown = false
        let turn = Chat.Turn(question: question, place: Assistant.place(provider, model))
        live = turn
        let id = turn.id
        let from = min(chat.compacted ?? 0, chat.turns.count)
        let recap = from > 0 ? chat.summary : nil
        let earlier = Array(chat.turns[from...].filter { $0.done && $0.failed == nil && !$0.answer.isEmpty }.suffix(UbiChat.remembered(provider)))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let reads = await self.gather(budget: UbiChat.budget(provider))
            guard self.live?.id == id else { return }
            self.addressed = reads.contains { $0.addressed }
            let fence = AIPage.newFence()
            let system = UbiChat.system(fence: fence)
            var messages: [AIMessage] = []
            if let recap {
                messages += [
                    AIMessage(role: .user, text: UbiChat.recap + recap),
                    AIMessage(role: .assistant, text: "Understood."),
                ]
            }
            for old in earlier {
                messages.append(AIMessage(role: .user, text: old.question))
                messages.append(AIMessage(role: .assistant, text: old.answer))
            }
            messages.append(AIMessage(role: .user, text: UbiChat.opening(reads, question, fence: fence)))
            do {
                let key = provider.takesKey ? await AIKeys.key(for: provider) : nil
                let stream = AIClient.shared.stream(provider, model: model, system: system, messages: messages, key: key, maxTokens: 4096, thinking: 1024)
                for try await piece in stream {
                    guard self.live?.id == id else { return }
                    self.live?.answer += piece
                    if (self.live?.answer.count ?? 0) > Assistant.longest { break }
                }
                self.finish(id, nil, reads)
                if self.chat.turns.last?.id == id {
                    self.name(self.chat, provider: provider, model: model)
                }
            } catch {
                self.finish(id, error.localizedDescription, reads)
            }
        }
    }

    private func gather(budget: Int) async -> [AIPage.Read] {
        var reads: [AIPage.Read] = []
        var seen = Set<URL>()
        if sharesPage, let tab = browser?.active, let read = await AIPage.read(tab) {
            reads.append(read)
            if let url = tab.pageAddress { seen.insert(url) }
        }
        for pin in chat.pins where !pin.hidden && seen.insert(pin.url).inserted {
            if let tab = UbiChat.openTab(for: pin.url), let read = await AIPage.read(tab) {
                reads.append(read)
            } else {
                // ponytail: a pin not open in a tab goes as its title and address; read it in a hidden web view if that proves too thin
                reads.append(AIPage.Read(
                    title: pin.title,
                    url: pin.url,
                    text: "(This page isn't open in a tab: only its title and address are known.)",
                    links: [],
                    cut: false
                ))
            }
        }
        let share = budget / max(reads.count, 1)
        return reads.map { read in
            read.text.count > share
                ? AIPage.shaped(title: read.title, url: read.url, text: read.text, links: read.links, limit: share)
                : read
        }
    }

    private func finish(_ id: Chat.Turn.ID, _ failed: String?, _ reads: [AIPage.Read]) {
        guard var turn = live, turn.id == id else { return }
        turn.done = true
        turn.failed = failed
        live = nil
        chat.turns.append(turn)
        chat.touched = Date()
        keep()
        guard failed == nil, !reads.isEmpty else { return }
        let shared = AIPage.Read(
            title: reads.map(\.title).joined(separator: "\n"),
            url: nil,
            text: reads.map(\.text).joined(separator: "\n"),
            links: reads.flatMap(\.links) + reads.compactMap { $0.url?.absoluteString },
            cut: false
        )
        let answer = turn.answer
        let chatID = chat.id
        Task.detached(priority: .userInitiated) { [weak self] in
            let strays = AIPage.strays(in: answer, from: shared)
            guard !strays.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.edit(chatID) { chat in
                    if let index = chat.turns.firstIndex(where: { $0.id == id }) {
                        chat.turns[index].strays = strays
                    }
                }
            }
        }
    }

    private func keep() {
        if !shy, !chat.turns.isEmpty { Shared.chats.put(chat) }
    }

    func edit(_ id: Chat.ID, _ change: (inout Chat) -> Void) {
        if id == chat.id {
            change(&chat)
            keep()
        } else {
            Shared.chats.update(id, change)
        }
    }

    private func name(_ chat: Chat, provider: AIProvider, model: String) {
        guard !shy, chat.title.isEmpty, !naming.contains(chat.id),
              let first = chat.turns.first(where: { $0.done && $0.failed == nil && !$0.answer.isEmpty })
        else { return }
        let chatID = chat.id
        naming.insert(chatID)
        let question = first.question
        let answer = first.answer
        Task { @MainActor [weak self] in
            defer { self?.naming.remove(chatID) }
            guard let name = await UbiChat.name(question: question, answer: answer, provider: provider, model: model) else {
                return
            }
            if let self {
                self.edit(chatID) { if $0.title.isEmpty { $0.title = name } }
            } else {
                Shared.chats.update(chatID) { if $0.title.isEmpty { $0.title = name } }
            }
        }
    }

    func open(_ id: Chat.ID) {
        guard let found = Shared.chats.chat(id) else { return }
        stop()
        live = nil
        chat = found
        if let ready = browser?.quietAI(),
           let first = found.turns.first(where: { $0.done && $0.failed == nil && !$0.answer.isEmpty }),
           first.place == Assistant.place(ready.provider, ready.model)
        {
            name(found, provider: ready.provider, model: ready.model)
        }
    }

    func new(keepingPins: Bool = false) {
        stop()
        live = nil
        chat = Chat(pageHidden: keepingPins ? chat.pageHidden : false, pins: keepingPins ? chat.pins : [])
    }

    func rename(_ id: Chat.ID, to name: String) {
        edit(id) {
            $0.title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        }
    }

    func clone(_ id: Chat.ID) {
        guard !shy, var copy = (id == chat.id ? chat : Shared.chats.chat(id)) else { return }
        copy.id = UUID()
        copy.title = copy.label + " (copy)"
        copy.touched = Date()
        copy.starred = false
        copy.task = false
        Shared.chats.put(copy)
        open(copy.id)
    }

    func delete(_ id: Chat.ID) {
        Shared.chats.remove(id)
        if id == chat.id { new() }
    }

    func togglePage() {
        chat.pageHidden.toggle()
        keep()
    }

    func pinPage() {
        guard let tab = browser?.active, shareable(tab), !tab.isPrivatePage,
              let url = tab.pageAddress, !chat.pins.contains(where: { $0.url == url })
        else { return }
        chat.pins.append(ChatPin(title: tab.label, url: url))
        keep()
    }

    func togglePin(_ id: ChatPin.ID) {
        guard let index = chat.pins.firstIndex(where: { $0.id == id }) else { return }
        chat.pins[index].hidden.toggle()
        keep()
    }

    func unpin(_ id: ChatPin.ID) {
        chat.pins.removeAll { $0.id == id }
        keep()
    }

    func pick(_ suggestion: UbiChat.Suggestion) {
        if suggestion.source == .command {
            if suggestion.title == "/rename-ws" {
                draft = "/rename-ws "
            } else {
                run(suggestion.title)
            }
            return
        }
        guard let url = suggestion.url else { return }
        chat.pins.append(ChatPin(title: suggestion.title, url: url))
        var words = draft.split(separator: " ", omittingEmptySubsequences: false)
        if !words.isEmpty { words.removeLast() }
        draft = words.isEmpty ? "" : words.joined(separator: " ") + " "
        keep()
    }

    private func run(_ text: String) {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map { String($0).lowercased() } ?? ""
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        draft = ""
        switch name {
        case "/summarize":
            summarize()
        case "/clear":
            new(keepingPins: true)
        case "/clear-pins":
            chat.pins = []
            keep()
        case "/rename-ws":
            if rest.isEmpty {
                draft = "/rename-ws "
                browser?.announce("Type a name after /rename-ws")
            } else {
                chat.title = String(rest.prefix(80))
                keep()
            }
        case "/copy-workspace":
            UbiChat.copy(UbiChat.markdown(of: chat))
            browser?.announce("Chat copied")
        case "/help":
            helpShown = true
        case "/compact":
            compact()
        case "/clean-up":
            cleanUp()
        default:
            draft = text
            browser?.announce("No command \(name)")
        }
    }

    func compact() {
        guard !busy, !compacting, notice == nil, let browser, let ready = browser.readyAI() else { return }
        let provider = ready.provider, model = ready.model
        if shy && !provider.staysOnThisMac {
            browser.announce("In a private tab, only an AI on this Mac")
            return
        }
        if !provider.isLocal && !Store.settings.bool(forKey: "chat.told.\(provider.id)") {
            browser.announce("Ask \(provider.name) a question first")
            return
        }
        let start = min(chat.compacted ?? 0, chat.turns.count)
        let end = chat.turns.count - 2
        guard end > start else {
            browser.announce("Nothing to compact yet")
            return
        }
        let chatID = chat.id
        let turns = chat.turns
        var currentSummary = start > 0 ? chat.summary : nil
        let step = max(1, UbiChat.remembered(provider))
        compactRun += 1
        let run = compactRun
        compacting = true
        compactor = Task { @MainActor [weak self] in
            defer { if self?.compactRun == run { self?.compacting = false } }
            var idx = start
            while idx < end {
                if Task.isCancelled { return }
                let nextIdx = min(idx + step, end)
                let batch = Array(turns[idx..<nextIdx])
                do {
                    let nextSummary = try await UbiChat.compact(
                        summary: currentSummary, turns: batch, provider: provider, model: model
                    )
                    if Task.isCancelled { return }
                    currentSummary = nextSummary
                    if let self, self.chat.id == chatID {
                        self.chat.summary = nextSummary
                        self.chat.compacted = nextIdx
                        self.keep()
                    } else {
                        Shared.chats.update(chatID) {
                            $0.summary = nextSummary
                            $0.compacted = nextIdx
                        }
                    }
                    idx = nextIdx
                } catch {
                    self?.browser?.announce("Couldn't compact: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    func cleanUp() {
        guard !busy, !compacting else { return }
        func isBad(_ turn: Chat.Turn) -> Bool {
            turn.failed != nil || turn.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let fold = min(chat.compacted ?? 0, chat.turns.count)
        let badBefore = chat.turns.prefix(fold).filter(isBad).count
        let beforeCount = chat.turns.count
        chat.turns.removeAll(where: isBad)
        let removedTurns = beforeCount - chat.turns.count
        if chat.compacted != nil {
            let nextFold = max(0, fold - badBefore)
            if nextFold == 0 {
                chat.compacted = nil
                chat.summary = nil
            } else {
                chat.compacted = nextFold
            }
        }
        let empties = shy ? 0 : Shared.chats.sweepEmpty()
        if chat.turns.isEmpty {
            if !shy { Shared.chats.remove(chat.id) }
            new(keepingPins: true)
        } else if removedTurns > 0 {
            keep()
        }
        if removedTurns == 0 && empties == 0 {
            browser?.announce("Nothing to clean up")
        } else {
            browser?.announce("Removed \(removedTurns) failed turns and \(empties) empty chats")
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        compactRun += 1
        compactor?.cancel()
        compactor = nil
        compacting = false
    }
}

enum AIAssist {
    /// What a provider off this Mac is sent, said once, the first time it is
    /// used — and a word on what it does with it where that matters.
    static func notice(for provider: AIProvider) -> String {
        var text = "When you ask, Kea sends your question, the chat so far, and the text and addresses of the pages you share to \(provider.host)"
        text += provider == .openRouter ? ", which passes them to the model's provider." : "."
        text += " Their terms and privacy policy apply. Nothing is sent until you ask, and never from a private tab. Your chats are kept on this Mac, and on your other Macs if Sync carries them, sealed with your passphrase. You can delete them."
        switch provider {
        case .gemini:
            text += "\n\nOn Gemini's free tier, outside the EEA, Switzerland and the UK, Google may use this to improve its products, and people may read it. Don't use it on sensitive pages."
        case .openRouter:
            text += "\n\nKea asks OpenRouter to use only providers that keep nothing (zero data retention)."
        default:
            break
        }
        return text
    }
}

extension Browser {
    /// View › Ubi Chat: the column, opened or put away.
    func toggleChat() { if assisting != nil { closeAssistant() } else { openChat() } }
    @discardableResult
    func openChat() -> Assistant {
        if let assisting { return assisting }
        let made = Assistant(browser: self, shy: active?.isPrivatePage ?? false)
        assisting = made
        return made
    }
    func summarizePage() { openChat().summarize() }
    func closeAssistant() { assisting?.stop(); assisting = nil; if expandedPanel == .chat { expandedPanel = nil } }

    /// Where the AI runs, and with which model, once Settings has all it
    /// needs; otherwise Settings › AI opens, saying what is missing, and nil.
    func readyAI() -> (provider: AIProvider, model: String)? {
        guard prefs.ai, let provider = prefs.aiProvider else {
            settingsPage = .ai; tuning = true
            announce(prefs.ai ? "Choose where the AI runs" : "Turn on AI in Settings › AI")
            return nil
        }
        let model = prefs.aiModel(for: provider)
        guard !model.isEmpty else {
            settingsPage = .ai; tuning = true
            announce("Choose a model for \(provider.name)")
            return nil
        }
        guard provider.isLocal || AIKeys.hint(for: provider) != nil else {
            settingsPage = .ai; tuning = true
            announce("No key for \(provider.name) yet")
            return nil
        }
        return (provider, model)
    }

    func quietAI() -> (provider: AIProvider, model: String)? {
        guard prefs.ai, let provider = prefs.aiProvider else { return nil }
        let model = prefs.aiModel(for: provider)
        guard !model.isEmpty, provider.isLocal || AIKeys.hint(for: provider) != nil else { return nil }
        return (provider, model)
    }
}

// MARK: - the panel

struct AssistantPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var assistant: Assistant
    let onLeft: Bool
    var drawn = false
    /// nil: as wide as it is given — let out over the page, or in its own window
    var width: CGFloat? = Metrics.chat
    var expanded = false
    var popped = false
    @FocusState private var typing: Bool
    @State private var showEarlier = false
    @State private var roomy = false
    @State private var pinsFolded = false

    private var z: CGFloat { CGFloat(browser.prefs.chatZoom) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text(assistant.listing && !roomy ? "Chats" : assistant.chat.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !assistant.shy {
                    Door(icon: "sidebar.left", on: assistant.listing, help: "Chats") { assistant.listing.toggle() }
                }
                Door(icon: "square.and.pencil", help: "New Chat") {
                    assistant.new()
                    if !roomy { assistant.listing = false }
                }
                if !drawn, !popped {
                    Door(icon: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: expanded ? "Back to Sidebar Width" : "Expand") { browser.toggleExpanded(.chat) }
                }
                if !drawn {
                    PanelMenu(browser: browser, panel: .chat, onLeft: onLeft, popped: popped) {
                        if !assistant.shy {
                            Button("Rename\u{2026}") {
                                Ask.name("Rename Chat", placeholder: "Name", initial: assistant.chat.label, confirm: "Rename") {
                                    assistant.rename(assistant.chat.id, to: $0)
                                }
                            }
                            Button(assistant.chat.starred ? "Unstar" : "Star") {
                                assistant.edit(assistant.chat.id) { $0.starred.toggle() }
                            }
                            Button(assistant.chat.task ? "Mark Done" : "Make It a Task") {
                                assistant.edit(assistant.chat.id) { $0.task.toggle() }
                            }
                            Button("Clone") {
                                assistant.clone(assistant.chat.id)
                            }
                            Button("Compact Earlier Turns") {
                                assistant.compact()
                            }
                            .disabled(!assistant.canCompact)
                            Button("Clean Up") {
                                assistant.cleanUp()
                            }
                        }
                        Button("Copy Chat") {
                            UbiChat.copy(UbiChat.markdown(of: assistant.chat))
                        }
                        if !assistant.shy {
                            Divider()
                            Button("Delete Chat") {
                                assistant.delete(assistant.chat.id)
                            }
                        }
                        Divider()
                        Section("Zoom: \(Int((browser.prefs.chatZoom * 100).rounded()))%") {
                            Button("Zoom In") {
                                browser.prefs.setChatZoom(browser.prefs.chatZoom + 0.1)
                            }
                            .disabled(browser.prefs.chatZoom >= 2)
                            Button("Zoom Out") {
                                browser.prefs.setChatZoom(browser.prefs.chatZoom - 0.1)
                            }
                            .disabled(browser.prefs.chatZoom <= 0.5)
                            Button("Actual Size") {
                                browser.prefs.setChatZoom(1)
                            }
                        }
                        Divider()
                    }
                }
                Door(icon: "xmark", help: "Close   esc") { browser.closeAssistant() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .modifier(PanelHeaderGesture(browser: browser, panel: .chat, active: !drawn && !popped))

            if roomy {
                HStack(spacing: 0) {
                    if assistant.listing && !assistant.shy {
                        SessionList(assistant: assistant, chats: Shared.chats, drawn: drawn, roomy: true)
                            .frame(width: 220)
                        Rectangle().fill(Palette.hairline).frame(width: 1)
                    }
                    chatColumn
                }
            } else {
                if assistant.listing {
                    SessionList(assistant: assistant, chats: Shared.chats, drawn: drawn, roomy: false)
                } else {
                    chatColumn
                }
            }
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { roomy = g.size.width >= 600 }
                    .onChange(of: g.size.width) { _, w in roomy = w >= 600 }
            }
        )
        .frame(maxWidth: expanded ? 760 : .infinity)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.ground)
        .overlay(alignment: onLeft ? .trailing : .leading) {
            if width != nil {
                Rectangle().fill(Palette.hairline).frame(width: 1)
            }
        }
        .overlay(alignment: onLeft ? .trailing : .leading) {
            if width != nil, !drawn {
                EdgeHandle(width: Binding(get: { browser.prefs.chatWidth }, set: { browser.setPanelWidth(.chat, $0) }),
                           range: SidePanel.chat.range, standard: Metrics.chat, growsRight: onLeft)
            }
        }
        .onAppear { if !drawn { typing = true } }
        .onChange(of: assistant.chat.id) { _, _ in showEarlier = false }
    }

    @ViewBuilder
    private var chatColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if drawn {
                GeometryReader { _ in
                    conversation
                }
                .frame(maxHeight: .infinity)
                .clipped()
            } else {
                ScrollViewReader { scroller in
                    ScrollView(showsIndicators: false) {
                        conversation
                    }
                    .onChange(of: assistant.live?.answer) { _, _ in
                        if let last = assistant.turns.last { scroller.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onChange(of: assistant.chat.turns.count) { _, _ in
                        if let last = assistant.turns.last { scroller.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var composer: some View {
        let suggestions = assistant.suggestions
        let pins = assistant.chat.pins
        let hasText = !assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if !pins.isEmpty {
                if pinsFolded {
                    Button { pinsFolded = false } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Pins: \(pins.count)")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PINS")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Palette.muted)
                        let pinRows = VStack(alignment: .leading, spacing: 4) {
                            ForEach(pins) { pin in
                                HStack(spacing: 6) {
                                    Button { assistant.togglePin(pin.id) } label: {
                                        Image(systemName: pin.hidden ? "eye.slash" : "eye")
                                            .font(.system(size: 10))
                                            .foregroundStyle(pin.hidden ? Palette.faint : Palette.muted)
                                    }
                                    .buttonStyle(.plain)
                                    Text(verbatim: pin.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(pin.hidden ? Palette.faint : Palette.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button { assistant.unpin(pin.id) } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(Palette.muted)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if drawn {
                            pinRows
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                pinRows
                            }
                            .frame(maxHeight: min(CGFloat(pins.count) * 24, 108))
                        }
                        HStack(spacing: 12) {
                            Button("+ Add Pins\u{2026}") { addPins() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                            Button { pinsFolded = true } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 8, weight: .semibold))
                                    Text("Collapse")
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 2)
                    }
                }
            }

            HStack(spacing: 4) {
                Door(icon: assistant.chat.pageHidden ? "eye.slash" : "eye",
                     on: !assistant.chat.pageHidden,
                     help: "Share the page in front") { assistant.togglePage() }
                Text(pageLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if pins.isEmpty {
                    Door(icon: "plus", help: "Add Pins\u{2026}") { addPins() }
                }
                Door(icon: "pin", help: "Pin This Page") { assistant.pinPage() }
            }

            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions) { s in
                        Button { assistant.pick(s) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: s.source))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 14)
                                Text(verbatim: s.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(verbatim: s.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if drawn {
                Text("Ask, or type / or @…")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.faint)
            } else {
                TextField("", text: $assistant.draft, prompt: Text("Ask, or type / or @…").foregroundStyle(Palette.faint), axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .focused($typing)
                    .onSubmit { assistant.submit() }
                    .disabled(assistant.notice != nil)
            }

            HStack(spacing: 8) {
                ModelPicker(browser: browser, prefs: browser.prefs, drawn: drawn)
                Spacer(minLength: 0)
                if assistant.busy {
                    Door(icon: "stop.fill", help: "Stop") { assistant.stop() }
                } else {
                    Button { assistant.submit() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(hasText ? Palette.ink : Palette.faint)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasText || assistant.notice != nil)
                    .help("Send   \u{21A9}")
                }
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline))
        .padding(10)
    }

    private func addPins() {
        assistant.draft += (assistant.draft.isEmpty || assistant.draft.hasSuffix(" ")) ? "@" : " @"
        typing = true
    }

    private var pageLine: String {
        guard let tab = browser.active, !tab.isBlank else { return "No page in front" }
        if tab.isPrivatePage && !assistant.shy { return "Private tab — not shared" }
        if !assistant.shareable(tab) { return "Not a web page — not shared" }
        if assistant.chat.pageHidden { return "Not shared: \(tab.label)" }
        return tab.label
    }

    private func icon(for source: UbiChat.Suggestion.Source) -> String {
        switch source {
        case .command: return "slash.circle"
        case .tab: return "square.on.square"
        case .bookmark: return "bookmark"
        case .history: return "clock"
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let notice = assistant.notice {
                noticeCard(notice)
            }
            if assistant.shy {
                Text("A private tab's chat: only an AI on this Mac, and nothing is kept.")
                    .font(.system(size: 12 * z))
                    .foregroundStyle(Palette.muted)
            }
            if assistant.helpShown {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(UbiChat.commands, id: \.self) { cmd in
                            Text("\(cmd.name) — \(cmd.hint)")
                                .font(.system(size: 11.5 * z))
                                .foregroundStyle(Palette.ink)
                        }
                        Text("tabs/  bookmarks/  history/  @ — pin a page")
                            .font(.system(size: 11.5 * z))
                            .foregroundStyle(Palette.ink)
                    }
                    Spacer(minLength: 0)
                    Door(icon: "xmark", help: "Hide") { assistant.helpShown = false }
                }
                .padding(8)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if assistant.turns.isEmpty && assistant.notice == nil {
                Text("Ask anything.")
                    .font(.system(size: 13 * z, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("The page in front goes with your question unless you close its eye below. Type tabs/, bookmarks/, history/ or @ to pin more pages, and / for commands.")
                    .font(.system(size: 12 * z))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if assistant.sharesPage {
                    HStack(spacing: 6) {
                        ForEach(UbiChat.starters, id: \.self) { s in
                            Pill("✦ " + s.label) { assistant.ask(s.prompt) }
                        }
                    }
                }
            }
            if assistant.addressed && assistant.notice == nil {
                caution("This page has text written for an AI to follow. The answer may have been steered by it.")
            }
            let folded = min(assistant.chat.compacted ?? 0, assistant.chat.turns.count)
            if folded > 0 {
                Button { showEarlier.toggle() } label: {
                    HStack(spacing: 8) {
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                        Text("Earlier, compacted · \(folded) turns")
                            .font(.system(size: 11.5 * z))
                            .foregroundStyle(Palette.muted)
                            .fixedSize()
                        Image(systemName: showEarlier ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9 * z, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showEarlier {
                    if let summary = assistant.chat.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Summary")
                                .font(.system(size: 11.5 * z, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                            AnswerView(text: summary, zoom: z, drawn: drawn)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    ForEach(Array(assistant.chat.turns.prefix(folded))) { turn in
                        TurnView(turn: turn, zoom: z, drawn: drawn)
                            .opacity(0.75)
                            .id(turn.id)
                    }
                }
            }
            ForEach(Array(assistant.turns.dropFirst(folded))) { turn in
                TurnView(turn: turn, zoom: z, drawn: drawn).id(turn.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caution(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10 * z, weight: .medium))
            Text(verbatim: text).font(.system(size: 11.5 * z)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted)
        .padding(8)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func noticeCard(_ notice: Assistant.Notice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Answers from \(notice.provider.name)")
                .font(.system(size: 12.5 * z, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(verbatim: notice.text)
                .font(.system(size: 12 * z))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Pill("Continue", filled: true) { assistant.agree() }
                Pill("Cancel") { assistant.decline() }
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private struct TurnView: View {
        let turn: Chat.Turn
        var zoom: CGFloat = 1
        var drawn = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer(minLength: 40)
                    Text(verbatim: turn.question)
                        .font(.system(size: 12.5 * zoom))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if turn.answer.isEmpty, !turn.done {
                    Text("…").font(.system(size: 13 * zoom)).foregroundStyle(Palette.faint)
                }
                if !turn.answer.isEmpty {
                    AnswerView(text: turn.answer, zoom: zoom, drawn: drawn)
                }
                if let failed = turn.failed {
                    Text(verbatim: failed).font(.system(size: 12 * zoom)).foregroundStyle(Palette.muted)
                }
                if !turn.strays.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10 * zoom, weight: .medium))
                        Text(verbatim: "Not in the pages shared: " + turn.strays.joined(separator: ", "))
                            .font(.system(size: 11.5 * zoom))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Palette.muted)
                    .padding(8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                HStack {
                    Text("AI — may be wrong · \(turn.place)")
                        .font(.system(size: 10.5 * zoom))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if turn.done, !turn.answer.isEmpty {
                        Quick("Copy") { UbiChat.copy(turn.answer) }
                    }
                }
            }
        }
    }

    private struct SessionList: View {
        @ObservedObject var assistant: Assistant
        @ObservedObject var chats: Chats
        var drawn = false
        var roomy = false
        @State private var query = ""
        @State private var allStarred = false
        @State private var hovered: Chat.ID?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                    if drawn {
                        Text("Search chats")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.faint)
                    } else {
                        TextField("Search chats", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.top, 6)

                Button {
                    assistant.new()
                    if !roomy { assistant.listing = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                        Text("New Chat")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)

                if chats.index.isEmpty {
                    Text("No chats yet. They stay in the nest — on your own Macs only.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .padding(12)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if drawn {
                    VStack(alignment: .leading, spacing: 0) { rows }
                        .padding(.horizontal, 6)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) { rows }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        @ViewBuilder
        private var rows: some View {
            ForEach(Chats.sections(chats.index, query: query, allStarred: allStarred), id: \.title) { section in
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ForEach(section.items) { entry in
                    row(entry)
                }
                if section.title == "Starred" {
                    if section.more > 0 {
                        Button { allStarred = true } label: {
                            Text("Show all (\(section.more + section.items.count))")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    } else if allStarred && section.items.count > 5 {
                        Button { allStarred = false } label: {
                            Text("Show fewer")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        private func row(_ entry: Chats.Entry) -> some View {
            HStack(spacing: 6) {
                if entry.task {
                    Image(systemName: "list.clipboard")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                } else if entry.starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                }
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.task {
                    Door(icon: "checkmark", help: "Mark Done") {
                        assistant.edit(entry.id) { $0.task = false }
                    }
                } else if hovered == entry.id {
                    Menu {
                        rowActions(entry)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                } else {
                    Text(When.clock(entry.touched))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(entry.id == assistant.chat.id ? Palette.wash : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { over in
                if over { hovered = entry.id } else if hovered == entry.id { hovered = nil }
            }
            .onTapGesture {
                assistant.open(entry.id)
                if !roomy { assistant.listing = false }
            }
            .contextMenu {
                rowActions(entry)
            }
        }

        @ViewBuilder
        private func rowActions(_ entry: Chats.Entry) -> some View {
            Button("Rename\u{2026}") {
                Ask.name("Rename Chat", placeholder: "Name", initial: entry.title, confirm: "Rename") {
                    assistant.rename(entry.id, to: $0)
                }
            }
            Button(entry.starred ? "Unstar" : "Star") {
                assistant.edit(entry.id) { $0.starred.toggle() }
            }
            Button(entry.task ? "Mark Done" : "Make It a Task") {
                assistant.edit(entry.id) { $0.task.toggle() }
            }
            Button("Clone") {
                assistant.clone(entry.id)
            }
            Divider()
            Button("Delete Chat") {
                assistant.delete(entry.id)
            }
        }
    }

    private struct ModelPicker: View {
        @ObservedObject var browser: Browser
        @ObservedObject var prefs: Preferences
        var drawn = false

        private var labelText: String {
            guard let provider = prefs.aiProvider else { return "Choose an AI" }
            let m = prefs.aiModel(for: provider)
            return m.isEmpty ? "Choose an AI" : m
        }

        var body: some View {
            HStack(spacing: 4) {
                if drawn {
                    Text(labelText)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                } else {
                    Menu {
                        if let provider = prefs.aiProvider {
                            let current = prefs.aiModel(for: provider)
                            ForEach(UbiChat.models(for: provider, current: current), id: \.self) { model in
                                Button(model) { prefs.setAIModel(model, for: provider) }
                            }
                            Divider()
                        }
                        Button("Choose Provider…") {
                            browser.settingsPage = .ai
                            browser.tuning = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(labelText)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 7.5))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(prefs.aiProvider?.name ?? "")
                }
            }
        }
    }
}

struct AnswerView: View {
    let text: String
    var zoom: CGFloat = 1
    var drawn = false

    var body: some View {
        let parsed = Markdown.blocks(text)
        VStack(alignment: .leading, spacing: 10 * zoom) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { _, item in
                block(item, depth: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18 * zoom
        case 2: return 16 * zoom
        case 3: return 14.5 * zoom
        default: return 13 * zoom
        }
    }

    @ViewBuilder
    private func block(_ b: Markdown.Block, depth: Int) -> some View {
        switch b {
        case let .heading(level, content):
            Text(Markdown.shown(content))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(content):
            Text(Markdown.shown(content))
                .font(.system(size: 13 * zoom))
                .foregroundStyle(Palette.ink)
                .lineSpacing(2.5 * zoom)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 5 * zoom) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, itemBlocks in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(start + i)." : ["•", "◦", "▪"][min(depth, 2)])
                            .font(.system(size: 13 * zoom).monospacedDigit())
                            .foregroundStyle(Palette.muted)
                            .frame(minWidth: 14 * zoom, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 6 * zoom) {
                            ForEach(Array(itemBlocks.enumerated()), id: \.offset) { _, sub in
                                AnyView(block(sub, depth: depth + 1))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .quote(inner):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Palette.faint)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6 * zoom) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, sub in
                        AnyView(block(sub, depth: depth + 1))
                    }
                }
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .table(header, rows):
            let grid = Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Markdown.shown(cell))
                            .font(.system(size: 12.5 * zoom, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Markdown.shown(cell))
                                .font(.system(size: 12.5 * zoom))
                                .foregroundStyle(Palette.ink)
                        }
                    }
                }
            }
            Group {
                if drawn {
                    grid
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        grid
                    }
                }
            }
            .padding(10)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .rule:
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)

        case let .code(language, codeText, closed):
            CodeBlock(language: language, text: codeText, closed: closed, zoom: zoom, drawn: drawn)
        }
    }
}

private struct CodeBlock: View {
    let language: String
    let text: String
    let closed: Bool
    var zoom: CGFloat = 1
    var drawn = false
    @State private var copied = false
    @State private var source = false

    var body: some View {
        let diagram = (language == "mermaid" && closed && !source) ? Mermaid.diagram(text) : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "Code" : language)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                if language == "mermaid" {
                    Door(
                        icon: source ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right",
                        help: source ? "Show Diagram" : "Show Code"
                    ) {
                        source.toggle()
                    }
                }
                Quick(copied ? "Copied" : "Copy") {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }
            }
            if let diagram {
                let view = DiagramView(diagram: diagram, zoom: zoom)
                    .frame(maxWidth: .infinity)
                if drawn {
                    view
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        view
                    }
                }
            } else {
                let codeView = Text(language == "mermaid" ? Mermaid.highlighted(text) : AttributedString(text))
                    .font(.system(size: 12 * zoom, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if drawn {
                    codeView
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        codeView
                    }
                }
            }
        }
        .padding(10)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

// MARK: - Settings › AI

struct AISettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// Drawn off screen, for a picture: menus and fields stood in for.
    var drawn = false
    @State private var pasted = ""
    /// A variable's name or a command being typed, not yet in use.
    @State private var typed = ""
    @State private var hint: String?
    @State private var source = AIKeySource.keychain
    @State private var kind = Kind.keychain
    private enum Kind: Hashable { case keychain, variable, command }
    @State private var server = ""
    @State private var models: [String] = []
    @State private var looking = false
    /// Watched so the list of providers redraws when the catalog arrives.
    @ObservedObject private var catalog = AICatalog.shared

    private var choices: [AIProvider] { AIProvider.all }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Use AI on pages", "Summarize a page, or open Ubi Chat, from the View menu. Nothing is sent until you ask") {
                    Switch(on: $prefs.ai)
                }
            }
            if prefs.ai {
                Card {
                    Line("Where it runs", place) {
                        if drawn {
                            Stand(prefs.aiProvider?.label ?? "Choose…", menu: true)
                        } else {
                        Picker("", selection: Binding(get: { prefs.aiProvider }, set: { prefs.aiProvider = $0 })) {
                            Text("Choose…").tag(AIProvider?.none)
                            ForEach(choices) { provider in
                                if provider == choices.first(where: { !AIProvider.builtIns.contains($0) }) { Divider() }
                                Text(provider.label)
                                    .tag(AIProvider?.some(provider))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        }
                    }
                    if let provider = prefs.aiProvider {
                        Rule()
                        if provider == .custom { serverRow; Rule(); key(provider); Rule(); localModel(provider) } else if provider.isLocal { localModel(provider) } else { key(provider); Rule(); cloudModel(provider) }
                    }
                }
                .onChange(of: prefs.aiProvider) { _, _ in
                    // A key typed for one provider is never saved for another.
                    pasted = ""
                    typed = ""
                    refresh()
                }
                .onAppear {
                    catalog.refreshIfStale()
                    refresh()
                }
                Card {
                    Line("Forget every key", "Deletes them from this Mac's keychain. A key made by signing in with OpenRouter still works until you delete it on openrouter.ai") {
                        Pill("Forget") {
                            AIKeys.forgetAll()
                            refresh()
                            browser.announce("Keys forgotten")
                        }
                    }
                }
            }
        }
    }

    private var place: String {
        guard let provider = prefs.aiProvider else { return "A provider you have a key with, or a server on this Mac or your network" }
        if provider == .custom {
            return provider.staysOnThisMac
                ? "Nothing leaves this Mac. Also in private tabs"
                : "Sent only to \(provider.host), on your network. Never from a private tab"
        }
        return provider.isLocal
            ? "Nothing leaves this Mac. Also in private tabs"
            : "Your key, sent only to \(provider.host). Never from a private tab"
    }

    private var serverRow: some View {
        Line("Address", "An OpenAI-compatible server — llama-server, vLLM, Jan… — on this Mac or your network") {
            HStack(spacing: 6) {
                field(prefs.aiServer, $server, width: 150) { useServer() }
                Pill("Use") { useServer() }
            }
        }
    }

    private func useServer() {
        guard let url = LocalNetwork.server(from: server) else { browser.announce("Use an address on this Mac or your network"); return }
        prefs.aiServer = url.absoluteString
        server = ""
        refresh()
    }

    @ViewBuilder
    private func key(_ provider: AIProvider) -> some View {
        Line("Key from", "Where Kea finds it when you ask") {
            Segmented(options: [(Kind.keychain, "Keychain"), (.variable, "Variable"), (.command, "Command")], selection: $kind)
        }
        Rule()
        switch kind {
        case .keychain:
            if source == .keychain, let hint {
                Line("Key", "\(hint), in your keychain") {
                    Pill("Forget") {
                        AIKeys.forget(provider)
                        refresh()
                    }
                }
            } else {
                Line("Key", provider == .custom ? "Only if your server asks for one" : provider == .openRouter ? "Paste one, or sign in and OpenRouter makes one for you" : "Paste your API key") {
                    HStack(spacing: 6) {
                        if drawn {
                            Stand("Key", width: 130)
                        } else {
                            SecureField("", text: $pasted, prompt: Text("Key").foregroundStyle(Palette.faint))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .frame(width: 130)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .onSubmit { save(provider) }
                        }
                        Pill("Save") { save(provider) }
                        if provider == .openRouter {
                            Pill("Sign In…") {
                                browser.tuning = false
                                AISignIn.start(in: browser)
                            }
                        }
                    }
                }
            }
        case .variable:
            if case .environment(let name) = source {
                Line("Key", "From $\(name)") { forgetPill(provider) }
            } else {
                Line("Key", "A variable that holds it, read when you ask") {
                    HStack(spacing: 6) {
                        field(provider.env.first ?? "API_KEY", $typed, width: 150) { useVariable(provider) }
                        Pill("Use") { useVariable(provider) }
                    }
                }
            }
        case .command:
            if case .command = source {
                Line("Key", "From a command") { forgetPill(provider) }
            } else {
                Line("Key", "A command that prints it, run by your shell when you ask") {
                    HStack(spacing: 6) {
                        field("op read op://Private/Gemini/credential", $typed, width: 200) { useCommand(provider) }
                        Pill("Use") { useCommand(provider) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ prompt: String, _ text: Binding<String>, width: CGFloat, submit: @escaping () -> Void) -> some View {
        if drawn {
            Stand(text.wrappedValue.isEmpty ? prompt : text.wrappedValue, width: width)
        } else {
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: width)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onSubmit(submit)
        }
    }

    private func forgetPill(_ provider: AIProvider) -> some View {
        Pill("Forget") {
            AIKeys.forget(provider)
            refresh()
        }
    }

    private func useVariable(_ provider: AIProvider) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIKeys.isVariableName(name) else { browser.announce("Not a variable name"); return }
        AIKeys.setSource(.environment(name), for: provider)
        typed = ""
        refresh()
    }

    private func useCommand(_ provider: AIProvider) {
        let command = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        AIKeys.setSource(.command(command), for: provider)
        typed = ""
        refresh()
    }

    private func cloudModel(_ provider: AIProvider) -> some View {
        Line("Model", provider.suggested.isEmpty ? "Choose one, or type its name" : "Leave empty for \(provider.suggested)") {
            if drawn {
                Stand(prefs.aiModels[provider.id].flatMap { $0.isEmpty ? nil : $0 } ?? provider.suggested, width: 170)
            } else {
                HStack(spacing: 6) {
                    TextField("", text: Binding(get: { prefs.aiModels[provider.id] ?? "" },
                                                set: { prefs.setAIModel($0, for: provider) }),
                              prompt: Text(provider.suggested).foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 170)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    modelMenu(provider)
                }
            }
        }
    }

    /// The models to pick from: what the provider listed when asked, else the catalog's.
    private func modelMenu(_ provider: AIProvider) -> some View {
        Menu {
            ForEach(models.isEmpty ? AIProvider.all.first { $0.id == provider.id }?.models ?? [] : models, id: \.self) { model in
                Button(model) { prefs.setAIModel(model, for: provider) }
            }
            Divider()
            Button("Fetch From \(provider.name)") {
                Task { @MainActor in
                    let key = await AIKeys.key(for: provider)
                    models = await AIClient.shared.models(provider, key: key)
                    if models.isEmpty { browser.announce(key == nil ? "No key for \(provider.name)" : "\(provider.name) listed no models") }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// A menu or a field, as a picture shows it.
    private struct Stand: View {
        let text: String
        var menu = false
        var width: CGFloat?
        init(_ text: String, menu: Bool = false, width: CGFloat? = nil) { self.text = text; self.menu = menu; self.width = width }
        var body: some View {
            HStack(spacing: 5) {
                Text(text).font(.system(size: 12)).foregroundStyle(menu ? Palette.ink : Palette.faint)
                if menu { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted) }
            }
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(menu ? Palette.ground : Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(menu ? Palette.hairline : .clear, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func localModel(_ provider: AIProvider) -> some View {
        if models.isEmpty {
            Line("Model", provider == .custom ? (looking ? "Asking \(provider.host)…" : "Nothing answered at \(provider.host), or it has no model yet") : (looking ? "Asking \(provider.name)…" : "\(provider.name) isn't running, or has no model yet")) {
                Pill("Look Again") { refresh() }
            }
        } else {
            Line("Model", provider == .custom ? "From \(provider.host)" : "From \(provider.name) on this Mac") {
                Picker("", selection: Binding(get: { prefs.aiModel(for: provider) }, set: { prefs.setAIModel($0, for: provider) })) {
                    Text("Choose…").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private func save(_ provider: AIProvider) {
        let key = pasted
        pasted = ""
        switch AIKeys.save(key, for: provider) {
        case .kept: browser.announce("Key kept in the keychain")
        case .failed: browser.announce("The key wasn't kept")
        }
        refresh()
    }

    /// Looked at when the page is: a local app is asked for its models only
    /// now, never in the background.
    private func refresh() {
        guard let provider = prefs.aiProvider else { return }
        hint = provider.takesKey ? AIKeys.hint(for: provider) : nil
        source = AIKeys.source(for: provider)
        kind = switch source {
        case .keychain: .keychain
        case .environment: .variable
        case .command: .command
        }
        models = []
        guard provider.isLocal else { return }
        looking = true
        Task { @MainActor in
            let key = provider.takesKey ? await AIKeys.key(for: provider) : nil
            models = await AIClient.shared.models(provider, key: key)
            looking = false
        }
    }
}
