import JavaScriptCore
import XCTest

@testable import Kea

@available(macOS 15.4, *)
final class ExtensionContentShimTests: XCTestCase {
    func testContentShimSizePlaceholdersAndSyntax() throws {
        let content = ExtensionShims.contentScript
        let full = ExtensionShims.script
        XCTAssertLessThan(content.count, full.count / 5)
        XCTAssertFalse(content.contains("__KEA_"))
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(content)
        XCTAssertNil(js.exception?.toString())
    }

    func testPrepareUsesContentShimAndMainWorldPasskeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ext-content-shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0",
            "content_scripts": [
                ["matches": ["<all_urls>"], "js": ["original.js"]],
                ["matches": ["<all_urls>"], "js": ["original.js"], "world": "MAIN"],
            ],
        ]
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try "console.log(1);".write(
            to: root.appendingPathComponent("original.js"), atomically: true, encoding: .utf8)

        try ExtensionShims.prepare(root, fresh: true)

        let prepared = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let entries = try XCTUnwrap(prepared["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["js"] as? [String], [ExtensionShims.contentFile, "original.js"])
        XCTAssertEqual(
            entries[1]["js"] as? [String],
            [ExtensionShims.passkeys, ExtensionShims.contentFile, "original.js"])
    }
}
