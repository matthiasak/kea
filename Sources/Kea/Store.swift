import Foundation
import WebKit

// Where everything this browser keeps is kept.
//
// One place, and one rule: a run started for testing never touches the folder
// or the settings of the browser somebody is actually using. Sharing them once
// cost a person their pinned tabs, which is not a mistake worth being able to
// make twice.

enum Store {
    /// A run is a test run if it says so, or if it is being run straight out
    /// of the build folder rather than from an installed app. The second half
    /// is not belt and braces: a development build launched from a terminal
    /// once wrote over somebody's real session, and asking a person to
    /// remember a flag is not a safeguard.
    static var testing: Bool {
        if ProcessInfo.processInfo.environment["KEA_PROBE"] != nil { return true }
        return Bundle.main.executablePath?.contains("/.build/") == true
    }

    /// Which test world a test run lives in. KEA_PROBE=1, or a run from
    /// the build folder, is the test world, "Kea (test)". KEA_PROBE=
    /// <name> is a world of its own, "Kea (<name>)", with settings and
    /// WebKit stores of its own: two sessions testing at once, or a
    /// measurement that needs a browser nobody has installed anything in,
    /// never borrow each other's. Nil for the browser somebody is using.
    static let world: String? = {
        guard testing else { return nil }
        let asked = (ProcessInfo.processInfo.environment["KEA_PROBE"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return asked.isEmpty || asked == "1" || asked == "test" ? "test" : asked
    }()

    /// A test run there to be weighed and timed rather than driven
    /// (KEA_MEASURE beside KEA_PROBE). It keeps what the shipped
    /// browser does where test runs otherwise differ — hidden pages slowed
    /// the way WebKit slows them, App Nap left to macOS — so what gets
    /// measured is what people get.
    static var measuring: Bool {
        testing && ProcessInfo.processInfo.environment["KEA_MEASURE"] != nil
    }

    /// Cookies, sign-ins, caches. WebKit keeps its default store per bundle,
    /// not per folder, so a test run got every site already signed in — and
    /// "sign out of everything" in a test run signed the real browser out.
    /// A test run gets a store of its own, under a fixed name so it persists
    /// between probes the way the real one does. Wiping the test store is
    /// then as safe as wiping its folder.
    static var websites: WKWebsiteDataStore {
        _ = carried
        guard testing, !ownContainer else { return .default() }
        return WKWebsiteDataStore(forIdentifier: probeStore(1))
    }

    /// Settings › Privacy › Prevent cross-site tracking, turned off. WebKit's
    /// tracking prevention, as in Safari, clears what a site it has seen
    /// redirect you — a sign-in through Google or Apple, say — left in local
    /// storage once you haven't opened it for a week or a month of use, and a
    /// site it counts as a tracker loses its cookies too: you are signed out.
    /// Turned off, that stops, and so does the rest of it: a site framed in
    /// another gets its cookies again, so trackers can follow you across
    /// sites, as in Chrome. On unless turned off; until then its flag is not
    /// touched.
    @MainActor static var keepsSignIns = false {
        didSet {
            guard keepsSignIns != oldValue else { return }
            Spaces.everyStore.forEach(followSignIns)
        }
    }

    /// The switch through a name outside the public framework — Safari's
    /// "Prevent cross-site tracking" is the same one.
    @MainActor static func followSignIns(_ store: WKWebsiteDataStore) {
        let set = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        guard store.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(store.method(for: set), to: Setter.self)(store, set, !keepsSignIns)
    }

    /// A test copy of the app under a bundle id of its own has a WebKit
    /// container of its own too, so it can use WebKit's default store and
    /// extension configuration — the ones the real browser uses, which
    /// differ from stores made by identifier in how long extension workers
    /// are let live.
    static var ownContainer: Bool {
        (Bundle.main.bundleIdentifier ?? "") != "app.kea.browser"
    }

    /// The fixed identifiers of a test world's WebKit stores: 1 for websites,
    /// 2 for extensions. The test world's are 5E4C0000-0000-4000-8000-00000000000k,
    /// the ones fresh.sh wipes; a named world puts a hash of its name (FNV-1a,
    /// 32 bits) in place of the second and third groups of zeros, so each
    /// keeps its own from one run to the next.
    static func probeStore(_ kind: UInt32) -> UUID {
        var hash: UInt32 = 0
        if let world, world != "test" {
            hash = 2_166_136_261
            for byte in world.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        }
        let text = String(format: "5E4C%04X-%04X-4000-8000-%012X", hash >> 16, hash & 0xFFFF, kind)
        return UUID(uuidString: text)!
    }

    /// What Search kept, brought over once before anything here is read
    /// (Carry.swift). Never in a test run.
    static let carried: Void = { if !testing { Carry.fromSearch() } }()

    /// Kea's own folder; each test world has one of its own beside it.
    static let folder: URL = {
        _ = carried
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(world.map { "Kea (\($0))" } ?? "Kea", isDirectory: true)
    }()

    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// A file that didn't decode is set aside rather than overwritten the
    /// next time something is saved over it — bookmarks, history and a
    /// session are the kind of thing nobody wants to lose to a bad read with
    /// no trace of what was there. Failing to move it is fine: the read
    /// already came back empty either way, and there's nothing further to
    /// do about a folder that won't take a rename.
    static func quarantine(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }

    /// Settings live apart too: a test that changes what the tabs wear or
    /// where the tabs go must not change yours.
    static let settings: UserDefaults = {
        guard testing else {
            _ = carried
            return .standard
        }
        let suite = world == "test" ? "app.kea.browser.test" : "app.kea.browser.test.\(world ?? "")"
        return UserDefaults(suiteName: suite) ?? .standard
    }()
}

/// Files written in the background, one at a time and the newest last.
///
/// Each save used to go to a concurrent queue on its own: two saves of the
/// same file a moment apart could land in either order, and the session
/// written at quit could be overwritten by an older one still on its way —
/// yesterday's tabs coming back instead of today's. Here every write joins
/// one serial queue, and a write that a newer one of the same file has
/// overtaken is dropped, including when the newer one was written at once
/// on the way out.
enum Disk {
    private static let queue = DispatchQueue(label: "kea.disk", qos: .utility)
    /// Guards `newest` and `count`, held for a moment and never across a write.
    private static let lock = NSLock()
    /// Held across a write or a removal, so the newest-wins check and the change
    /// to the file are one step, without making whoever asks next wait for the disk.
    private static let io = NSLock()
    nonisolated(unsafe) private static var newest: [URL: Int] = [:]
    nonisolated(unsafe) private static var count = 0

    /// `encode` runs where the write does. `now` writes on the calling
    /// thread: quitting doesn't wait for a queue.
    static func write(_ file: URL, now: Bool = false, _ encode: @escaping @Sendable () -> Data?) {
        let turn = ask(file)
        let put: @Sendable () -> Void = {
            guard isNewest(file, turn), let data = encode() else { return }
            io.lock()
            defer { io.unlock() }
            // Overtaken: something newer of this file was asked for since.
            guard isNewest(file, turn) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        if now { put() } else { queue.async(execute: put) }
    }

    /// A file gone, in its turn among the writes; a newer write of it wins.
    static func remove(_ file: URL) {
        let turn = ask(file)
        queue.async {
            io.lock()
            defer { io.unlock() }
            guard isNewest(file, turn) else { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func ask(_ file: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        newest[file] = count
        return count
    }

    private static func isNewest(_ file: URL, _ turn: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return newest[file] == turn
    }

    /// Everything asked for so far, written — for the way out.
    static func drain() {
        queue.sync {}
    }
}
