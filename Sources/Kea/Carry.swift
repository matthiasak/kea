import AppKit
import Security

// Kea was called Search, under the bundle id com.officecommun.search, until
// October 2026. The first time Kea opens on a Mac that ran Search, what
// Search kept comes over, once: its folder, its settings, the sign-ins and
// site data WebKit kept for it, the passwords and AI keys in the keychain
// (relabelled; no secret is read), and each extension's files, with the
// pieces Search wrote into them swapped for Kea's. Store runs this before
// anything is read (Store.carried); a test run never does.

enum Carry {
    static let oldID = "com.officecommun.search"
    static let newID = "app.kea.browser"

    static func fromSearch() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard needed(home: home) else { return }
        // Search writing its files while they move would lose some of them.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: oldID).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit Search first"
            alert.informativeText = "Kea brings over your tabs, history, bookmarks, settings and sign-ins from Search the first time it opens. Quit Search, then open Kea again."
            alert.addButton(withTitle: "Quit Kea")
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(0)
        }
        files(home: home)
        if let old = UserDefaults.standard.persistentDomain(forName: oldID) { settings(from: old, into: .standard) }
        keychain()
    }

    /// Search's folder is there and Kea's isn't: Kea has never run here for real.
    static func needed(home: URL) -> Bool {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return FileManager.default.fileExists(atPath: support.appendingPathComponent("Search").path)
            && !FileManager.default.fileExists(atPath: support.appendingPathComponent("Kea").path)
    }

    static func files(home: URL) {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        for (from, to) in [("Application Support/Search", "Application Support/Kea"),
                           ("WebKit/\(oldID)", "WebKit/\(newID)"),
                           ("HTTPStorages/\(oldID)", "HTTPStorages/\(newID)"),
                           ("HTTPStorages/\(oldID).binarycookies", "HTTPStorages/\(newID).binarycookies")] {
            merge(library.appendingPathComponent(from), into: library.appendingPathComponent(to))
        }
        let kea = library.appendingPathComponent("Application Support/Kea", isDirectory: true)
        // The engine that ran a model on this Mac, and the model: not in Kea.
        try? FileManager.default.removeItem(at: kea.appendingPathComponent("AI", isDirectory: true))
        // Search's compiled blocking rules, under names Kea doesn't use; Kea compiles its own.
        try? FileManager.default.removeItem(at: library.appendingPathComponent("WebKit/\(newID)/ContentRuleLists", isDirectory: true))
        extensions(in: kea.appendingPathComponent("Extensions", isDirectory: true))
    }

    /// Moves `source` to `target`. Kea's test runs share its bundle id, so
    /// WebKit's folders for it may already be there: then each of Search's
    /// entries replaces Kea's of the same name, whole — no store is ever a
    /// mix of the two — and the rest of Kea's stay.
    static func merge(_ source: URL, into target: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { return }
        var folder: ObjCBool = false
        guard files.fileExists(atPath: target.path, isDirectory: &folder) else {
            try? files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.moveItem(at: source, to: target)
            return
        }
        var sourceFolder: ObjCBool = false
        _ = files.fileExists(atPath: source.path, isDirectory: &sourceFolder)
        guard folder.boolValue, sourceFolder.boolValue else {
            try? files.removeItem(at: target)
            try? files.moveItem(at: source, to: target)
            return
        }
        for child in (try? files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
            let there = target.appendingPathComponent(child.lastPathComponent)
            try? files.removeItem(at: there)
            try? files.moveItem(at: child, to: there)
        }
        if (try? files.contentsOfDirectory(atPath: source.path))?.isEmpty == true { try? files.removeItem(at: source) }
    }

    // What Search put into each extension, by its old names.
    static let oldMarker = "/* Search: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    static let oldEnd = "/* Search: end of shim */"
    static let oldImport = "import \"/search-shim.js\";\n"
    static let oldTag = "<script src=\"/search-shim.js\"></script>"
    static let oldScripts: Set<String> = ["search-shim.js", "search-shim-content.js", "search-passkeys.js"]

    /// Search's marks and shims out, before Kea prepares each extension again
    /// with its own; what Search added to a manifest is remembered as Kea's.
    static func extensions(in folder: URL) {
        let files = FileManager.default
        for dir in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for (old, new) in [(".search-added", ".kea-added"), ("_search", "_kea")] {
                let from = dir.appendingPathComponent(old), to = dir.appendingPathComponent(new)
                if files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) { try? files.moveItem(at: from, to: to) }
            }
            try? files.removeItem(at: dir.appendingPathComponent(".search-shim"))
            tidyManifest(in: dir)
            for name in oldScripts { try? files.removeItem(at: dir.appendingPathComponent(name)) }
            tidyPages(in: dir)
        }
        let list = folder.appendingPathComponent("installed.json")
        if let data = try? Data(contentsOf: list), let json = try? JSONSerialization.jsonObject(with: data),
           let out = try? JSONSerialization.data(withJSONObject: renamed(json)) {
            try? out.write(to: list, options: .atomic)
        }
    }

    static func tidyManifest(in dir: URL) {
        let url = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var changed = false
        func kept(_ names: [String]) -> [String] {
            let left = names.filter { !oldScripts.contains(String($0.drop(while: { $0 == "/" }))) }
            if left.count != names.count { changed = true }
            return left
        }
        if var background = manifest["background"] as? [String: Any] {
            if let scripts = background["scripts"] as? [String] { background["scripts"] = kept(scripts) }
            if let worker = background["service_worker"] as? String, let file = inside(dir, worker),
               let source = try? String(contentsOf: file, encoding: .utf8) {
                let clean = stripped(source)
                if clean != source { try? clean.write(to: file, atomically: true, encoding: .utf8) }
            }
            manifest["background"] = background
        }
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if let js = entry["js"] as? [String] { entry["js"] = kept(js) }
                return entry
            }
        }
        if changed, let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? out.write(to: url, options: .atomic)
        }
    }

    /// A worker with Search's shim taken off its top.
    static func stripped(_ text: String) -> String {
        var source = text
        if source.hasPrefix(oldMarker), let end = source.range(of: oldEnd) {
            source = String(source[end.upperBound...])
            if source.hasPrefix("\n") { source.removeFirst() }
        }
        // Older shims had no end mark: they ran to the first close of their wrapper.
        while source.hasPrefix(oldMarker), let end = source.range(of: "\n})();\n") {
            source = String(source[end.upperBound...])
        }
        while source.hasPrefix(oldImport) { source.removeFirst(oldImport.count) }
        return source
    }

    static func tidyPages(in dir: URL) {
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let file as URL in walk where ["html", "htm"].contains(file.pathExtension.lowercased()) {
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let page = try? String(contentsOf: file, encoding: .utf8), page.contains(oldTag) else { continue }
            try? page.replacingOccurrences(of: oldTag, with: "").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// `path`, as a manifest names it, inside `dir` and not through a link.
    static func inside(_ dir: URL, _ path: String) -> URL? {
        let file = dir.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(dir.standardizedFileURL.path + "/"),
              (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return file
    }

    /// installed.json: the permissions Search granted itself ("search:…") are Kea's ("kea:…").
    static func renamed(_ value: Any, key: String? = nil) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { $0[$1.key] = renamed($1.value, key: $1.key) }
        }
        if let list = value as? [Any] {
            return list.map { item -> Any in
                if key == "permissions", let name = item as? String, name.hasPrefix("search:") { return "kea:" + String(name.dropFirst(7)) }
                return renamed(item)
            }
        }
        return value
    }

    /// Search's settings, Search's winning: before this, nothing of Kea's was real.
    static func settings(from old: [String: Any], into fresh: UserDefaults) {
        let gone: Set<String> = ["carried", "update.install", "update.checked", "whatsnew.seen"]
        for (key, value) in old where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !gone.contains(key) {
            fresh.set(value, forKey: key)
        }
        // The window comes back where it was, under its new name.
        if let frame = old["NSWindow Frame search"] as? String { fresh.set(frame, forKey: "NSWindow Frame kea") }
    }

    /// Only labels and the AI keys' service change; no secret is read, so macOS asks nothing here.
    static func keychain() {
        SecItemUpdate([kSecClass as String: kSecClassInternetPassword, kSecAttrLabel as String: "Search"] as CFDictionary,
                      [kSecAttrLabel as String: "Kea"] as CFDictionary)
        let oldCrypto = "com.apple.WebKit.WebCrypto.master+" + oldID
        let newCrypto = "com.apple.WebKit.WebCrypto.master+" + newID
        if SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: oldCrypto] as CFDictionary, nil) == errSecSuccess {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: newCrypto] as CFDictionary)
            SecItemUpdate([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: oldCrypto] as CFDictionary,
                          [kSecAttrAccount as String: newCrypto, kSecAttrLabel as String: "Kea WebCrypto Master Key"] as CFDictionary)
        }
        var found: CFTypeRef?
        let listed = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
                                          kSecAttrService as String: oldID + ".ai",
                                          kSecReturnAttributes as String: true,
                                          kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &found)
        guard listed == errSecSuccess, let items = found as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            let label = (item[kSecAttrLabel as String] as? String ?? "").replacingOccurrences(of: "Search — ", with: "Kea — ")
            SecItemUpdate([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: oldID + ".ai",
                           kSecAttrAccount as String: account] as CFDictionary,
                          [kSecAttrService as String: newID + ".ai", kSecAttrLabel as String: label] as CFDictionary)
        }
    }
}
