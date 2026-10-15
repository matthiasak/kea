import AppKit
import SwiftUI

// Bookmarks: folders and sites, kept in a small file.
//
// Shown as the app's own kind of list rather than a system menu, on purpose:
// a menu can't be dragged into, and can't be asked a second thing by
// right-clicking it. A folder you actually keep things in wants both.

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// Nil for a folder.
    var url: String?
    var children: [Bookmark]?

    var isFolder: Bool { url == nil }

    /// A bookmark whose name was emptied, as in Chrome and Safari: on the
    /// bar it is its icon alone. There is no setting; emptying it is the
    /// choice. A folder always has a name.
    var unnamed: Bool {
        !isFolder && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a list reads it as: its name, or for one without, its address
    /// as the address field shows it, so the list is still readable.
    var label: String {
        guard unnamed else { return title }
        return url.flatMap { URL(string: $0) }.map(Address.pretty) ?? url ?? ""
    }

    var host: String? {
        url.flatMap { URL(string: $0)?.host()?.lowercased() }
    }

    /// Its site, as its icon is kept: the host, and the port when there is one.
    var site: String? {
        url.flatMap { URL(string: $0) }.flatMap(Favicons.site)
    }

    static func site(_ title: String, _ url: URL) -> Bookmark {
        Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url.absoluteString, children: nil)
    }

    static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark {
        Bookmark(title: title, url: nil, children: children)
    }
}

@MainActor
final class Bookmarks: ObservableObject {
    @Published private(set) var roots: [Bookmark] = [] {
        didSet {
            revision &+= 1
            kept = preparedKept ?? Set(Bookmarks.urls(roots).map(\.absoluteString))
            preparedKept = nil
        }
    }
    /// The manager's window's, while the manager is open; changes made then
    /// can be undone there.
    weak var undo: UndoManager?
    private var revision = 0
    private var preparedKept: Set<String>?

    /// Every address kept, for `contains` — asked on every redraw of the
    /// button, which fills in on a page that is kept.
    private var kept: Set<String> = []

    init() { load() }

    var isEmpty: Bool { roots.isEmpty }

    /// How many sites, folders included.
    var count: Int { Bookmarks.count(roots) }

