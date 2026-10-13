import Foundation
import Security

// The AI add-on: a summary of the page you're on, and questions about it,
// answered where you choose — a model on this Mac, an app on this Mac that
// runs one (Ollama, LM Studio), or a provider you have an account or a key
// with. On by default, but nothing is detected, downloaded or sent until you
// choose where it runs in Settings › AI and ask.
//
// This file: where it runs, and the keys. The requests are AIClient's, the
// page's text AIPage's.

/// Where the answers come from: one of the seven built in, or any provider in
/// the models.dev catalog (AICatalog) that speaks one of the three wires.
struct AIProvider: Hashable, Identifiable {
    /// Built-ins: "thisMac", "anthropic", "openAI", "gemini", "openRouter",
    /// "ollama", "lmStudio". Catalog: its models.dev id.
    let id: String
    let name: String
    /// Where requests go outside a test run.
    let home: URL
    let wire: Wire
    /// The model asked for when none is chosen; "" when there is none.
    let suggested: String
    /// The variables its key usually lives in.
    var env: [String]
    /// The catalog's models, newest first.
    var models: [String] = []

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// How requests are written.
    enum Wire: String { case openAI, anthropic, gemini }

    /// The model downloaded to this Mac, run by Search's own engine (AIEngine).
    /// Never asked over the network: the engine is a program of its own.
    static let thisMac = AIProvider(id: "thisMac", name: "On this Mac", home: URL(string: "http://127.0.0.1:1/")!,
                                    wire: .openAI, suggested: "", env: [])
    // Cheap and quick, for a summary; each can be changed in Settings.
    static let anthropic = AIProvider(id: "anthropic", name: "Anthropic", home: URL(string: "https://api.anthropic.com/v1/")!,
                                      wire: .anthropic, suggested: "claude-haiku-4-5", env: ["ANTHROPIC_API_KEY"])
    static let openAI = AIProvider(id: "openAI", name: "OpenAI", home: URL(string: "https://api.openai.com/v1/")!,
                                   wire: .openAI, suggested: "gpt-5.4-mini", env: ["OPENAI_API_KEY"])
    static let gemini = AIProvider(id: "gemini", name: "Google Gemini", home: URL(string: "https://generativelanguage.googleapis.com/v1beta/")!,
                                   wire: .gemini, suggested: "gemini-3.8-flash", env: ["GEMINI_API_KEY", "GOOGLE_API_KEY"])
    static let openRouter = AIProvider(id: "openRouter", name: "OpenRouter", home: URL(string: "https://openrouter.ai/api/v1/")!,
                                       wire: .openAI, suggested: "google/gemini-3.8-flash", env: ["OPENROUTER_API_KEY"])
    /// Ollama, on this Mac. The local apps have no default: the list comes from the app.
    static let ollama = AIProvider(id: "ollama", name: "Ollama", home: URL(string: "http://127.0.0.1:11434/v1/")!,
                                   wire: .openAI, suggested: "", env: [])
    /// LM Studio, on this Mac.
    static let lmStudio = AIProvider(id: "lmStudio", name: "LM Studio", home: URL(string: "http://127.0.0.1:1234/v1/")!,
                                     wire: .openAI, suggested: "", env: [])

    static let builtIns: [AIProvider] = [.thisMac, .anthropic, .openAI, .gemini, .openRouter, .ollama, .lmStudio]

    /// Every provider to choose from: the built-ins, with the catalog's models
    /// for four of them, then the rest of the catalog by name.
    @MainActor static var all: [AIProvider] {
        let catalog = AICatalog.shared
        let merged = builtIns.map { built -> AIProvider in
            guard let found = catalog.merged[AICatalog.builtIn[built.id] ?? ""] else { return built }
            var built = built
            built.models = found.models
            built.env += found.env.filter { !built.env.contains($0) }
            return built
        }
        return merged + catalog.providers
    }

    @MainActor static func named(_ id: String) -> AIProvider? { all.first { $0.id == id } }

    /// Runs on this Mac: nothing leaves it, and no key is needed.
    var isLocal: Bool { ["thisMac", "ollama", "lmStudio"].contains(id) }

    var defaultModel: String { self == .thisMac ? AIEngine.model.name : suggested }

    /// The one address requests go to. A key is kept for this host and is
    /// never sent to any other (see AIClient.request).
    var base: URL {
        if Store.testing, let mock = AIProvider.mock { return mock.appendingPathComponent(id + "/") }
        return home
    }

    var host: String { self == .thisMac ? "this Mac" : base.host() ?? "" }

    /// A test run's stand-in for every provider: a server on this Mac that
    /// answers the way they do (bench ai-mock). Never outside a test run,
    /// and only ever on the loopback address.
    nonisolated(unsafe) static var mock: URL?
}

enum AIKeySource: Equatable { case keychain, environment(String), command(String) }

/// The keys: in the keychain, or fetched when a request needs one from a
/// variable or a command the user named.
///
/// A signed release keeps them in the data protection keychain, under Search's
/// own access group: only apps signed as Search can read or write them. A
/// copy built from source has no access group, and keeps them in the login
/// keychain instead, as Vault keeps passwords. Either way this Mac only,
/// readable while it is unlocked, never synced, and each kept for its
/// provider's host (account "provider@host"). Test runs keep theirs in
/// memory, for the run.
///
/// A key is read the moment a request needs it and let go with the request:
/// never in the settings file, a published value, a log line or an error.
@MainActor
enum AIKeys {
    enum Saved { case kept, failed }

