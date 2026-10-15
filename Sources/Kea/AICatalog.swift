import Foundation

// The providers and models to choose from, read from models.dev: the catalog
// pi and omp are generated from. Fetched when Settings › AI is opened and the
// copy kept on this Mac is more than a day old — never in the background —
// and slimmed to what is used here. Which of them can be reached is the
// client's business (AIClient speaks three wires); an entry whose address
// isn't a plain https one is left out.

@MainActor
final class AICatalog: ObservableObject {
    static let shared = AICatalog()

    /// The catalog's providers that aren't built in, by name.
    @Published private(set) var providers: [AIProvider] = []
    /// What models.dev lists for the built-ins, by its id for them (see `builtIn`).
    private(set) var merged: [String: (models: [String], env: [String])] = [:]
    /// models.dev's whole catalog; a test run may point it elsewhere (bench ai catalog).
    var source = URL(string: "https://models.dev/api.json")!

    /// A built-in's id → models.dev's id for it.
    nonisolated static let builtIn = ["anthropic": "anthropic", "openAI": "openai", "gemini": "google", "openRouter": "openrouter"]

    private struct Entry: Codable {
        var id: String
        var name: String
        var api: String
        var wire: String
        var env: [String]
        var models: [String]
    }

    private static let cache = Store.file("ai-catalog.json")

    private init() {
        if let data = try? Data(contentsOf: Self.cache), let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            apply(entries)
        }
    }

    /// Fetched again if the copy on this Mac is a day old. Not in a test run.
    func refreshIfStale() {
        guard !Store.testing else { return }
        let made = (try? FileManager.default.attributesOfItem(atPath: Self.cache.path))?[.modificationDate] as? Date
        if let made, Date().timeIntervalSince(made) < 86_400 { return }
        Task { _ = await refresh() }
    }

    /// The number of providers now listed; 0, with the old list kept, if it
    /// couldn't be fetched.
    func refresh() async -> Int {
        let url = source
        let entries = await Task.detached { () -> [Entry]? in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            guard let (data, response) = try? await URLSession(configuration: configuration).data(from: url),
                  (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
                  let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
            else { return nil }
            return Self.slim(all)
        }.value
        guard let entries, !entries.isEmpty else { return 0 }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: Self.cache, options: .atomic) }
        apply(entries)
        return providers.count
    }

    private func apply(_ entries: [Entry]) {
        let ours = Set(Self.builtIn.values)
        merged = Dictionary(uniqueKeysWithValues: entries.filter { ours.contains($0.id) }.map { ($0.id, ($0.models, $0.env)) })
        providers = entries.filter { !ours.contains($0.id) }.compactMap { entry in
            guard let home = URL(string: entry.api), let wire = AIProvider.Wire(rawValue: entry.wire) else { return nil }
            return AIProvider(id: entry.id, name: entry.name, home: home, wire: wire, suggested: "", env: entry.env, models: entry.models)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Where an entry without an "api" is reached, for the ones that speak the
    /// OpenAI way.
    // ponytail: base URLs for models.dev entries without "api" are a hand table; extend it when a wanted provider is skipped
    private nonisolated static let bases = [
        "groq": "https://api.groq.com/openai/v1",
        "xai": "https://api.x.ai/v1",
        "mistral": "https://api.mistral.ai/v1",
        "cerebras": "https://api.cerebras.ai/v1",
        "togetherai": "https://api.together.xyz/v1",
        "deepinfra": "https://api.deepinfra.com/v1/openai",
        "perplexity": "https://api.perplexity.ai",
        "cohere": "https://api.cohere.ai/compatibility/v1",
        "venice": "https://api.venice.ai/api/v1",
        "vercel": "https://ai-gateway.vercel.sh/v1",
    ]

    private nonisolated static func slim(_ all: [String: [String: Any]]) -> [Entry] {
        let ours = Set(builtIn.values)
        var entries: [Entry] = []
        for (id, p) in all where id != "ollama" && id != "lmstudio" {
            var api = (p["api"] as? String) ?? bases[id] ?? ""
            // Azure, Bedrock, Vertex and the like have a placeholder in theirs.
            if !ours.contains(id) {
                guard api.hasPrefix("https://"), !api.contains("${") else { continue }
                if !api.hasSuffix("/") { api += "/" }
            }
            let npm = p["npm"] as? String
            let wire = npm == "@ai-sdk/anthropic" ? "anthropic" : npm == "@ai-sdk/google" ? "gemini" : "openAI"
            let found = (p["models"] as? [String: [String: Any]] ?? [:]).filter { _, model in
                guard let modalities = model["modalities"] as? [String: Any] else { return true }
                return (modalities["output"] as? [String])?.contains("text") == true
            }
            .sorted {
                let (a, b) = ($0.value["release_date"] as? String ?? "", $1.value["release_date"] as? String ?? "")
                return a == b ? $0.key < $1.key : a > b
            }
            .map(\.key)
            entries.append(Entry(id: id, name: p["name"] as? String ?? id, api: api, wire: wire,
                                 env: p["env"] as? [String] ?? [], models: found))
        }
        return entries
    }
}