    nonisolated static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in the list, in order, folders opened.
    nonisolated static func urls(_ nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isFolder { return urls(node.children ?? []) }
            return node.url.flatMap(URL.init(string:)).map { [$0] } ?? []
        }
    }

    /// The addresses of every site among `nodes`, one to a line, on the pasteboard.
    static func copy(_ nodes: [Bookmark]) {
        let text = urls(nodes).map(\.absoluteString).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Every folder in the tree, each with how deep it sits — for "move to
    /// folder" lists, where a folder three deep should look like it.
    static func folders(_ nodes: [Bookmark], depth: Int = 0) -> [(node: Bookmark, depth: Int)] {
        nodes.flatMap { node -> [(Bookmark, Int)] in
            guard node.isFolder else { return [] }
            return [(node, depth)] + folders(node.children ?? [], depth: depth + 1)
        }
    }

    /// Every site and folder whose title or address holds all the words,
    /// with the folders it sits in — the same rule chrome.bookmarks.search
    /// keeps (see ExtensionShims.swift).
    func matches(_ text: String) -> [(node: Bookmark, path: [String])] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        func walk(_ nodes: [Bookmark], _ path: [String]) -> [(node: Bookmark, path: [String])] {
            nodes.flatMap { node -> [(node: Bookmark, path: [String])] in
                let hay = (node.title + " " + (node.url ?? "")).lowercased()
                let hit = words.allSatisfy { hay.contains($0) } ? [(node: node, path: path)] : []
                return hit + walk(node.children ?? [], path + [node.title])
            }
        }
        return walk(roots, [])
    }

    /// The folders `id` sits in, outermost first; empty at the top level,
    /// nil when it isn't here at all.
    func path(to id: Bookmark.ID) -> [Bookmark]? {
        func walk(_ nodes: [Bookmark], _ above: [Bookmark]) -> [Bookmark]? {
            for node in nodes {
                if node.id == id { return above }
                if let kids = node.children, let found = walk(kids, above + [node]) { return found }
            }
            return nil
        }
        return walk(roots, [])
    }

    /// The folder `id` sits in, nil at the top level.
    func parent(of id: Bookmark.ID) -> Bookmark.ID? {
        path(to: id)?.last?.id
    }

    /// The one kept for this address, wherever it is filed.
    func bookmark(for url: URL) -> Bookmark? {
        first { $0.url == url.absoluteString }
    }

    func bookmark(_ id: Bookmark.ID) -> Bookmark? {
        first { $0.id == id }
    }

    private func first(where test: (Bookmark) -> Bool) -> Bookmark? {
        func walk(_ nodes: [Bookmark]) -> Bookmark? {
            for node in nodes {
                if test(node) { return node }
                if let found = walk(node.children ?? []) { return found }
            }
            return nil
        }
        return walk(roots)
    }

    // MARK: - changing

    /// The page, at the end of the list. Nothing is asked first: the title
    /// is the page's, and the card that opens after (see BookmarkCard) is
    /// where it gets another name or a folder.
    @discardableResult
    func add(_ url: URL, title: String) -> Bookmark? {
        guard !contains(url) else { return nil }
        let made = Bookmark.site(title, url)
        commit(roots + [made], "Add Bookmark")
        return made
    }

    func contains(_ url: URL) -> Bool {
        kept.contains(url.absoluteString)
    }

    /// Where a change to the list is made: kept, and undoable while the
    /// manager is open. Undoing is itself a commit, so it can be redone.
    // ponytail: snapshot undo restores the whole tree, so it also reverts an extension's or import's change made after the undone one; per-operation inverses if that bites
    private func commit(_ tree: [Bookmark], _ action: String) {
        guard tree != roots else { return }
        let before = roots
        roots = tree
        save()
        guard let undo else { return }
        undo.registerUndo(withTarget: self) { $0.commit(before, action) }
        undo.setActionName(action)
    }

    /// Every one at once, whether it is a site or a folder with all it holds.
    func remove(_ ids: Set<Bookmark.ID>) {
        guard !ids.isEmpty else { return }
        commit(Bookmarks.prune(ids, from: roots), ids.count == 1 ? "Remove" : "Remove \(ids.count) Items")
    }

    func remove(_ id: Bookmark.ID) { remove([id]) }

    private static func prune(_ ids: Set<Bookmark.ID>, from nodes: [Bookmark]) -> [Bookmark] {
        nodes.compactMap { node in
            if ids.contains(node.id) { return nil }
            var copy = node
            if let kids = node.children { copy.children = prune(ids, from: kids) }
            return copy
        }
    }

    /// `ids` as they stand in the list, none inside another: the order they
    /// are read in, and a folder carries what is in it.
    func topmost(_ ids: some Collection<Bookmark.ID>) -> [Bookmark.ID] {
        let wanted = Set(ids)
        var found: [Bookmark.ID] = []
        func walk(_ nodes: [Bookmark]) {
            for node in nodes {
                if wanted.contains(node.id) { found.append(node.id) } else { walk(node.children ?? []) }
            }
        }
        walk(roots)
        return found
    }

    /// Takes bookmarks and whole folders out of wherever they sit and puts
    /// them, in the order the list reads, in another folder — or at the top
    /// level when `folderID` is nil — one after another from `index` among
    /// what is there, or at the end. The index is counted as the list reads
    /// before the move, so dropping a row just below itself leaves it where
    /// it was. Moving a folder into its own children is refused rather than
    /// allowed to erase it by looping it inside itself; moving it onto
    /// itself is simply nothing to do.
    func move(_ ids: [Bookmark.ID], into folderID: Bookmark.ID?, at index: Int? = nil) {
        let tops = topmost(ids)
        let nodes = tops.compactMap(bookmark)
        guard !nodes.isEmpty else { return }
        if let folderID, nodes.contains(where: { Bookmarks.holds(folderID, $0) }) { return }
        var at = index
        if let wanted = index {
            // They leave gaps above the place they go to.
            let leaving = Set(tops)
            at = max(wanted, 0) - siblings(of: folderID).prefix(max(wanted, 0)).filter { leaving.contains($0.id) }.count
        }
        var working = roots
        for id in tops { _ = Bookmarks.detach(id, from: &working) }
        for (i, node) in nodes.enumerated() {
            guard Bookmarks.place(node, in: folderID, at: at.map { $0 + i }, nodes: &working) else { return }
        }
        commit(working, nodes.count == 1 ? "Move" : "Move \(nodes.count) Items")
    }

    func move(_ id: Bookmark.ID, into folderID: Bookmark.ID?, at index: Int? = nil) {
        move([id], into: folderID, at: index)
    }

    /// The ones in `ids` in a new folder at the place the first of them was.
    /// Its id, nil if none of them is here.
    @discardableResult
    func group(_ ids: Set<Bookmark.ID>, named name: String) -> Bookmark.ID? {
        let tops = topmost(ids)
        guard let first = tops.first, let above = path(to: first) else { return nil }
        let parentID = above.last?.id
        guard let at = siblings(of: parentID).firstIndex(where: { $0.id == first }) else { return nil }
        let nodes = tops.compactMap(bookmark)
        var working = roots
        for id in tops { _ = Bookmarks.detach(id, from: &working) }
        let folder = Bookmark.folder(name, nodes)
        guard Bookmarks.place(folder, in: parentID, at: at, nodes: &working) else { return nil }
        commit(working, "New Folder")
        return folder.id
    }

    enum SortKey { case name, site }

    /// One folder's own list, or the top level for nil, folders first and
    /// each kind by name — or, for the bookmarks, by site and then name.
    /// What is inside a folder is left as it is.
    func sort(_ folderID: Bookmark.ID?, by key: SortKey) {
        func before(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        func site(_ node: Bookmark) -> String {
            let host = node.host ?? ""
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        func ordered(_ kids: [Bookmark]) -> [Bookmark] {
            kids.filter(\.isFolder).sorted { before($0.title, $1.title) }
                + kids.filter { !$0.isFolder }.sorted { a, b in
                    key == .site && site(a) != site(b) ? before(site(a), site(b)) : before(a.title, b.title)
                }
        }
        func walk(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.map { node in
                guard let kids = node.children else { return node }
                var copy = node
                copy.children = node.id == folderID ? ordered(kids) : walk(kids)
                return copy
            }
        }
        commit(folderID == nil ? ordered(roots) : walk(roots), "Sort")
    }

    /// Every bookmark whose address is already kept above it, in the order
    /// the list reads: the first of each stays.
    func duplicates() -> Set<Bookmark.ID> {
        var seen = Set<String>()
        var extra = Set<Bookmark.ID>()
        func walk(_ nodes: [Bookmark]) {
            for node in nodes {
                if let url = node.url, !seen.insert(url).inserted { extra.insert(node.id) }
                walk(node.children ?? [])
            }
        }
        walk(roots)
        return extra
    }

    /// The whole list at once, as one change that can be undone (Organize with AI).
    func replace(_ tree: [Bookmark], action: String) { commit(tree, action) }

    /// What a folder holds, or the top level for nil.
    private func siblings(of folderID: Bookmark.ID?) -> [Bookmark] {
        guard let folderID else { return roots }
        func walk(_ nodes: [Bookmark]) -> [Bookmark]? {
            for node in nodes {
                if node.id == folderID { return node.children ?? [] }
                if let found = walk(node.children ?? []) { return found }
            }
            return nil
        }
        return walk(roots) ?? []
    }

    private static func detach(_ id: Bookmark.ID, from nodes: inout [Bookmark]) -> Bookmark? {
        for i in nodes.indices {
            if nodes[i].id == id { return nodes.remove(at: i) }
            guard nodes[i].children != nil else { continue }
            var kids = nodes[i].children!
            if let found = detach(id, from: &kids) {
                nodes[i].children = kids
                return found
            }
        }
        return nil
    }

    /// `node` into the folder `id` (the top level for nil) at `index`,
    /// clamped to what is there, or at the end. False when there is no such
    /// folder.
    @discardableResult
    private static func place(_ node: Bookmark, in id: Bookmark.ID?, at index: Int?, nodes: inout [Bookmark]) -> Bool {
        guard let id else {
            nodes.insert(node, at: min(max(index ?? nodes.count, 0), nodes.count))
            return true
        }
        for i in nodes.indices {
            if nodes[i].id == id, nodes[i].isFolder {
                var kids = nodes[i].children ?? []
                kids.insert(node, at: min(max(index ?? kids.count, 0), kids.count))
                nodes[i].children = kids
                return true
            }
            guard var kids = nodes[i].children else { continue }
            if place(node, in: id, at: index, nodes: &kids) {
                nodes[i].children = kids
                return true
            }
        }
        return false
    }

    /// `id` is `node` itself, or somewhere inside it — also used by the
    /// outline to keep a folder out of its own "move to" list.
    fileprivate static func holds(_ id: Bookmark.ID, _ node: Bookmark) -> Bool {
        node.id == id || (node.children ?? []).contains { holds(id, $0) }
    }

    /// Another browser's, kept apart in a folder of that browser's name
    /// unless there was nothing here yet. Bringing them in again adds only
    /// what is new — a page already in the same place is left as it is, a
    /// folder of the same name is gone into — and never takes away what
    /// you have added or moved since. Returns how many pages came in, and
    /// how many were already here.
    @discardableResult
    func take(_ nodes: [Bookmark], from name: String) -> (added: Int, already: Int) {
        let taken = takeNoting(nodes, from: name)
        return (taken.added, taken.already)
    }

    /// The same, and which bookmarks and folders it added — every one, so
    /// they can be taken back out exactly (see ImportRecord).
    func takeNoting(_ nodes: [Bookmark], from name: String) -> (added: Int, already: Int, ids: [Bookmark.ID]) {
        guard !nodes.isEmpty else { return (0, 0, []) }
        var added = 0, already = 0
        var ids: [Bookmark.ID] = []
        if roots.isEmpty {
            roots = nodes
            added = Bookmarks.count(nodes)
            ids = Bookmarks.ids(nodes)
            Store.settings.set(name, forKey: Bookmarks.topKey)
        } else if intoTop(nodes, from: name) {
            Bookmarks.merge(nodes, into: &roots, added: &added, already: &already, ids: &ids)
        } else {
            var kids = roots.first { $0.isFolder && $0.title == name }?.children ?? []
            Bookmarks.merge(nodes, into: &kids, added: &added, already: &already, ids: &ids)
            if let at = roots.firstIndex(where: { $0.isFolder && $0.title == name }) {
                roots[at].children = kids
            } else {
                let folder = Bookmark.folder(name, kids)
                ids.append(folder.id)
                roots.append(folder)
            }
        }
        save()
        return (added, already, ids)
    }

    /// Prepare a potentially large file merge away from the UI thread. A live
    /// edit wins: if bookmarks changed while preparing, merge a fresh snapshot.
    func takeFile(_ incoming: [Bookmark], from name: String, control: ImportFile.Control) async throws -> (added: Int, already: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        while true {
            try control.checkCancellation()
            let snapshot = roots
            let version = revision
            let top = Store.settings.string(forKey: Bookmarks.topKey)
            let prepared: (roots: [Bookmark], kept: Set<String>, added: Int, already: Int, top: Bool) = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try control.checkCancellation()
                        var output = snapshot
                        var added = 0, already = 0
                        var setTop = false
                        if snapshot.isEmpty {
                            output = incoming
                            added = try Bookmarks.fileCount(incoming, control: control)
                            setTop = true
                        } else {
                            let intoTop: Bool
                            if let top { intoTop = top == name }
                            else {
                                let theirs = try Bookmarks.fileURLs(incoming, control: control)
                                let ours = Set(try Bookmarks.fileURLs(snapshot, control: control))
                                intoTop = !theirs.isEmpty && theirs.filter { ours.contains($0) }.count * 2 >= theirs.count
                                setTop = intoTop
                            }
                            if intoTop {
                                try Bookmarks.mergeFile(incoming, into: &output, added: &added, already: &already, control: control)
                            } else {
                                var kids = output.first { $0.isFolder && $0.title == name }?.children ?? []
                                try Bookmarks.mergeFile(incoming, into: &kids, added: &added, already: &already, control: control)
                                if let at = output.firstIndex(where: { $0.isFolder && $0.title == name }) {
                                    output[at].children = kids
                                } else {
                                    output.append(.folder(name, kids))
                                }
                            }
                        }
                        try control.checkCancellation()
                        continuation.resume(returning: (output, Set(try Bookmarks.fileURLs(output, control: control)), added, already, setTop))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try control.checkCancellation()
            guard revision == version, Store.settings.string(forKey: Bookmarks.topKey) == top else { continue }
            preparedKept = prepared.kept
            roots = prepared.roots
            if prepared.top { Store.settings.set(name, forKey: Bookmarks.topKey) }
            save()
            return (prepared.added, prepared.already)
        }
    }

    /// Takes back out what an import added: every bookmark among `ids`
    /// wherever it now sits, then every folder among them left empty. A
    /// folder of theirs that you have put something of your own in stays,
    /// with that in it. Returns how many bookmarks went.
    @discardableResult
    func withdraw(_ ids: [Bookmark.ID]) -> Int {
        let ours = Set(ids)
        var gone = 0
        func strip(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.compactMap { node in
                if !node.isFolder, ours.contains(node.id) {
                    gone += 1
                    return nil
                }
                guard let kids = node.children else { return node }
                var copy = node
                copy.children = strip(kids)
                if ours.contains(node.id), copy.children?.isEmpty == true { return nil }
                return copy
            }
        }
        roots = strip(roots)
        save()
        return gone
    }

    /// Every id in a tree, folders and all.
    nonisolated static func ids(_ nodes: [Bookmark]) -> [Bookmark.ID] {
        nodes.flatMap { [$0.id] + ids($0.children ?? []) }
    }

    nonisolated private static func fileURLs(_ nodes: [Bookmark], control: ImportFile.Control) throws -> [String] {
        var urls: [String] = []
        var pending = nodes
        var scanned = 0
        while let node = pending.popLast() {
            scanned += 1
            if scanned % 256 == 0 {
                try control.checkCancellation()
            }
            if let url = node.url, let canonical = URL(string: url)?.absoluteString { urls.append(canonical) }
            if let children = node.children { pending.append(contentsOf: children) }
        }
        try control.checkCancellation()
        return urls
    }

    nonisolated private static func fileCount(_ nodes: [Bookmark], control: ImportFile.Control) throws -> Int {
        var count = 0
        var scanned = 0
        var pending = nodes
        while let node = pending.popLast() {
            scanned += 1
            if scanned % 256 == 0 { try control.checkCancellation() }
            if node.isFolder { pending.append(contentsOf: node.children ?? []) }
            else { count += 1 }
        }
        try control.checkCancellation()
        return count
    }

    nonisolated private static func mergeFile(_ incoming: [Bookmark], into nodes: inout [Bookmark], added: inout Int, already: inout Int, control: ImportFile.Control) throws {
        var folders: [String: Int] = [:]
        var pages = Set<String>()
        for (index, node) in nodes.enumerated() {
            if index % 256 == 0 { try control.checkCancellation() }
            if node.isFolder { if folders[node.title] == nil { folders[node.title] = index } }
            else if let url = node.url { pages.insert(url) }
        }
        for (index, node) in incoming.enumerated() {
            if index % 256 == 0 {
                try control.checkCancellation()
            }
            if node.isFolder {
                if let at = folders[node.title] {
                    var kids = nodes[at].children ?? []
                    try mergeFile(node.children ?? [], into: &kids, added: &added, already: &already, control: control)
                    nodes[at].children = kids
                } else {
                    folders[node.title] = nodes.count
                    nodes.append(node)
                    added += try fileCount([node], control: control)
                }
            } else if pages.contains(node.url ?? "") {
                already += 1
            } else {
                if let url = node.url { pages.insert(url) }
                nodes.append(node)
                added += 1
            }
        }
    }

    /// Which browser filled the empty top level, the first time.
    private static let topKey = "bookmarks.top"

    /// Whether this browser's bookmarks belong at the top level: it filled
    /// it the first time — or, from before that was noted, most of its
    /// pages are already there.
    private func intoTop(_ nodes: [Bookmark], from name: String) -> Bool {
        if let top = Store.settings.string(forKey: Bookmarks.topKey) { return top == name }
        let theirs = Bookmarks.urls(nodes).map(\.absoluteString)
        guard !theirs.isEmpty else { return false }
        let ours = Set(Bookmarks.urls(roots).map(\.absoluteString))
        let shared = theirs.filter { ours.contains($0) }.count
        guard shared * 2 >= theirs.count else { return false }
        Store.settings.set(name, forKey: Bookmarks.topKey)
        return true
    }

    /// `incoming` into `nodes`, level by level: a folder into the folder of
    /// the same name, a page only if the same address isn't already at
    /// that level.
    nonisolated private static func merge(_ incoming: [Bookmark], into nodes: inout [Bookmark], added: inout Int, already: inout Int, ids: inout [Bookmark.ID]) {
        var folders: [String: Int] = [:]
        for (index, node) in nodes.enumerated() where node.isFolder {
            if folders[node.title] == nil { folders[node.title] = index }
        }
        var pages = Set(nodes.compactMap { $0.isFolder ? nil : $0.url })
        for node in incoming {
            if node.isFolder {
                if let at = folders[node.title] {
                    var kids = nodes[at].children ?? []
                    merge(node.children ?? [], into: &kids, added: &added, already: &already, ids: &ids)
                    nodes[at].children = kids
                } else {
                    folders[node.title] = nodes.count
                    nodes.append(node)
                    added += count([node])
                    ids += Bookmarks.ids([node])
                }
            } else if pages.contains(node.url ?? "") {
                already += 1
            } else {
                if let url = node.url { pages.insert(url) }
                nodes.append(node)
                added += 1
                ids.append(node.id)
            }
        }
    }

    // MARK: - the file

    private static var file: URL { Store.file("bookmarks.json") }

    // MARK: - for extensions

    /// A page or a folder filed under `parent` at `index`, or at the top
    /// level for nil or a folder that isn't there. What
    /// chrome.bookmarks.create does.
    @discardableResult
    func insert(_ node: Bookmark, into parent: Bookmark.ID?, at index: Int? = nil) -> Bookmark {
        var nodes = roots
        if !Bookmarks.place(node, in: parent, at: index, nodes: &nodes) {
            Bookmarks.place(node, in: nil, at: index, nodes: &nodes)
        }
        commit(nodes, node.isFolder ? "New Folder" : "Add Bookmark")
        return node
    }

    /// A folder of your own, its name asked for as a rename's is: inside
    /// `parent`, or at the top level for nil. An empty name makes none.
    func askNewFolder(in parent: Bookmark.ID?, made: @escaping (Bookmark.ID) -> Void = { _ in }) {
        Ask.name("New Folder", placeholder: "Folder name", confirm: "Make") { name in
            made(self.insert(.folder(name, []), into: parent).id)
        }
    }

    /// A folder named by the user, with `nodes` moved into it, where the first
    /// of them was. An empty name makes none.
    func askGroup(_ nodes: [Bookmark], made: @escaping (Bookmark.ID) -> Void = { _ in }) {
        Ask.name("New Folder with Selection", placeholder: "Folder name", confirm: "Make") { name in
            if let id = self.group(Set(nodes.map(\.id)), named: name) { made(id) }
        }
    }

    /// A folder with bookmarks in it asks first: they all go with it, and
    /// there is no taking it back. Anything else goes at once.
    func askRemove(_ nodes: [Bookmark]) {
        let full = nodes.filter { $0.isFolder && !($0.children ?? []).isEmpty }
        guard !full.isEmpty else { return remove(Set(nodes.map(\.id))) }
        let count = Bookmarks.count(full.flatMap { $0.children ?? [] })
        let them = full.count == 1 ? "it" : "them"
        let detail = switch count {
        case 0: "The empty folders in \(them) go too."
        case 1: "The bookmark in \(them) goes too."
        default: "The \(count) bookmarks in \(them) go too."
        }
        let title = nodes.count == 1 ? "Remove \u{201C}\(nodes[0].title)\u{201D}?" : "Remove \(nodes.count) items?"
        Ask.sure(title, detail: detail, confirm: "Remove") {
            self.remove(Set(nodes.map(\.id)))
        }
    }

    /// A new title or address for one that is kept. chrome.bookmarks.update,
    /// and Rename… in the list's right-click menu.
    func update(_ id: Bookmark.ID, title: String?, url: String?) {
        func walk(_ nodes: inout [Bookmark]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    if let title { nodes[i].title = title }
                    if let url, !nodes[i].isFolder { nodes[i].url = url }
                    return true
                }
                guard var kids = nodes[i].children else { continue }
                if walk(&kids) {
                    nodes[i].children = kids
                    return true
                }
            }
            return false
        }
        var nodes = roots
        if walk(&nodes) { commit(nodes, "Edit") }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Bookmarks.file) else { return }
        guard let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            Store.quarantine(Bookmarks.file)
            return
        }
        roots = list
    }

    private func save() {
        let snapshot = roots
        // One after another, the newest last (see Disk).
        Disk.write(Bookmarks.file) { try? JSONEncoder().encode(snapshot) }
    }
}

