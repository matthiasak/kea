import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case check(String)

    var description: String {
        switch self {
        case .check(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.check(message) }
}

@main
private struct CarryTests {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("CarryTests-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: home) }

        let searchSupport = home.appendingPathComponent("Library/Application Support/Search", isDirectory: true)
        try files.createDirectory(at: searchSupport.appendingPathComponent("AI", isDirectory: true), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: searchSupport.appendingPathComponent("history.json"))
        try Data("gguf".utf8).write(to: searchSupport.appendingPathComponent("AI/model.gguf"))

        let ext = searchSupport.appendingPathComponent("Extensions/abc", isDirectory: true)
        try files.createDirectory(at: ext.appendingPathComponent("_search", isDirectory: true), withIntermediateDirectories: true)
        try Data("[\"nativeMessaging\"]".utf8).write(to: ext.appendingPathComponent(".search-added"))
        try Data("v1".utf8).write(to: ext.appendingPathComponent(".search-shim"))
        try Data("{}".utf8).write(to: ext.appendingPathComponent("_search/worlds.json"))
        try Data(#"{"background":{"service_worker":"sw.js","scripts":["search-shim.js","bg.js"]},"content_scripts":[{"js":["search-shim-content.js","search-passkeys.js","c.js"]}]}"#.utf8)
            .write(to: ext.appendingPathComponent("manifest.json"))
        let swText = Carry.oldMarker + "\nshim()\n" + Carry.oldEnd + "\n" + Carry.oldImport + "self.ok = 1;\n"
        try Data(swText.utf8).write(to: ext.appendingPathComponent("sw.js"))
        try Data(("<html><head>" + Carry.oldTag + "</head><body>ok</body></html>").utf8).write(to: ext.appendingPathComponent("popup.html"))
        for name in Carry.oldScripts {
            try Data("old".utf8).write(to: ext.appendingPathComponent(name))
        }
        try Data(#"[{"id":"abc","permissions":["search:history","tabs"],"more":{"permissions":["search:x"]}}]"#.utf8)
            .write(to: searchSupport.appendingPathComponent("Extensions/installed.json"))

        let oldWebKit = home.appendingPathComponent("Library/WebKit/com.officecommun.search", isDirectory: true)
        try files.createDirectory(at: oldWebKit.appendingPathComponent("WebsiteData/Default", isDirectory: true), withIntermediateDirectories: true)
        try files.createDirectory(at: oldWebKit.appendingPathComponent("ContentRuleLists", isDirectory: true), withIntermediateDirectories: true)
        try Data("search".utf8).write(to: oldWebKit.appendingPathComponent("WebsiteData/Default/cookies"))
        try Data("rules".utf8).write(to: oldWebKit.appendingPathComponent("ContentRuleLists/x"))

        let newWebKit = home.appendingPathComponent("Library/WebKit/app.kea.browser", isDirectory: true)
        try files.createDirectory(at: newWebKit.appendingPathComponent("WebsiteData", isDirectory: true), withIntermediateDirectories: true)
        try files.createDirectory(at: newWebKit.appendingPathComponent("WebsiteDataStore/5E4C0000-0000-4000-8000-000000000001", isDirectory: true), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: newWebKit.appendingPathComponent("WebsiteData/junk"))
        try Data("probe".utf8).write(to: newWebKit.appendingPathComponent("WebsiteDataStore/5E4C0000-0000-4000-8000-000000000001/x"))

        let httpStorages = home.appendingPathComponent("Library/HTTPStorages", isDirectory: true)
        try files.createDirectory(at: httpStorages, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: httpStorages.appendingPathComponent("app.kea.browser.binarycookies"))
        try Data("old".utf8).write(to: httpStorages.appendingPathComponent("com.officecommun.search.binarycookies"))

        try require(Carry.needed(home: home), "needed should be true before carry")
        Carry.files(home: home)
        print("PASS needed and files migration run")

        // 1. Search is gone. Kea/history.json exists. Kea/AI is gone.
        let keaSupport = home.appendingPathComponent("Library/Application Support/Kea", isDirectory: true)
        try require(!files.fileExists(atPath: searchSupport.path), "Search folder should be gone")
        try require(files.fileExists(atPath: keaSupport.appendingPathComponent("history.json").path), "Kea/history.json should exist")
        try require(!files.fileExists(atPath: keaSupport.appendingPathComponent("AI").path), "Kea/AI should be gone")
        print("PASS Application Support folder moved and AI removed")

        // 2. .kea-added and _kea/worlds.json exist; old markers/scripts gone.
        let keaExt = keaSupport.appendingPathComponent("Extensions/abc", isDirectory: true)
        try require(files.fileExists(atPath: keaExt.appendingPathComponent(".kea-added").path), ".kea-added should exist")
        try require(files.fileExists(atPath: keaExt.appendingPathComponent("_kea/worlds.json").path), "_kea/worlds.json should exist")
        try require(!files.fileExists(atPath: keaExt.appendingPathComponent(".search-added").path), ".search-added should be gone")
        try require(!files.fileExists(atPath: keaExt.appendingPathComponent(".search-shim").path), ".search-shim should be gone")
        for name in Carry.oldScripts {
            try require(!files.fileExists(atPath: keaExt.appendingPathComponent(name).path), "\(name) should be gone")
        }
        print("PASS extension markers and old shim scripts cleaned")

        // 3. Manifest tidied.
        let manifestData = try Data(contentsOf: keaExt.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        let bg = manifest?["background"] as? [String: Any]
        let scripts = bg?["scripts"] as? [String]
        let cs = (manifest?["content_scripts"] as? [[String: Any]])?.first?["js"] as? [String]
        try require(scripts == ["bg.js"], "expected scripts == [\"bg.js\"], got \(String(describing: scripts))")
        try require(cs == ["c.js"], "expected content js == [\"c.js\"], got \(String(describing: cs))")
        try require(bg?["service_worker"] as? String == "sw.js", "service_worker should remain sw.js")

        // 4. sw.js and popup.html stripped.
        let swOut = try String(contentsOf: keaExt.appendingPathComponent("sw.js"), encoding: .utf8)
        try require(swOut == "self.ok = 1;\n", "expected sw.js stripped, got \(swOut)")
        let popupOut = try String(contentsOf: keaExt.appendingPathComponent("popup.html"), encoding: .utf8)
        try require(!popupOut.contains("search-shim"), "popup.html should not contain search-shim")
        print("PASS manifest, worker, and HTML page stripped")

        // 5. installed.json permissions renamed.
        let installedData = try Data(contentsOf: keaSupport.appendingPathComponent("Extensions/installed.json"))
        let installed = try JSONSerialization.jsonObject(with: installedData) as? [[String: Any]]
        let perms = installed?.first?["permissions"] as? [String]
        let morePerms = (installed?.first?["more"] as? [String: Any])?["permissions"] as? [String]
        try require(perms == ["kea:history", "tabs"], "expected [\"kea:history\", \"tabs\"], got \(String(describing: perms))")
        try require(morePerms == ["kea:x"], "expected [\"kea:x\"], got \(String(describing: morePerms))")
        print("PASS installed.json permissions renamed")

        // 6. WebKit stores merged.
        let cookies = try String(contentsOf: newWebKit.appendingPathComponent("WebsiteData/Default/cookies"), encoding: .utf8)
        try require(cookies == "search", "expected cookies == search")
        try require(!files.fileExists(atPath: newWebKit.appendingPathComponent("WebsiteData/junk").path), "WebsiteData/junk should be replaced")
        try require(files.fileExists(atPath: newWebKit.appendingPathComponent("WebsiteDataStore/5E4C0000-0000-4000-8000-000000000001/x").path), "test WebsiteDataStore should remain")
        try require(!files.fileExists(atPath: newWebKit.appendingPathComponent("ContentRuleLists").path), "ContentRuleLists should be gone")
        try require(!files.fileExists(atPath: oldWebKit.path), "old WebKit folder should be gone")

        // 7. binarycookies replaced.
        let bc = try String(contentsOf: httpStorages.appendingPathComponent("app.kea.browser.binarycookies"), encoding: .utf8)
        try require(bc == "old", "expected binarycookies == old")
        try require(!files.fileExists(atPath: httpStorages.appendingPathComponent("com.officecommun.search.binarycookies").path), "old binarycookies should be gone")
        print("PASS WebKit and HTTPStorages merged")

        // 8. needed is now false, and a second files(home:) changes nothing.
        try require(!Carry.needed(home: home), "needed should be false after carry")
        Carry.files(home: home)
        try require(files.fileExists(atPath: keaSupport.appendingPathComponent("history.json").path), "Kea/history.json should still exist")

        // 9. stripped fallback without oldEnd.
        try require(Carry.stripped(Carry.oldMarker + "\n(function(){\nx\n})();\n" + "rest") == "rest", "stripped fallback should strip old wrapper")
        print("PASS idempotence and stripped fallback")

        // 10. settings(from:into:)
        let suiteName = "app.kea.browser.carrytest.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else { throw TestFailure.check("could not create suite") }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        Carry.settings(from: [
            "ai.provider": "gemini",
            "NSWindow Frame search": "10 20 800 600",
            "update.checked": 123,
            "AppleLanguages": ["en"],
        ], into: suite)
        let domain = suite.persistentDomain(forName: suiteName) ?? [:]
        try require(domain["ai.provider"] as? String == "gemini", "ai.provider should be carried")
        try require(domain["NSWindow Frame kea"] as? String == "10 20 800 600", "window frame should be carried as NSWindow Frame kea")
        try require(domain["update.checked"] == nil, "update.checked should be dropped")
        try require(domain["AppleLanguages"] == nil, "AppleLanguages should be dropped")
        print("PASS settings carry")
    }
}
