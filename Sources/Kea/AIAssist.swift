import SwiftUI

// Ubi Chat: the AI add-on as you meet it, a column beside the page. One chat
// at a time in each window, kept on this Mac only (Chats.swift), a private
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
    private var waiting: String?
    private var task: Task<Void, Never>?
    static let longest = 32_000
    init(browser: Browser, shy: Bool) { self.browser = browser; self.shy = shy }
    var busy: Bool { live != nil }
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
        guard live == nil, notice == nil, let browser, let ready = browser.readyAI() else { return false }
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
        listing = false
        if chat.title.isEmpty { chat.title = String(question.prefix(60)) }
        let turn = Chat.Turn(question: question, place: Assistant.place(provider, model))
        live = turn
        let id = turn.id
        let earlier = Array(chat.turns.filter { $0.done && $0.failed == nil && !$0.answer.isEmpty }.suffix(UbiChat.remembered(provider)))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let reads = await self.gather(budget: UbiChat.budget(provider))
            guard self.live?.id == id else { return }
            self.addressed = reads.contains { $0.addressed }
            let fence = AIPage.newFence()
            let system = UbiChat.system(fence: fence)
            var messages: [AIMessage] = []
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
            await MainActor.run {
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

    func open(_ id: Chat.ID) {
        guard let found = Shared.chats.chat(id) else { return }
        stop()
        live = nil
        chat = found
        listing = false
    }

    func new(keepingPins: Bool = false) {
        stop()
        live = nil
        chat = Chat(pageHidden: keepingPins ? chat.pageHidden : false, pins: keepingPins ? chat.pins : [])
        listing = false
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
        default:
            draft = text
            browser?.announce("No command \(name)")
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

enum AIAssist {
    /// What a provider off this Mac is sent, said once, the first time it is
    /// used — and a word on what it does with it where that matters.
    static func notice(for provider: AIProvider) -> String {
        var text = "When you ask, Kea sends your question, the chat so far, and the text and addresses of the pages you share to \(provider.host)"
        text += provider == .openRouter ? ", which passes them to the model's provider." : "."
        text += " Their terms and privacy policy apply. Nothing is sent until you ask, and never from a private tab. Your chats are kept on this Mac only, and you can delete them."
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
    func closeAssistant() { assisting?.stop(); assisting = nil }

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
}

// MARK: - the panel

struct AssistantPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var assistant: Assistant
    let onLeft: Bool
    var drawn = false
    @FocusState private var typing: Bool
    static let width: CGFloat = 380

    var body: some View {
        let suggestions = assistant.suggestions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text(assistant.listing ? "Chats" : (assistant.chat.title.isEmpty ? "Ubi Chat" : assistant.chat.title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !assistant.shy {
                    Door(icon: "list.bullet", on: assistant.listing, help: "Chats") { assistant.listing.toggle() }
                }
                Door(icon: "square.and.pencil", help: "New Chat") { assistant.new() }
                if !drawn {
                    Menu {
                        if !assistant.shy {
                            Button(assistant.chat.starred ? "Unstar" : "Star") {
                                assistant.edit(assistant.chat.id) { $0.starred.toggle() }
                            }
                            Button(assistant.chat.task ? "Mark Done" : "Make It a Task") {
                                assistant.edit(assistant.chat.id) { $0.task.toggle() }
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
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
                Door(icon: "xmark", help: "Close   esc") { browser.closeAssistant() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)

            if assistant.listing {
                ChatList(assistant: assistant, chats: Shared.chats, drawn: drawn)
            } else {
                if drawn {
                    conversation
                    Spacer(minLength: 0)
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

                Rectangle().fill(Palette.hairline).frame(height: 1)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Door(icon: assistant.chat.pageHidden ? "eye.slash" : "eye",
                             on: !assistant.chat.pageHidden,
                             help: "Share the page in front") { assistant.togglePage() }
                        Text(pageLine)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Door(icon: "pin", help: "Pin This Page") { assistant.pinPage() }
                    }
                    if !assistant.chat.pins.isEmpty {
                        if drawn {
                            pinsRow
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                pinsRow
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

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
                                        .foregroundStyle(Palette.faint)
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
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                }

                HStack(spacing: 8) {
                    if drawn {
                        Text("Ask, or type / or @…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.faint)
                    } else {
                        TextField("", text: $assistant.draft, prompt: Text("Ask, or type / or @…").foregroundStyle(Palette.faint))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .focused($typing)
                            .onSubmit { assistant.submit() }
                            .disabled(assistant.notice != nil)
                    }
                    if assistant.busy {
                        Door(icon: "stop.fill", help: "Stop") { assistant.stop() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ModelPicker(browser: browser, prefs: browser.prefs, drawn: drawn)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: AssistantPanel.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.ground)
        .overlay(alignment: onLeft ? .trailing : .leading) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .onAppear { if !drawn { typing = true } }
    }

    private var pageLine: String {
        guard let tab = browser.active, !tab.isBlank else { return "No page in front" }
        if tab.isPrivatePage && !assistant.shy { return "Private tab — not shared" }
        if !assistant.shareable(tab) { return "Not a web page — not shared" }
        if assistant.chat.pageHidden { return "Not shared: \(tab.label)" }
        return tab.label
    }

    private var pinsRow: some View {
        HStack(spacing: 6) {
            Text("Pins: \(assistant.chat.pins.count)")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
            ForEach(assistant.chat.pins) { pin in
                HStack(spacing: 3) {
                    Button { assistant.togglePin(pin.id) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: pin.hidden ? "eye.slash" : "eye")
                                .font(.system(size: 9))
                            Text(verbatim: pin.title)
                                .lineLimit(1)
                                .frame(maxWidth: 120)
                        }
                    }
                    .buttonStyle(.plain)
                    Button { assistant.unpin(pin.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 11))
                .foregroundStyle(pin.hidden ? Palette.faint : Palette.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Palette.wash, in: Capsule())
            }
        }
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
        VStack(alignment: .leading, spacing: 14) {
            if let notice = assistant.notice {
                noticeCard(notice)
            }
            if assistant.shy {
                Text("A private tab's chat: only an AI on this Mac, and nothing is kept.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            if assistant.helpShown {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(UbiChat.commands, id: \.self) { cmd in
                            Text("\(cmd.name) — \(cmd.hint)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink)
                        }
                        Text("tabs/  bookmarks/  history/  @ — pin a page")
                            .font(.system(size: 11.5))
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("The page in front goes with your question unless you close its eye below. Type tabs/, bookmarks/, history/ or @ to pin more pages, and / for commands.")
                    .font(.system(size: 12))
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
            ForEach(assistant.turns) { turn in
                TurnView(turn: turn).id(turn.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caution(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
            Text(verbatim: text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted)
        .padding(8)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func noticeCard(_ notice: Assistant.Notice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Answers from \(notice.provider.name)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(verbatim: notice.text)
                .font(.system(size: 12))
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

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: turn.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if turn.answer.isEmpty, !turn.done {
                    Text("…").font(.system(size: 13)).foregroundStyle(Palette.faint)
                }
                if !turn.answer.isEmpty {
                    // Markdown's emphasis and code; never its links or pictures (see Markdown.shown).
                    Text(Markdown.shown(turn.answer))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failed = turn.failed {
                    Text(verbatim: failed).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                if !turn.strays.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .medium))
                        Text(verbatim: "Not in the pages shared: " + turn.strays.joined(separator: ", "))
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Palette.muted)
                    .padding(8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                HStack {
                    Text("AI — may be wrong · \(turn.place)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if turn.done, !turn.answer.isEmpty {
                        Quick("Copy") { UbiChat.copy(turn.answer) }
                    }
                }
            }
        }
    }

    private struct ChatList: View {
        @ObservedObject var assistant: Assistant
        @ObservedObject var chats: Chats
        var drawn = false

        var body: some View {
            if chats.all.isEmpty {
                Text("No chats yet. They stay in the nest — on this Mac only.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if drawn {
                listContent
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) {
                    listContent
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }

        private var listContent: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.title) { section in
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    ForEach(section.items) { chat in
                        HStack(spacing: 6) {
                            if chat.task {
                                Image(systemName: "list.clipboard")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.muted)
                            } else if chat.starred {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Palette.muted)
                            }
                            Text(chat.title.isEmpty ? "Untitled" : chat.title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if chat.task {
                                Door(icon: "checkmark", help: "Mark Done") {
                                    assistant.edit(chat.id) { $0.task = false }
                                }
                            } else {
                                Text(When.clock(chat.touched))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.faint)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(chat.id == assistant.chat.id ? Palette.wash : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { assistant.open(chat.id) }
                        .contextMenu {
                            Button(chat.starred ? "Unstar" : "Star") {
                                assistant.edit(chat.id) { $0.starred.toggle() }
                            }
                            Button(chat.task ? "Mark Done" : "Make It a Task") {
                                assistant.edit(chat.id) { $0.task.toggle() }
                            }
                            Divider()
                            Button("Delete Chat") {
                                assistant.delete(chat.id)
                            }
                        }
                    }
                }
            }
        }

        private var sections: [(title: String, items: [Chat])] {
            let sorted = chats.all.sorted { $0.touched > $1.touched }
            var out: [(String, [Chat])] = []
            let tasks = sorted.filter(\.task)
            if !tasks.isEmpty { out.append(("Tasks", tasks)) }
            let starred = sorted.filter { $0.starred && !$0.task }
            if !starred.isEmpty { out.append(("Starred", starred)) }
            for chat in sorted where !chat.task && !chat.starred {
                let day = When.day(chat.touched)
                if out.last?.0 == day {
                    out[out.count - 1].1.append(chat)
                } else {
                    out.append((day, [chat]))
                }
            }
            return out
        }
    }

    private struct ModelPicker: View {
        @ObservedObject var browser: Browser
        @ObservedObject var prefs: Preferences
        var drawn = false

        private var labelText: String {
            prefs.aiProvider.map { "\($0.name) · \(prefs.aiModel(for: $0))" } ?? "Choose an AI"
        }

        var body: some View {
            HStack(spacing: 4) {
                if drawn {
                    Text(labelText)
                        .font(.system(size: 10.5))
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
                                .font(.system(size: 10.5))
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
                    Spacer(minLength: 0)
                }
            }
        }
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