// MARK: - what the manager has picked

/// What the manager has picked, what it is looking for and which folders
/// are open, kept by the window so its keys (ContentView.take) reach it.
@MainActor
final class BookmarkPicks: ObservableObject {
    @Published var ids: Set<Bookmark.ID> = []
    @Published var query = ""
    @Published var expanded: Set<Bookmark.ID> = []
    var anchor: Bookmark.ID?
    /// The AI's proposal for the list, shown in place of it until applied or discarded.
    @Published var proposal: AIBookmarks.Proposal?
    /// What the manager says while the AI is asked; nil otherwise.
    @Published var organizing: String?
    var organizeTask: Task<Void, Never>?

    /// A click on a row: ⇧ takes the rows from the last one clicked to this
    /// one, ⌘ adds it or takes it away, and a plain click is that row alone.
    /// `order` is the rows as they read, top to bottom.
    func click(_ id: Bookmark.ID, flags: NSEvent.ModifierFlags, order: [Bookmark.ID]) {
        if flags.contains(.shift), let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            ids = Set(order[min(from, to)...max(from, to)])
        } else if flags.contains(.command) {
            if ids.remove(id) == nil { ids.insert(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }

    func reset() {
        ids = []
        query = ""
        expanded = []
        anchor = nil
        organizeTask?.cancel()
        organizeTask = nil
        organizing = nil
        proposal = nil
    }
}

extension Browser {
    /// Every page among `nodes`, folders opened, in order: background tabs
    /// here, or a new window of their own. A great many ask first.
    func openBookmarks(_ nodes: [Bookmark], inNewWindow: Bool) {
        let urls = Bookmarks.urls(nodes)
        guard !urls.isEmpty else { return }
        func go() {
            if inNewWindow {
                let made = Browser(record: WindowRecord(space: spaceID))
                Browsers.open(made, frame: nil)
                made.visit(urls[0])
                urls.dropFirst().forEach { made.open($0, foreground: false, atEnd: true, mayWait: true) }
            } else {
                urls.forEach { open($0, foreground: false, atEnd: true, mayWait: true) }
            }
        }
        if urls.count > 20 {
            Ask.sure("Open \(urls.count) pages?", detail: "Each in a tab of its own.", confirm: "Open", then: go)
        } else {
            go()
        }
    }
}

// MARK: - the tree, drawn

/// The list itself: folders that open in place rather than to the side, each
/// row draggable above or below another, or into a folder, each row good
/// for a right-click too. Used both in the small dropdown off the button and
/// in the full manager — the interaction is the same size either way.
struct BookmarkOutline: View {
    @ObservedObject var bookmarks: Bookmarks
    /// The folders open, kept by whoever shows the outline, so the manager
    /// can open the way down to one it was asked to show.
    @Binding var expanded: Set<Bookmark.ID>
    /// A row to wash for a moment, after a search showed where it is.
    var shown: Bookmark.ID? = nil
    let open: (URL) -> Void
    let openInNewTab: (URL) -> Void
    /// What the manager has picked; nil where a click just opens (the dropdown).
    var picks: BookmarkPicks? = nil
    /// Bookmarks or a folder opened, in new tabs here or in a new window.
    var openAll: ([Bookmark], Bool) -> Void = { _, _ in }

    @State private var dragging: Set<Bookmark.ID> = []
    /// Where the drag under way would land, drawn as a line or a wash.
    @State private var aimed: Aim?
    /// A closed folder held over opens after a moment, so a bookmark can go
    /// deep without being dropped on the way.
    @State private var spring: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rows(bookmarks.roots, depth: 0, parent: nil)
            // Past the last row: the end of the top level, which "after" on
            // an open folder at the bottom can't reach. Only there while a
            // row is carried, or it is an empty band under the list (#391).
            if !dragging.isEmpty {
                Color.clear
                    .frame(height: 10)
                    .overlay(alignment: .top) { if aimed == Aim(id: nil, zone: .after) { Line(depth: 0) } }
                    .modifier(Landing(
                        isFolder: false,
                        allowed: { true },
                        aim: { aim($0.map { _ in Aim(id: nil, zone: .after) }) },
                        land: { _, providers in drop(providers) { bookmarks.move($0, into: nil) } }
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rows(_ nodes: [Bookmark], depth: Int, parent: Bookmark.ID?) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
            let isOpen = node.isFolder && expanded.contains(node.id)
            Row(
                node: node,
                depth: depth,
                // A folder's arrow has a place in front of every row, so the
                // icons line up; with no folder at all, it is only a gap.
                arrows: bookmarks.roots.contains(where: \.isFolder),
                // An extension can write an address that does not parse,
                // and the menu below already unwraps this the same way.
                isOpen: isOpen,
                dragging: dragging.contains(node.id),
                selected: picks?.ids.contains(node.id) == true,
                aim: aimed?.id == node.id ? aimed?.zone : nil,
                shown: shown == node.id,
                tap: { tapped(node) },
                toggle: node.isFolder ? { toggle(node.id) } : nil,
                menu: AnyView(actions(for: node))
            )
            .id(node.id)
            .overlay {
                if let url = node.url.flatMap(URL.init(string:)) {
                    MiddleClick { openInNewTab(url) }
                }
            }
            .onDrag {
                // The whole selection, if this row is in it.
                let ids = picks?.ids.contains(node.id) == true ? bookmarks.topmost(picks?.ids ?? []) : [node.id]
                dragging = Set(ids)
                settleWhenLetGo()
                return NSItemProvider(object: ids.map(\.uuidString).joined(separator: "\n") as NSString)
            }
            .modifier(Landing(
                isFolder: node.isFolder,
                allowed: { allows(node.id) },
                aim: { aim($0.map { Aim(id: node.id, zone: $0) }) },
                land: { zone, providers in
                    drop(providers) { ids in
                        switch zone {
                        case .before: bookmarks.move(ids, into: parent, at: index)
                        // Below an open folder's row is above its first
                        // child, so that is where it goes.
                        case .after where isOpen: bookmarks.move(ids, into: node.id, at: 0)
                        case .after: bookmarks.move(ids, into: parent, at: index + 1)
                        case .into: bookmarks.move(ids, into: node.id)
                        }
                    }
                }
            ))

            if isOpen {
                if let kids = node.children, !kids.isEmpty {
                    // Type-erased: a view that calls itself can't let Swift
                    // infer its own opaque return type from its own body.
                    AnyView(rows(kids, depth: depth + 1, parent: node.id))
                } else {
                    // Where its first bookmark would be, so a drop here goes
                    // in, shown as the folder's own lower edge shows it.
                    Text("Empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, indent(depth + 1) + 26)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .modifier(Landing(
                            isFolder: false,
                            allowed: { allows(node.id) },
                            aim: { aim($0.map { _ in Aim(id: node.id, zone: .after) }) },
                            land: { _, providers in drop(providers) { bookmarks.move($0, into: node.id) } }
                        ))
                }
            }
        }
    }

    private func toggle(_ id: Bookmark.ID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// The rows as they read, top to bottom, for a ⇧-click's range and ⌘A.
    static func visible(_ roots: [Bookmark], open: Set<Bookmark.ID>) -> [Bookmark.ID] {
        roots.flatMap { node in
            [node.id] + (node.isFolder && open.contains(node.id) ? visible(node.children ?? [], open: open) : [])
        }
    }

    /// A click on a row. Where a click only opens, it opens a bookmark and
    /// toggles a folder. In the manager it picks, and a double-click opens.
    private func tapped(_ node: Bookmark) {
        if let picks, NSApp.currentEvent?.clickCount != 2 {
            picks.click(node.id, flags: NSApp.currentEvent?.modifierFlags ?? [], order: Self.visible(bookmarks.roots, open: expanded))
        } else if node.isFolder {
            toggle(node.id)
        } else if let text = node.url, let url = URL(string: text) {
            open(url)
        }
    }

    /// What a right-click acts on: every row picked, if this is one of
    /// several, and otherwise this row alone.
    private func targets(for node: Bookmark) -> [Bookmark] {
        guard let picks, picks.ids.contains(node.id) else { return [node] }
        let all = bookmarks.topmost(picks.ids).compactMap(bookmarks.bookmark)
        return all.count > 1 ? all : [node]
    }

    /// The "Move to" list: the top level and every folder the rows can go
    /// into, none inside what is being moved.
    @ViewBuilder
    static func moveItems(_ bookmarks: Bookmarks, _ nodes: [Bookmark]) -> some View {
        Button("Top Level") { bookmarks.move(nodes.map(\.id), into: nil) }
        let into = Bookmarks.folders(bookmarks.roots).filter { target in !nodes.contains { Bookmarks.holds(target.node.id, $0) } }
        if !into.isEmpty {
            Divider()
            ForEach(into, id: \.node.id) { target in
                Button(String(repeating: "   ", count: target.depth) + target.node.title) {
                    bookmarks.move(nodes.map(\.id), into: target.node.id)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for node: Bookmark) -> some View {
        let targets = targets(for: node)
        if targets.count > 1 {
            Button("Open \(targets.count) in New Tabs") { openAll(targets, false) }
            Button("Open in New Window") { openAll(targets, true) }
            Divider()
            Button("New Folder with Selection…") { group(targets) }
            Button("Copy Addresses") { Bookmarks.copy(targets) }
            Menu("Move to") { Self.moveItems(bookmarks, targets) }
            Divider()
            Button("Remove \(targets.count) Items", role: .destructive) { bookmarks.askRemove(targets) }
        } else if node.isFolder {
            if Bookmarks.count(node.children ?? []) > 0 {
                Button("Open All in New Tabs") { openAll([node], false) }
                Button("Open All in New Window") { openAll([node], true) }
                Divider()
            }
            Button("Rename…") { rename(node) }
            Button("New Folder Inside…") {
                bookmarks.askNewFolder(in: node.id) { _ in expanded.insert(node.id) }
            }
            Menu("Sort") {
                Button("By Name") { bookmarks.sort(node.id, by: .name) }
                Button("By Site") { bookmarks.sort(node.id, by: .site) }
            }
            Menu("Move to") { Self.moveItems(bookmarks, [node]) }
            Divider()
            Button("Remove", role: .destructive) { bookmarks.askRemove([node]) }
        } else {
            if let url = node.url.flatMap(URL.init(string:)) {
                Button("Open") { open(url) }
                Button("Open in New Tab") { openInNewTab(url) }
                Button("Open in New Window") { openAll([node], true) }
                Divider()
            }
            Button("Edit…") { edit(node) }
            Button("Copy Address") { Bookmarks.copy([node]) }
            Menu("Move to") { Self.moveItems(bookmarks, [node]) }
            Divider()
            Button("Remove", role: .destructive) { bookmarks.askRemove([node]) }
        }
    }

    /// The rows into a new folder, named first, and shown open.
    private func group(_ nodes: [Bookmark]) {
        bookmarks.askGroup(nodes) { made in
            expanded.formUnion((bookmarks.path(to: made) ?? []).map(\.id))
            expanded.insert(made)
        }
    }

    /// A new name and address for a bookmark, in one sheet.
    private func edit(_ node: Bookmark) {
        Ask.bookmark(name: node.title, address: node.url ?? "") { name, address in
            let url = Address.url(from: address)
            if !address.isEmpty, url == nil { NSSound.beep() }
            bookmarks.update(node.id, title: name.isEmpty ? nil : name, url: url?.absoluteString)
        }
    }

    /// A name of your own for a bookmark or a folder, asked for the way a
    /// space's is: the page's title is what a bookmark starts with, and a
    /// folder brought in from another browser is called after it. The name
    /// it has arrives in the field. An empty one changes nothing for a
    /// folder; a bookmark left without one is its icon alone on the bar.
    private func rename(_ node: Bookmark) {
        if node.isFolder {
            Ask.name("Rename Folder", placeholder: node.title, initial: node.title, confirm: "Rename") {
                bookmarks.update(node.id, title: $0, url: nil)
            }
        } else {
            Ask.name("Rename Bookmark", detail: "Without a name, the bookmarks bar shows its icon alone.",
                     placeholder: node.label, initial: node.title, confirm: "Rename", empty: true) {
                bookmarks.update(node.id, title: $0, url: nil)
            }
        }
    }

    /// A folder can't go above, below or into anything inside itself, nor can
    /// the rows carried with it.
    private func allows(_ target: Bookmark.ID) -> Bool {
        guard !dragging.isEmpty else { return true }
        return !dragging.contains(target) && !(bookmarks.path(to: target) ?? []).contains { dragging.contains($0.id) }
    }

    private func aim(_ target: Aim?) {
        guard target != aimed else { return }
        aimed = target
        spring?.cancel()
        spring = nil
        guard let target, target.zone == .into, let id = target.id, !expanded.contains(id) else { return }
        let expanded = $expanded
        let work = DispatchWorkItem { withAnimation(Motion.settle) { _ = expanded.wrappedValue.insert(id) } }
        spring = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// SwiftUI says when a row lands on the list, not when it is let go
    /// anywhere else or the drag is called off, which left the line where
    /// it was last aimed and the row faded (#391). The button coming up says
    /// it: looked at a few times a second, which a drag's own loop holds
    /// back until it is over.
    private func settleWhenLetGo() {
        let aimed = $aimed, dragging = $dragging, spring = $spring
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                spring.wrappedValue?.cancel()
                spring.wrappedValue = nil
                aimed.wrappedValue = nil
                dragging.wrappedValue = []
            }
        }
    }

    private func drop(_ providers: [NSItemProvider], then move: @escaping ([Bookmark.ID]) -> Void) -> Bool {
        aim(nil)
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            let ids = (text ?? "").split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async {
                withAnimation(Motion.settle) { move(ids) }
                self.dragging = []
            }
        }
        return true
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 18 }

    enum Zone { case before, into, after }

    /// A row and where on it; no row is the end of the list.
    struct Aim: Equatable {
        let id: Bookmark.ID?
        let zone: Zone
    }

    /// The line where a dragged row would go.
    private struct Line: View {
        let depth: Int
        var body: some View {
            Capsule()
                .fill(Palette.ink.opacity(0.55))
                .frame(height: 2)
                .padding(.leading, CGFloat(depth) * 18 + 10)
                .padding(.trailing, 10)
        }
    }

    /// Every row takes a drop: the top of it means above, the bottom below,
    /// and the middle of a folder means into it. Which part the pointer is
    /// over is only known against the row's height, so it is measured.
    private struct Landing: ViewModifier {
        let isFolder: Bool
        let allowed: () -> Bool
        let aim: (Zone?) -> Void
        let land: (Zone, [NSItemProvider]) -> Bool

        @State private var height: CGFloat = 1

        func body(content: Content) -> some View {
            content
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = max($0, 1) }
                .onDrop(of: [.text], delegate: Spot(landing: self))
        }

        func zone(at y: CGFloat) -> Zone {
            let part = y / height
            guard isFolder else { return part < 0.5 ? .before : .after }
            return part < 0.25 ? .before : part > 0.75 ? .after : .into
        }

        private struct Spot: DropDelegate {
            let landing: Landing

            func dropUpdated(info: DropInfo) -> DropProposal? {
                guard landing.allowed() else {
                    landing.aim(nil)
                    return DropProposal(operation: .forbidden)
                }
                landing.aim(landing.zone(at: info.location.y))
                return DropProposal(operation: .move)
            }

            func dropExited(info: DropInfo) { landing.aim(nil) }

            func performDrop(info: DropInfo) -> Bool {
                guard landing.allowed() else { return false }
                return landing.land(landing.zone(at: info.location.y), info.itemProviders(for: [.text]))
            }
        }
    }

    private struct Row: View {
        let node: Bookmark
        let depth: Int
        let arrows: Bool
        let isOpen: Bool
        let dragging: Bool
        /// Picked in the manager.
        let selected: Bool
        /// Where a drag over this row would land, if one is.
        let aim: Zone?
        let shown: Bool
        let tap: () -> Void
        /// Nil for a bookmark.
        let toggle: (() -> Void)?
        let menu: AnyView

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                if node.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 16, height: 15)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle?() }
                    Mark(icon: nil, letter: "", size: 15)
                        .overlay(
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.muted)
                        )
                } else {
                    if arrows { Spacer().frame(width: 16) }
                    Mark(icon: Favicons.shared.cached(node.site ?? ""), letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 15)
                }
                // One without a name reads as its address, a shade lighter.
                Text(node.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(node.unnamed ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if node.isFolder, let kids = node.children, !kids.isEmpty {
                    Text("\(Bookmarks.count(kids))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.leading, CGFloat(depth) * 18 + 10)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(wash))
            .overlay(alignment: aim == .before ? .top : .bottom) {
                if aim == .before || aim == .after {
                    // Below an open folder is its first child's place.
                    Line(depth: aim == .after && isOpen ? depth + 1 : depth)
                        .offset(y: aim == .before ? -1.5 : 1.5)
                }
            }
            .contentShape(Rectangle())
            .opacity(dragging ? 0.35 : 1)
            .onTapGesture(perform: tap)
            .onHover { hovering = $0 }
            .contextMenu { menu }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: dragging)
            .animation(Motion.quick, value: aim)
            .animation(Motion.settle, value: shown)
        }

        private var wash: Color {
            if aim == .into || shown || selected { return Palette.hover }
            return hovering ? Palette.wash : .clear
        }
    }
}

/// The bookmark button, in the row or at the foot of the column: filled on
/// a page that is kept, and what hangs off it — the card for one bookmark
/// when ⇧⌘B opened it, the list otherwise.
struct BookmarkDoor: View {
    @ObservedObject var browser: Browser
    let arrowEdge: Edge