    private static let service = "com.officecommun.search.ai"
    /// A test run's, by account, gone when it quits.
    private static var rehearsal: [String: String] = [:]

    private static func account(_ provider: AIProvider) -> String { "\(provider.id)@\(provider.host)" }

    /// Whether this copy has the access group the data protection keychain needs.
    private static let protected: Bool = {
        if Store.testing { return true }
        let asked: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecUseDataProtectionKeychain as String: true,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "probe",
                                    kSecReturnAttributes as String: true]
        return SecItemCopyMatching(asked as CFDictionary, nil) != errSecMissingEntitlement
    }()

    private static func query(_ provider: AIProvider) -> [String: Any] {
        var asked: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(provider)]
        if protected { asked[kSecUseDataProtectionKeychain as String] = true }
        return asked
    }

    static func save(_ key: String, for provider: AIProvider) -> Saved {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !provider.isLocal else { return .failed }
        setSource(.keychain, for: provider)
        if Store.testing {
            rehearsal[account(provider)] = key
            return .kept
        }
        SecItemDelete(query(provider) as CFDictionary)
        var item = query(provider)
        item[kSecValueData as String] = Data(key.utf8)
        if protected {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrSynchronizable as String] = false
        } else {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }
        item[kSecAttrLabel as String] = "Search — \(provider.name) key"
        // The last four, to tell keys apart in Settings without reading one.
        item[kSecAttrComment as String] = String(key.suffix(4))
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? .kept : .failed
    }

    // MARK: where a key comes from

    /// Kept by account ("provider@host"): were a provider's host to change, the
    /// variable or command is no longer used for it, so a key never goes to a new host.
    private static let sourcesKey = "ai.keySources"

    static func source(for provider: AIProvider) -> AIKeySource {
        guard let saved = (Store.settings.dictionary(forKey: sourcesKey) as? [String: String])?[account(provider)] else { return .keychain }
        if saved.hasPrefix("env:") { return .environment(String(saved.dropFirst(4))) }
        if saved.hasPrefix("cmd:") { return .command(String(saved.dropFirst(4))) }
        return .keychain
    }

    static func isVariableName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// `.keychain` removes the entry. A name that isn't a variable's, or an empty command, is ignored.
    static func setSource(_ source: AIKeySource, for provider: AIProvider) {
        var all = Store.settings.dictionary(forKey: sourcesKey) as? [String: String] ?? [:]
        switch source {
        case .keychain: all[account(provider)] = nil
        case .environment(let name):
            guard isVariableName(name) else { return }
            all[account(provider)] = "env:" + name
        case .command(let command):
            guard !command.isEmpty else { return }
            all[account(provider)] = "cmd:" + command
        }
        Store.settings.set(all, forKey: sourcesKey)
    }

    /// The key, for the request about to go out. Nil when there is none.
    static func key(for provider: AIProvider) async -> String? {
        switch source(for: provider) {
        case .keychain:
            return keychainKey(provider)
        case .environment(let name):
            // An app started from the Dock has none of the shell's variables: ask a shell.
            if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
            return await shell("printenv \(name)")
        case .command(let command):
            return await shell(command)
        }
    }

    private static func keychainKey(_ provider: AIProvider) -> String? {
        if Store.testing { return rehearsal[account(provider)] }
        var asked = query(provider)
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What a command prints, run by the user's login shell: the last line of
    /// output, if it looks like a key. Ten seconds, then it is killed.
    // ponytail: last stdout line is the key; an rc file that prints after it breaks this — use a command that prints only the key
    nonisolated static func shell(_ command: String) async -> String? {
        await withCheckedContinuation { done in
            // Whichever comes first, the output or the ten seconds, answers; a
            // grandchild holding the pipe open can't keep the caller waiting.
            let lock = NSLock()
            nonisolated(unsafe) var answered = false
            func answer(_ value: String?) {
                lock.lock(); defer { lock.unlock() }
                guard !answered else { return }
                answered = true
                done.resume(returning: value)
            }
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) } ?? "/bin/zsh")
                process.arguments = ["-l", "-i", "-c", command]
                let out = Pipe()
                process.standardOutput = out
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return answer(nil) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    answer(nil)
                    guard process.isRunning else { return }
                    process.terminate()
                    // An interactive shell ignores the first.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let last = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .last { !$0.isEmpty }
                guard let last, last.count <= 400, !last.contains(where: \.isWhitespace) else { return answer(nil) }
                answer(last)
            }
        }
    }

    /// "••••1a2b" for one that is kept, without reading the key itself;
    /// where it comes from otherwise. Never runs anything.
    static func hint(for provider: AIProvider) -> String? {
        switch source(for: provider) {
        case .environment(let name): return "$" + name
        case .command: return "from a command"
        case .keychain: break
        }
        if Store.testing { return rehearsal[account(provider)].map { "••••" + $0.suffix(4) } }
        var asked = query(provider)
        asked[kSecReturnAttributes as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess,
              let attributes = found as? [String: Any]
        else { return nil }
        return "••••" + (attributes[kSecAttrComment as String] as? String ?? "")
    }

    static func forget(_ provider: AIProvider) {
        setSource(.keychain, for: provider)
        if Store.testing { rehearsal[account(provider)] = nil; return }
        SecItemDelete(query(provider) as CFDictionary)
    }

    static func forgetAll() {
        Store.settings.removeObject(forKey: sourcesKey)
        rehearsal = [:]
        var all: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if protected { all[kSecUseDataProtectionKeychain as String] = true }
        if !Store.testing { SecItemDelete(all as CFDictionary) }
    }
}