    var body: some View {
        Group {
            if let tab = browser.active {
                Kept(browser: browser, bookmarks: browser.bookmarks, tab: tab)
            } else {
                BookmarkDoor.door(browser, kept: false)
            }
        }
        .popover(isPresented: $browser.bookmarksOpen, arrowEdge: arrowEdge) {
            if let id = browser.bookmarkCard {
                BookmarkCard(browser: browser, bookmarks: browser.bookmarks, id: id)
            } else {
                BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
            }
        }
    }

    fileprivate static func door(_ browser: Browser, kept: Bool) -> some View {
        Door(icon: kept ? "bookmark.fill" : "bookmark", help: "Bookmarks") { browser.toggleBookmarks() }
    }

    /// Watches the tab for where it goes and the bookmarks for what is
    /// kept, so the button fills and empties with either.
    private struct Kept: View {
        let browser: Browser
        @ObservedObject var bookmarks: Bookmarks
        @ObservedObject var tab: Tab

        var body: some View {
            BookmarkDoor.door(browser, kept: tab.address.map(bookmarks.contains) ?? false)
        }
    }
}

/// What ⇧⌘B opens off the button: the page just kept, or kept before, with
/// its name to change and a folder to file it in. Each change is kept as it
/// is made, so Done, Return, Escape and a click elsewhere all only close it.
struct BookmarkCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks
    let id: Bookmark.ID

    @State private var title = ""
    @FocusState private var naming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bookmarked")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)

            VStack(spacing: 8) {
                line("Name") {
                    // Emptied, the field shows what the lists will read.
                    TextField(bookmarks.bookmark(id)?.url.flatMap(URL.init(string:)).map(Address.pretty) ?? "", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .focused($naming)
                        .onSubmit(close)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onChange(of: title) { _, typed in rename(typed) }
                }
                line("Folder") { folder }
            }

            HStack(spacing: 8) {
                Quick("Remove", tint: .red.opacity(0.75)) {
                    close()
                    bookmarks.remove(id)
                }
                Spacer(minLength: 0)
                Pill("Done", filled: true, action: close)
            }
        }
        .padding(14)
        .frame(width: 280)
        .popoverGround(card: true)
        .onAppear {
            title = bookmarks.bookmark(id)?.title ?? ""
            // The popover's window takes the keyboard only after this, and
            // gives it to the first button it finds unless told otherwise.
            DispatchQueue.main.async { naming = true }
        }
    }

    /// Where it is filed, and every other folder to file it in.
    private var folder: some View {
        let here = bookmarks.path(to: id)?.last
        return Menu {
            Button("Top Level") { bookmarks.move(id, into: nil) }
            let folders = Bookmarks.folders(bookmarks.roots)
            if !folders.isEmpty {
                Divider()
                ForEach(folders, id: \.node.id) { target in
                    Button(String(repeating: "   ", count: target.depth) + target.node.title) {
                        bookmarks.move(id, into: target.node.id)
                    }
                }
            }
            Divider()
            Button("New Folder\u{2026}") {
                Ask.name("New Folder", placeholder: "Name", confirm: "Create") { name in
                    let made = bookmarks.insert(.folder(name, []), into: nil)
                    bookmarks.move(id, into: made.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                Text(here?.title ?? "Top Level")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func line(_ name: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .frame(width: 42, alignment: .leading)
            control()
        }
    }

    /// An empty name is kept as empty: the bookmarks bar then shows the
    /// bookmark's icon alone, as Chrome's and Safari's do.
    private func rename(_ typed: String) {
        BookmarkCard.rename(id, typed, in: bookmarks)
    }

    /// The same, for the bench.
    static func rename(_ id: Bookmark.ID, _ typed: String, in bookmarks: Bookmarks) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != bookmarks.bookmark(id)?.title else { return }
        bookmarks.update(id, title: name, url: nil)
    }

    private func close() {
        browser.bookmarksOpen = false
    }
}

/// The button's dropdown: the tree, and the two things that aren't in it.
struct BookmarksDropdown: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    @State private var expanded: Set<Bookmark.ID>

    init(browser: Browser, bookmarks: Bookmarks) {
        self.browser = browser
        self.bookmarks = bookmarks
        _expanded = State(initialValue: Self.opening(bookmarks.roots))
    }

    /// Open as the list opens: a top level that is one folder and nothing
    /// else, as bringing bookmarks in from another browser often leaves
    /// ("Dia", "Imported from Chrome"). Closed, it was one row in a list
    /// sized for all it holds (see listHeight).
    static func opening(_ roots: [Bookmark]) -> Set<Bookmark.ID> {
        guard roots.count == 1, let only = roots.first, only.isFolder else { return [] }
        return [only.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bookmarks.isEmpty {
                Text("No bookmarks yet — nothing pocketed")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    BookmarkOutline(bookmarks: bookmarks, expanded: $expanded, open: { url in
                        browser.pickBookmark(url)
                    }, openInNewTab: { url in
                        browser.pickBookmark(url, inNewTab: true)
                    }, openAll: { browser.openBookmarks($0, inNewWindow: $1) })
                    .padding(6)
                }
                .frame(height: listHeight)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot(browser.pageKept ? "bookmark.fill" : "bookmark", browser.pageKept ? "Edit This Bookmark\u{2026}" : "Add This Page") {
                    browser.bookmarkCurrent()
                }
                Foot(nil, "Manage Bookmarks…") { browser.bookmarking = true }
            }
            .padding(6)
        }
        .frame(width: 280)
        .popoverGround(card: true)
    }

    /// The list as tall as the whole tree would be with every folder open,
    /// up to 360 points. The popover takes its height once, from what the
    /// list holds as it opens, and doesn't grow with a folder opened in it:
    /// a list of one closed folder was one row high, and the folder opened
    /// into a sliver above Add This Page.
    var listHeight: CGFloat {
        let most: CGFloat = 360
        var lines = 0
        Self.count(bookmarks.roots, into: &lines, upTo: Int(most / Self.line) + 1)
        return min(most, CGFloat(lines) * Self.line + 12)
    }

    /// A row's height and the gap under it (see BookmarkOutline.Row).
    private static let line: CGFloat = 28

    /// Every row with every folder open, an empty one's "Empty" included,
    /// counted only as far as the list can be tall.
    private static func count(_ nodes: [Bookmark], into lines: inout Int, upTo limit: Int) {
        for node in nodes {
            guard lines < limit else { return }
            lines += 1
            guard node.isFolder else { continue }
            if let kids = node.children, !kids.isEmpty { count(kids, into: &lines, upTo: limit) } else { lines += 1 }
        }
    }

    private struct Foot: View {
        let symbol: String?
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String?, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

/// The bookmarks in a column of their own beside the page (Bookmarks ›
/// Show Bookmarks Sidebar): the dropdown's tree, a click opening a page,
/// a drag putting it in order. Picking several and undo are the manager's.
struct BookmarksSidebar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks
    /// On the window's left edge, so the line between it and the page is on its right.
    let onLeft: Bool
    @State private var expanded: Set<Bookmark.ID>

    init(browser: Browser, bookmarks: Bookmarks, onLeft: Bool) {
        self.browser = browser
        self.bookmarks = bookmarks
        self.onLeft = onLeft
        _expanded = State(initialValue: BookmarksDropdown.opening(bookmarks.roots))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Bookmarks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Quick("Manage") { browser.bookmarking = true }
                Door(icon: "xmark", help: "Hide Bookmarks Sidebar") { browser.prefs.bookmarksSidebar = false }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            if bookmarks.isEmpty {
                Text("No bookmarks yet. Pocket this page with ⇧⌘B.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(12)
            } else {
                ScrollView {
                    BookmarkOutline(bookmarks: bookmarks, expanded: $expanded, open: { url in
                        browser.pickBookmark(url)
                    }, openInNewTab: { url in
                        browser.pickBookmark(url, inNewTab: true)
                    }, openAll: { browser.openBookmarks($0, inNewWindow: $1) })
                    .padding(6)
                }
            }
        }
        .frame(width: Metrics.side)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.ground)
        .overlay(alignment: onLeft ? .trailing : .leading) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
    }
}

/// The full list, for putting it in order, finding one, or bringing more in.
struct BookmarksPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks
    @ObservedObject var picks: BookmarkPicks

    @FocusState private var hunting: Bool
    /// The row just shown from a search, washed for a moment so the eye
    /// lands on it.
    @State private var shown: Bookmark.ID?

    var body: some View {
        Plate("Bookmarks", width: 600, close: { browser.bookmarking = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Hunt(text: $picks.query, prompt: "Search bookmarks", focus: $hunting)
                    .onSubmit(openFirst)

                if let organizing = picks.organizing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(organizing).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Spacer()
                        Quick("Stop") { picks.reset() }
                    }
                } else if picks.proposal == nil {
                    bar
                }

                if let proposal = picks.proposal {
                    BookmarkProposalView(proposal: proposal, apply: { browser.applyBookmarkProposal() }, discard: { picks.proposal = nil })
                } else if bookmarks.isEmpty {
                    Card { Nothing("Nothing pocketed yet. Add this page with ⇧⌘B, or bring yours in below.") }
                } else if !picks.query.isEmpty {
                    found
                } else {
                    ScrollViewReader { scroller in
                        ScrollView(showsIndicators: false) {
                            Card {
                                BookmarkOutline(bookmarks: bookmarks, expanded: $picks.expanded, shown: shown, open: { url in
                                    browser.pickBookmark(url)
                                }, openInNewTab: { url in
                                    browser.pickBookmark(url, inNewTab: true)
                                }, picks: picks, openAll: { browser.openBookmarks($0, inNewWindow: $1) })
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                            }
                            .padding(.bottom, 2)
                        }
                        .frame(maxHeight: 440)
                        // A bookmark found is shown where it lives, which
                        // may be below what shows. This list is only made
                        // as the search is cleared for it, with the row to
                        // show already set, so it is read as it appears too.
                        .onChange(of: shown, initial: true) { _, id in
                            guard let id else { return }
                            DispatchQueue.main.async {
                                withAnimation(Motion.settle) { scroller.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                }
            }
        } foot: {
            HStack(spacing: 8) {
                Text("Bring in from")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Pill("Bring in…") {
                    browser.bookmarking = false
                    browser.bringingIn = ""
                }
                Pill("File…") { browser.importFile() }
                Spacer()
                Pill("New Folder…") { bookmarks.askNewFolder(in: nil) }
                pillMenu("Organize") {
                    Button("Sort Top Level by Name") { bookmarks.sort(nil, by: .name) }
                    Button("Sort Top Level by Site") { bookmarks.sort(nil, by: .site) }
                    Divider()
                    Button("Remove Duplicates…") { removeDuplicates() }
                    Divider()
                    Button("Organize with AI…") { browser.organizeBookmarks() }
                        .disabled(picks.organizing != nil)
                }
                Text(bookmarks.count == 1 ? "1 bookmark" : "\(bookmarks.count) bookmarks")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .animation(Motion.settle, value: picks.query.isEmpty)
        .onAppear {
            bookmarks.undo = browser.window?.undoManager
            hunting = true
        }
        .onDisappear {
            // What was done here can't be undone from a page's text field.
            let manager = browser.window?.undoManager
            manager?.removeAllActions(withTarget: bookmarks)
            if bookmarks.undo === manager { bookmarks.undo = nil }
            picks.reset()
        }
        // A row taken away, by anything, is no longer picked.
        .onChange(of: bookmarks.roots) { _, roots in
            let here = Set(Bookmarks.ids(roots))
            if !picks.ids.isSubset(of: here) { picks.ids.formIntersection(here) }
        }
    }

    /// What is picked, and what can be done with all of it at once.
    @ViewBuilder
    private var bar: some View {
        if !picks.ids.isEmpty {
            let nodes = bookmarks.topmost(picks.ids).compactMap(bookmarks.bookmark)
            HStack(spacing: 8) {
                Text("\(picks.ids.count) selected")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Pill("Open in Tabs") { browser.openBookmarks(nodes, inNewWindow: false) }
                Pill("New Window") { browser.openBookmarks(nodes, inNewWindow: true) }
                pillMenu("Move to") { BookmarkOutline.moveItems(bookmarks, nodes) }
                Pill("Group…") {
                    bookmarks.askGroup(nodes) { made in
                        picks.expanded.formUnion((bookmarks.path(to: made) ?? []).map(\.id))
                        picks.expanded.insert(made)
                    }
                }
                Pill("Copy") { Bookmarks.copy(nodes) }
                Pill("Remove", tint: .red.opacity(0.75)) { bookmarks.askRemove(nodes) }
                Quick("Clear") { picks.ids = [] }
            }
        }
    }

    /// A key pressed while the manager is up and nothing is typed in its
    /// search: ⌘A picks every row shown, ⌘Z and ⇧⌘Z undo and redo, ⌫ removes
    /// what is picked and Return opens it. Whether the key was used.
    static func take(_ event: NSEvent, browser: Browser) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let picks = browser.bookmarkPicks
        let bookmarks = browser.bookmarks
        let nodes = bookmarks.topmost(picks.ids).compactMap(bookmarks.bookmark)
        if flags == .command, key == "a" {
            picks.ids = Set(BookmarkOutline.visible(bookmarks.roots, open: picks.expanded))
        } else if flags == .command, key == "z" {
            browser.window?.undoManager?.undo()
        } else if flags == [.command, .shift], key == "z" {
            browser.window?.undoManager?.redo()
        } else if event.keyCode == 51 || event.keyCode == 117, flags.isSubset(of: .command), !nodes.isEmpty {
            bookmarks.askRemove(nodes)
        } else if event.keyCode == 36, !nodes.isEmpty {
            if nodes.count == 1, let text = nodes[0].url, let url = URL(string: text) {
                browser.pickBookmark(url)
            } else {
                browser.openBookmarks(nodes, inNewWindow: false)
            }
        } else {
            return false
        }
        return true
    }

    /// A menu that looks like a Pill.
    private func pillMenu(_ title: String, @ViewBuilder _ items: () -> some View) -> some View {
        Menu {
            items()
        } label: {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func removeDuplicates() {
        let extra = bookmarks.duplicates()
        guard !extra.isEmpty else { return browser.announce("No duplicates") }
        Ask.sure("Remove \(extra.count) duplicate\(extra.count == 1 ? "" : "s")?",
                 detail: "The first of each address stays where it is.", confirm: "Remove") {
            bookmarks.remove(extra)
        }
    }

    /// What the search finds, flat, each with the folders it is in. Nothing
    /// here is dragged: it is put in order in the tree.
    @ViewBuilder
    private var found: some View {
        let hits = bookmarks.matches(picks.query)
        if hits.isEmpty {
            Card { Nothing("Nothing matches. The kea checked under every rock.") }
        } else {
            ScrollView(showsIndicators: false) {
                Card {
                    ForEach(Array(hits.enumerated()), id: \.element.node.id) { index, hit in
                        if index > 0 { Rule(inset: 40) }
                        Found(
                            node: hit.node,
                            path: hit.path,
                            selected: picks.ids.contains(hit.node.id),
                            open: hit.node.url.flatMap(URL.init(string:)).map { url in { browser.pickBookmark(url) } },
                            show: { show(hit.node) },
                            pick: { picks.click(hit.node.id, flags: NSApp.currentEvent?.modifierFlags ?? [], order: hits.map(\.node.id)) }
                        )
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 440)
        }
    }

    /// Return in the field: the first site found.
    private func openFirst() {
        guard let url = bookmarks.matches(picks.query).lazy.compactMap({ $0.node.url.flatMap(URL.init(string:)) }).first
        else { return }
        browser.pickBookmark(url)
    }

    /// Back to the tree, opened down to it, and it washed a moment. A
    /// folder is shown open.
    private func show(_ node: Bookmark) {
        picks.query = ""
        picks.expanded.formUnion((bookmarks.path(to: node.id) ?? []).map(\.id))
        if node.isFolder { picks.expanded.insert(node.id) }
        shown = node.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if shown == node.id { withAnimation(Motion.settle) { shown = nil } }
        }
    }

    /// One line of what was found: its title, then where it is.
    private struct Found: View {
        let node: Bookmark
        let path: [String]
        let selected: Bool
        /// Nil for a folder, which is shown in the tree instead.
        let open: (() -> Void)?
        let show: () -> Void
        let pick: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                if node.isFolder {
                    Mark(icon: nil, letter: "", size: 16)
                        .overlay(Image(systemName: "folder.fill").font(.system(size: 9.5)).foregroundStyle(Palette.muted))
                } else {
                    Mark(icon: Favicons.shared.cached(node.site ?? ""), letter: String((node.host ?? "•").prefix(1)).uppercased(), size: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.label)
                        .font(.system(size: 13))
                        .foregroundStyle(node.unnamed ? Palette.muted : Palette.ink)
                        .lineLimit(1)
                    Text(whereabouts)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Show in Folder", act: show)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering || selected ? Palette.hover : .clear)
            .contentShape(Rectangle())
            // A click picks; a double-click opens it, or shows a folder.
            .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { open?() ?? show() } else { pick() } }
            .onHover { hovering = $0 }
            .contextMenu {
                if let open { Button("Open", action: open) }
                Button("Show in Folder", action: show)
            }
            .animation(Motion.quick, value: hovering)
        }

        /// The folders it is in, then the site.
        private var whereabouts: String {
            let folders = path.isEmpty ? "Top level" : path.joined(separator: " \u{203A} ")
            guard let host = node.host else { return folders }
            return folders + "  \u{00B7}  " + host
        }
    }
}

/// The bookmarks in the menu bar's Bookmarks menu, made by AppKit rather
/// than SwiftUI. SwiftUI makes a menu bar's items all at once, folders
/// and all, before the app has finished launching: 1,500 bookmarks, as a
/// Chrome import brings, held the window back by 230 ms at every launch.
/// Here the top of the list is made as the menu opens, and a folder's
/// items as that folder opens.
///
/// SwiftUI keeps its own two items, and its own delegate, which lays the
/// menu out afresh each time it opens — anything added beside them was
/// gone by then. So its delegate is wrapped: SwiftUI does its update,
/// then the bookmarks go in after it. SwiftUI puts its delegate back on
/// every update, so the wrapping is put back too (see `start`).
@MainActor
final class BookmarkMenu: NSObject, NSMenuDelegate {
    static let shared = BookmarkMenu()

    private weak var browser: Browser?
    private var watch: [Any] = []
    private let relay = Relay()
    /// What each folder's submenu holds, until it opens.
    private var folders: [ObjectIdentifier: [Bookmark]] = [:]
    /// The items put in here, among SwiftUI's own.
    fileprivate static let mark = 0x5EAC

    func start(for browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        relay.after = { [weak self] menu in self?.fill(menu) }
        // SwiftUI puts its own delegate back whenever it updates the menu
        // bar, which is whenever anything in the window changes. So: after
        // each event, and as the menu bar starts to be used, before any of
        // its menus opens.
        let centre = NotificationCenter.default
        watch = [
            centre.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrap() }
            },
            centre.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                    self?.wrap()
                }
            },
            // However the menu bar is let go of, even if SwiftUI's delegate
            // got the menu's own close instead.
            centre.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                    self?.closed()
                }
            },
        ]
        wrap()
    }

    private var menu: NSMenu? { NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu }

    /// Looks, while the menu is open, after each turn of the run loop.
    private var looking: CFRunLoopObserver?

    /// An open menu is updated by SwiftUI itself, straight through its own
    /// delegate, whenever anything it shows could have changed — a tab's
    /// title, every second on a download page — and that took the bookmarks
    /// out from under the pointer. While it is open, they go back in as soon
    /// as a turn of the run loop finds them gone.
    fileprivate func opened(_ menu: NSMenu) {
        guard looking == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self, weak menu] _, _ in
            MainActor.assumeIsolated {
                guard let self, let menu, !menu.items.contains(where: { $0.tag == Self.mark }) else { return }
                self.fill(menu)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        looking = observer
    }

    fileprivate func closed() {
        guard let looking else { return }
        CFRunLoopObserverInvalidate(looking)
        self.looking = nil
    }

    private func wrap() {
        guard let menu, menu.delegate !== relay
        else { return }
        relay.inner = menu.delegate
        menu.delegate = relay
    }

    /// SwiftUI's own update of the menu, without ours after it: what it
    /// does by itself to a menu that is open. For the bench.
    func swiftUIUpdate() {
        guard let menu else { return }
        relay.inner?.menuNeedsUpdate?(menu)
    }

    /// How many items this has put in the menu, for the bench.
    var count: Int {
        menu?.items.filter { $0.tag == Self.mark }.count ?? 0
    }

    /// The top of the list, after SwiftUI's items, in place of any left
    /// from the last time.
    private func fill(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.mark { menu.removeItem(item) }
        folders = [:]
        guard let roots = browser?.bookmarks.roots, !roots.isEmpty else { return }
        let line = NSMenuItem.separator()
        line.tag = Self.mark
        menu.addItem(line)
        for item in items(for: roots) { menu.addItem(item) }
    }

    /// A folder of the bookmarks bar, opened as a menu at the pointer: the
    /// same items as the menu bar's, folders opening as they are reached.
    func popUp(_ folder: Bookmark) {
        let menu = NSMenu(title: folder.title)
        let made = items(for: folder.children ?? [])
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func items(for nodes: [Bookmark]) -> [NSMenuItem] {
        nodes.compactMap { node in
            let item: NSMenuItem
            if node.isFolder {
                item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let sub = NSMenu(title: node.title)
                sub.delegate = self
                folders[ObjectIdentifier(sub)] = node.children ?? []
                item.submenu = sub
            } else if let text = node.url, let url = URL(string: text) {
                // One without a name reads as its address here.
                item = NSMenuItem(title: node.label, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                // The site's icon, as the bar wears it: a folder opened from
                // the bar, or the Bookmarks menu, had none (idea 183). A site
                // whose icon isn't kept yet (brought in, never visited) wears
                // the bar's letter in its place, rather than nothing and its
                // title out of line with the others'.
                if let icon = Favicons.shared.cached(node.site ?? "") {
                    let small = icon.copy() as? NSImage ?? icon
                    small.size = NSSize(width: 16, height: 16)
                    item.image = small
                } else {
                    item.image = BookmarkMenu.letter(String((node.host ?? "•").prefix(1)).uppercased())
                }
            } else {
                return nil
            }
            item.tag = Self.mark
            return item
        }
    }

    /// The bar's Mark with no icon, for a menu: the letter, muted, on a
    /// faint square, drawn as the menu draws so it follows light and dark.
    private static func letter(_ letter: String) -> NSImage {
        let size: CGFloat = 16
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            Palette.NS.ink.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.56, weight: .medium),
                .foregroundColor: Palette.NS.muted,
            ])
            let drawn = text.size()
            text.draw(at: NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2))
            return true
        }
    }

    /// What a folder of the bar holds as its menu: every item, its folders
    /// opened as a click would, deepest last. For the bench.
    func walk(_ folder: Bookmark) -> [(depth: Int, item: NSMenuItem)] {
        func down(_ items: [NSMenuItem], _ depth: Int) -> [(depth: Int, item: NSMenuItem)] {
            items.flatMap { item -> [(depth: Int, item: NSMenuItem)] in
                guard let sub = item.submenu else { return [(depth, item)] }
                menuNeedsUpdate(sub)
                return [(depth, item)] + down(sub.items, depth + 1)
            }
        }
        return down(items(for: folder.children ?? []), 0)
    }

    /// A folder, opening.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kids = folders[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        let made = items(for: kids)
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
    }

    @objc private func open(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        browser?.visit(url)
    }

    /// SwiftUI's delegate, with the bookmarks put in after its update.
    /// Everything else it answers goes straight to it.
    private final class Relay: NSObject, NSMenuDelegate {
        weak var inner: NSMenuDelegate?
        var after: ((NSMenu) -> Void)?

        func menuNeedsUpdate(_ menu: NSMenu) {
            inner?.menuNeedsUpdate?(menu)
            MainActor.assumeIsolated { after?(menu) }
        }

        func menuWillOpen(_ menu: NSMenu) {
            inner?.menuWillOpen?(menu)
            MainActor.assumeIsolated { BookmarkMenu.shared.opened(menu) }
        }

        func menuDidClose(_ menu: NSMenu) {
            inner?.menuDidClose?(menu)
            MainActor.assumeIsolated { BookmarkMenu.shared.closed() }
        }

        /// Only for its own items: the bookmarks aren't SwiftUI's to know.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard item?.tag != BookmarkMenu.mark else { return }
            inner?.menu?(menu, willHighlight: item)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { inner }
    }
}
