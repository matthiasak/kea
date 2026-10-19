import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI
import SystemConfiguration

// Your Macs in step: each writes its own sealed files to one store, a synced folder or a bucket, and reads the others'. No server of Kea's, and nothing the store can read.

struct SyncTab: Codable, Hashable {
 var url: String
 var title: String
}

struct TabsDoc: Codable {
 var name: String
 var at: Date
 var windows: [[SyncTab]]
}

struct HistoryDoc: Codable {
 var visits: [Visit]
 var cleared: Date?
 var forgot: [String: Date]
}

struct SentTab: Codable {
 var url: String
 var title: String
 var from: String
 var at: Date
}

@MainActor
final class Sync: ObservableObject {
 static let shared = Sync()

 enum Place: String, CaseIterable {
  case off, folder, bucket
 }

 enum Kind: String, CaseIterable, Identifiable {
  case bookmarks, places, settings, chats, history, tabs
  var id: String { rawValue }
  var title: String {
   switch self {
   case .bookmarks: return "Bookmarks"
   case .places: return "Pins and spaces"
   case .settings: return "Settings"
   case .chats: return "Ubi Chat chats"
   case .history: return "History"
   case .tabs: return "Open tabs"
   }
  }
 }

 struct Device: Identifiable, Equatable {
  struct Page: Hashable {
   let title: String
   let url: URL
  }
  let id: UUID
  let name: String
  let seen: Date
  let pages: [Page]
 }

 struct State: Codable {
  var store = ""
  var joined = false
  var ledgers: [String: SyncLedger] = [:]
  var cleared: Date?
  var forgot: [String: Date] = [:]
 }

 @Published var place: Place {
  didSet {
   Store.settings.set(place.rawValue, forKey: "sync.place")
   if place == .off {
    status = "Off"
    ready = false
   } else if key == nil {
    status = "Type the passphrase"
   }
  }
 }
 @Published var folder: String {
  didSet { Store.settings.set(folder, forKey: "sync.folder") }
 }
 @Published var endpoint: String {
  didSet { Store.settings.set(endpoint, forKey: "sync.endpoint") }
 }
 @Published var bucket: String {
  didSet { Store.settings.set(bucket, forKey: "sync.bucket") }
 }
 @Published var access: String {
  didSet { Store.settings.set(access, forKey: "sync.access") }
 }
 @Published var kinds: Set<Kind> {
  didSet { Store.settings.set(kinds.map(\.rawValue).sorted(), forKey: "sync.kinds") }
 }
 let device: UUID
 var name: String

 @Published private(set) var status = "Off"
 @Published private(set) var devices: [Device] = []
 @Published private(set) var ready = false

 /// While another Mac's change is put in place: what it changes is not this Mac's news.
 private(set) static var applying = false

 private var key: SymmetricKey?
 private var secret: String?
 private var running: Task<Void, Never>?
 private var timer: Timer?
 private var started = false
 private var seen: [String: Date] = [:]
 private var wrote: [String: String] = [:]
 private var lastTabsWrite: Date = .distantPast
 private var others: [UUID: TabsDoc] = [:]
 private var state: State

 private static var stateFile: URL { Store.file("sync.json") }
 private static let service = "app.kea.browser.sync"

 static let bools: [String: ReferenceWritableKeyPath<Preferences, Bool>] = [
  "toolbar.left": \.navigationLeft,
  "bookmarks.bar": \.bookmarksBar,
  "sidebar": \.sidebar,
  "bookmarks.sidebar": \.bookmarksSidebar,
  "sidebar.hides": \.sideHides,
  "links.show": \.showsLinks,
  "tabs.sleep": \.sleepsTabs,
  "swipe.history": \.holdsHistory,
  "tabs.lazy": \.lazyTabs,
  "float.flicks": \.floatFlicks,
  "search.sites": \.searchesSites,
  "kea.facts": \.keaFacts,
  "tabs.reading": \.showsReading,
  "float.away": \.floatsAway,
  "shield": \.shielded,
  "media.click": \.waitsForPlay,
  "downloads.ask": \.asksWhereToSave,
  "float.leave": \.floatsOnLeave,
  "passwords.save": \.savesPasswords,
  "spaces": \.usesSpaces,
  "passwords.fill": \.fillsPasswords,
  "tabs.groups": \.usesTabGroups,
  "links.peek": \.peeksLinks,
  "pins.list": \.listsPins,
  "links.little": \.littleLinks,
  "splitView": \.splitView,
  "downloads.button": \.alwaysShowsDownloads,
  "ai": \.ai,
  "autoscroll": \.autoScroll,
  "commandbar": \.commandBar,
  "handoff": \.handoff,
 ]

 static let portable: [String] =
  Array(bools.keys).sorted() + [
   "look", "sidebar.position", "glyph", "search.engine", "search.custom",
   "search.keywords", "pageZoom", "ai.provider", "ai.models", "shortcuts",
  ]

 private init() {
  let store = Store.settings
  place = store.string(forKey: "sync.place").flatMap(Place.init) ?? .off
  folder = store.string(forKey: "sync.folder") ?? ""
  endpoint = store.string(forKey: "sync.endpoint") ?? "https://storage.googleapis.com"
  bucket = store.string(forKey: "sync.bucket") ?? ""
  access = store.string(forKey: "sync.access") ?? ""
  if let saved = store.stringArray(forKey: "sync.kinds") {
   kinds = Set(saved.compactMap(Kind.init))
  } else {
   kinds = Set(Kind.allCases)
  }
  if let existing = store.string(forKey: "sync.device").flatMap(UUID.init) {
   device = existing
  } else {
   let made = UUID()
   store.set(made.uuidString, forKey: "sync.device")
   device = made
  }
  name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
  if let data = try? Data(contentsOf: Self.stateFile),
   let decoded = try? JSONDecoder().decode(State.self, from: data)
  {
   state = decoded
  } else {
   state = State()
  }
 }

 func start() {
  guard !started else { return }
  started = true
  if place != .off {
   if !Store.testing {
    if let secData = Self.loadKeychain(account: "secret"),
     let sec = String(data: secData, encoding: .utf8)
    {
     secret = sec
    }
    if let keyData = Self.loadKeychain(account: "key"), keyData.count == 32 {
     key = SymmetricKey(data: keyData)
     ready = true
    }
   }
   if key == nil {
    status = "Type the passphrase"
   }
  }
  guard !Store.testing else { return }
  timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
   Task { @MainActor in await self?.now() }
  }
  NotificationCenter.default.addObserver(
   forName: NSApplication.didBecomeActiveNotification,
   object: nil,
   queue: .main
  ) { [weak self] _ in
   Task { @MainActor in await self?.now() }
  }
  Task { @MainActor [weak self] in
   try? await Task.sleep(for: .seconds(3))
   await self?.now()
  }
 }

 private var storeIdentity: String {
  switch place {
  case .off: return ""
  case .folder: return "folder:\(folder)"
  case .bucket: return "bucket:\(endpoint)/\(bucket)"
  }
 }

 private func drop() -> (any SyncDrop)? {
  switch place {
  case .off:
   return nil
  case .folder:
   guard !folder.isEmpty else { return nil }
   return FolderDrop(root: URL(fileURLWithPath: folder))
  case .bucket:
   guard !endpoint.isEmpty, !bucket.isEmpty, !access.isEmpty,
    let secret, !secret.isEmpty,
    let url = URL(string: endpoint), BucketDrop.allowed(url)
   else { return nil }
   return BucketDrop(endpoint: url, bucket: bucket, access: access, secret: secret)
  }
 }

 private func forgetKey() {
  key = nil
  ready = false
  seen = [:]
  wrote = [:]
  others = [:]
  devices = []
  lastTabsWrite = .distantPast
  if !Store.testing { Self.deleteKeychain(account: "key") }
 }

 func chooseFolder(_ url: URL) {
  folder = url.path
  place = .folder
  forgetKey()
  status = "Type the passphrase"
 }

 func useBucket(endpoint: String, bucket: String, access: String, secret: String) -> String? {
  let ep = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
  let bk = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
  let ac = access.trimmingCharacters(in: .whitespacesAndNewlines)
  let sc = secret.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let url = URL(string: ep), BucketDrop.allowed(url) else {
   return "Use an https address (http only on this Mac)"
  }
  guard !bk.isEmpty, !ac.isEmpty, !sc.isEmpty else {
   return "Fill in the bucket, access key and secret"
  }
  self.endpoint = ep
  self.bucket = bk
  self.access = ac
  self.secret = sc
  if !Store.testing {
   Self.saveKeychain(account: "secret", data: Data(sc.utf8))
  }
  place = .bucket
  forgetKey()
  status = "Type the passphrase"
  return nil
 }

 func use(passphrase: String) async -> String? {
  guard !passphrase.isEmpty else { return "Type a passphrase" }
  guard let drop = drop() else {
   return place == .folder ? "Choose a folder first" : "Fill in the bucket details first"
  }
  do {
   let derived: SymmetricKey
   if let salt = try await drop.get("kea/v1/salt") {
    derived = await Task.detached { SyncSeal.key(passphrase: passphrase, salt: salt) }.value
    guard let checkSealed = try await drop.get("kea/v1/check"),
     let checkPlain = try? SyncSeal.open(checkSealed, with: derived),
     String(data: checkPlain, encoding: .utf8) == "kea"
    else {
     let msg = SyncError.wrongPassphrase.localizedDescription
     status = msg
     return msg
    }
   } else {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let salt = Data(bytes)
    try await drop.put("kea/v1/salt", salt)
    derived = await Task.detached { SyncSeal.key(passphrase: passphrase, salt: salt) }.value
    let check = try SyncSeal.seal(Data("kea".utf8), with: derived)
    try await drop.put("kea/v1/check", check)
   }
   key = derived
   if !Store.testing {
    derived.withUnsafeBytes { Self.saveKeychain(account: "key", data: Data($0)) }
   }
   ready = true
   let id = storeIdentity
   if state.store != id {
    state = State(store: id)
    seen = [:]
    wrote = [:]
    others = [:]
    lastTabsWrite = .distantPast
   }
   await now()
   return nil
  } catch {
   status = error.localizedDescription
   return error.localizedDescription
  }
 }

 func now() async {
  while let running { await running.value }
  let task = Task { @MainActor in await tick() }
  running = task
  await task.value
  if running == task { running = nil }
 }

 func send(_ tab: Tab, to device: Device, from browser: Browser) {
  guard ready, let key, let drop = drop(),
   let url = tab.address, ["http", "https"].contains(url.scheme?.lowercased() ?? "")
  else {
   browser.announce("Set up Sync in Settings first")
   return
  }
  let sent = SentTab(url: url.absoluteString, title: tab.title, from: name, at: Date())
  let itemName = "kea/v1/inbox/\(device.id.uuidString)/\(UUID().uuidString).kea"
  Task { @MainActor in
   do {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let plain = try enc.encode(sent)
    let sealed = try SyncSeal.seal(plain, with: key)
    try await drop.put(itemName, sealed)
    browser.announce("Sent to \(device.name)")
   } catch {
    browser.announce(error.localizedDescription)
   }
  }
 }

 func historyCleared() {
  guard !Sync.applying, place != .off else { return }
  state.cleared = Date()
  saveState()
 }

 func historyForgot(_ key: String) {
  guard !Sync.applying, place != .off else { return }
  state.forgot[key] = Date()
  saveState()
 }

 private func saveState() {
  let snapshot = state
  Disk.write(Self.stateFile, now: Store.testing) {
   let enc = JSONEncoder()
   enc.outputFormatting = [.sortedKeys]
   return try? enc.encode(snapshot)
  }
 }

 private static let recordKinds: [Kind] = [.bookmarks, .places, .settings, .chats]

 /// Said only when it changes: whatever shows the status (the History menu's
 /// Other Macs) is drawn again on every set, the same words or not.
 private func say(_ text: String) { if status != text { status = text } }

 private func tick() async {
  guard place != .off else {
   say("Off")
   return
  }
  guard let key else {
   say("Type the passphrase")
   return
  }
  guard let drop = drop() else {
   say(place == .folder ? "Choose a folder" : "Set up the bucket")
   return
  }
  do {
   let now = Date()
   if state.joined {
    for kind in Self.recordKinds where kinds.contains(kind) {
     SyncMerge.stamp(
      records(kind),
      into: &state.ledgers[kind.rawValue, default: SyncLedger()],
      now: now
     )
    }
   }

   let names = try await drop.list("kea/v1/devices/")
   for name in names.keys.sorted() {
    guard let modDate = names[name], seen[name] != modDate else { continue }
    guard name.hasPrefix("kea/v1/devices/") else { continue }
    let rest = name.dropFirst("kea/v1/devices/".count)
    let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2,
     let otherID = UUID(uuidString: String(parts[0])),
     otherID != device,
     parts[1].hasSuffix(".kea"),
     let kind = Kind(rawValue: String(parts[1].dropLast(4)))
    else { continue }

    if kind != .tabs && !kinds.contains(kind) { continue }
    guard let sealed = try await drop.get(name) else { continue }
    let plain = try SyncSeal.open(sealed, with: key)

    switch kind {
    case .bookmarks, .places, .settings, .chats:
     let doc = try JSONDecoder().decode(SyncDoc.self, from: plain)
     var ledger = state.ledgers[kind.rawValue, default: SyncLedger()]
     let (put, remove) = SyncMerge.take(doc, against: ledger)
     Sync.applying = true
     for (k, rec) in put.sorted(by: { $0.key < $1.key }) {
      apply(kind, key: k, data: rec.data, joining: !state.joined)
     }
     for (k, at) in remove.sorted(by: { $0.key < $1.key }) {
      removeRecord(kind, key: k)
      SyncMerge.removed(k, at: at, in: &ledger)
     }
     Sync.applying = false
     let after = records(kind)
     for (k, rec) in put {
      SyncMerge.settle(k, local: after[k], remote: rec, in: &ledger, now: now)
     }
     state.ledgers[kind.rawValue] = ledger

    case .history:
     let doc = try JSONDecoder().decode(HistoryDoc.self, from: plain)
     applyHistory(doc)

    case .tabs:
     let doc = try JSONDecoder().decode(TabsDoc.self, from: plain)
     others[otherID] = doc
    }
    seen[name] = modDate
   }

   if !state.joined {
    for kind in Self.recordKinds where kinds.contains(kind) {
     SyncMerge.stamp(
      records(kind),
      into: &state.ledgers[kind.rawValue, default: SyncLedger()],
      now: now
     )
    }
    state.joined = true
   }

   let enc = JSONEncoder()
   enc.outputFormatting = [.sortedKeys]

   for kind in Self.recordKinds where kinds.contains(kind) {
    let current = records(kind)
    let ledger = state.ledgers[kind.rawValue, default: SyncLedger()]
    let plain = try enc.encode(SyncMerge.doc(current, ledger: ledger, now: now))
    let objName = "kea/v1/devices/\(device.uuidString)/\(kind.rawValue).kea"
    let h = SyncMerge.hash(plain)
    if h != wrote[objName] {
     try await drop.put(objName, try SyncSeal.seal(plain, with: key))
     wrote[objName] = h
    }
   }

   if kinds.contains(.history) {
    let cutoff = now.addingTimeInterval(-SyncMerge.keepGone)
    state.forgot = state.forgot.filter { $0.value >= cutoff }
    let hDoc = HistoryDoc(
     visits: Shared.history.exported(), cleared: state.cleared, forgot: state.forgot)
    let plain = try enc.encode(hDoc)
    let objName = "kea/v1/devices/\(device.uuidString)/history.kea"
    let h = SyncMerge.hash(plain)
    if h != wrote[objName] {
     try await drop.put(objName, try SyncSeal.seal(plain, with: key))
     wrote[objName] = h
    }
   }

   let windows: [[SyncTab]]
   if kinds.contains(.tabs) {
    windows = Browsers.all.compactMap { b -> [SyncTab]? in
     let list = b.tabs.compactMap { tab -> SyncTab? in
      guard !tab.shy, !tab.bench, !tab.isBlank,
       let url = tab.address,
       ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      else { return nil }
      return SyncTab(url: url.absoluteString, title: tab.title)
     }
     return list.isEmpty ? nil : list
    }
   } else {
    windows = []
   }
   var tabsCheck = (try? enc.encode(windows)) ?? Data()
   tabsCheck.append(Data(name.utf8))
   let tabsHash = SyncMerge.hash(tabsCheck)
   let tabsName = "kea/v1/devices/\(device.uuidString)/tabs.kea"
   if tabsHash != wrote[tabsName] || now.timeIntervalSince(lastTabsWrite) >= 600 {
    let plain = try enc.encode(TabsDoc(name: name, at: now, windows: windows))
    try await drop.put(tabsName, try SyncSeal.seal(plain, with: key))
    wrote[tabsName] = tabsHash
    lastTabsWrite = now
   }

   let inboxPrefix = "kea/v1/inbox/\(device.uuidString)/"
   let inbox = try await drop.list(inboxPrefix)
   for itemName in inbox.keys.sorted() {
    if let sealed = try await drop.get(itemName),
     let plain = try? SyncSeal.open(sealed, with: key),
     let sent = try? JSONDecoder().decode(SentTab.self, from: plain),
     let url = URL(string: sent.url),
     ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    {
     let browser = Browsers.ensureWindow()
     browser.open(url, foreground: false, atEnd: true)
     let label = sent.title.isEmpty ? (url.host() ?? sent.url) : sent.title
     browser.announce("From \(sent.from): \(label)")
    }
    try? await drop.delete(itemName)
   }

   let recentCutoff = now.addingTimeInterval(-30 * 86_400)
   devices = others.compactMap { id, doc -> Device? in
    guard doc.at >= recentCutoff else { return nil }
    let pages = doc.windows.flatMap { $0 }.compactMap { t -> Device.Page? in
     guard let url = URL(string: t.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
     else { return nil }
     return Device.Page(title: t.title, url: url)
    }
    return Device(id: id, name: doc.name, seen: doc.at, pages: pages)
   }.sorted { $0.seen > $1.seen }

   let rel = RelativeDateTimeFormatter().localizedString(for: now, relativeTo: Date())
   say("Synced \(rel)")
   saveState()
   if Store.testing { Disk.drain() }
  } catch {
   say(error.localizedDescription)
  }
 }

 private func records(_ kind: Kind) -> [String: Data] {
  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys]
  switch kind {
  case .bookmarks:
   // ponytail: the bookmark tree is one record; per-node merge if edits on two Macs within 30 s get lost
   guard let data = try? enc.encode(Shared.bookmarks.roots) else { return [:] }
   return ["tree": data]

  case .places:
   var out: [String: Data] = [:]
   let spaces = Spaces.read().map { s -> Space in
    var copy = s
    copy.downloads = nil
    return copy
   }
   if let data = try? enc.encode(spaces) { out["spaces"] = data }
   let pins = Dictionary(uniqueKeysWithValues: Pins.all.map { ($0.key.uuidString, $0.value) })
   if let data = try? enc.encode(pins) { out["pins"] = data }
   return out

  case .settings:
   var out: [String: Data] = [:]
   let zoomKeys = Store.settings.dictionaryRepresentation().keys.filter { $0.hasPrefix("zoom.") }
    .sorted()
   for key in Self.portable + zoomKeys {
    guard let val = Store.settings.object(forKey: key),
     let data = try? PropertyListSerialization.data(
      fromPropertyList: ["v": val], format: .binary, options: 0)
    else { continue }
    out[key] = data
   }
   return out

  case .chats:
   return Shared.chats.records()

  case .history, .tabs:
   return [:]
  }
 }

 private func apply(_ kind: Kind, key: String, data: Data, joining: Bool) {
  switch kind {
  case .bookmarks:
   guard key == "tree", let remote = try? JSONDecoder().decode([Bookmark].self, from: data) else {
    return
   }
   if joining {
    Shared.bookmarks.replace(Bookmarks.union(remote, Shared.bookmarks.roots), action: "Sync")
   } else {
    Shared.bookmarks.replace(remote, action: "Sync")
   }

  case .places:
   if key == "spaces" {
    guard var list = try? JSONDecoder().decode([Space].self, from: data) else { return }
    let local = Spaces.read()
    if joining {
     let remoteIDs = Set(list.map(\.id))
     list += local.filter { !remoteIDs.contains($0.id) }
    }
    let localDownloads = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0.downloads) })
    for i in list.indices {
     list[i].downloads = localDownloads[list[i].id] ?? nil
    }
    Spaces.write(list)
   } else if key == "pins" {
    guard let raw = try? JSONDecoder().decode([String: [PinDef]].self, from: data) else { return }
    var map: [UUID: [PinDef]] = [:]
    for (k, defs) in raw {
     if let id = UUID(uuidString: k) { map[id] = defs }
    }
    if joining {
     for (space, localDefs) in Pins.all {
      var combined = map[space] ?? []
      let homes = Set(combined.map(\.home))
      combined += localDefs.filter { !homes.contains($0.home) }
      if !combined.isEmpty { map[space] = combined }
     }
    }
    Pins.replaceAll(map)
   }

  case .settings:
   guard
    let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
     as? [String: Any],
    let v = dict["v"]
   else { return }
   let prefs = Shared.prefs
   if let kp = Self.bools[key] {
    if let b = v as? Bool { prefs[keyPath: kp] = b }
    return
   }
   switch key {
   case "look":
    if let s = v as? String, let l = Look(rawValue: s) { prefs.look = l }
   case "sidebar.position":
    if let s = v as? String, let p = SidebarPosition(rawValue: s) { prefs.sidePosition = p }
   case "glyph":
    if let s = v as? String, let g = Glyph(rawValue: s) { prefs.glyph = g }
   case "search.engine":
    if let s = v as? String, let e = Engine(rawValue: s) { prefs.engine = e }
   case "search.custom":
    if let s = v as? String { prefs.customEngine = s }
   case "search.keywords":
    if let d = v as? Data, let kw = try? JSONDecoder().decode([Keyword].self, from: d) {
     prefs.keywords = kw
    }
   case "pageZoom":
    if let d = (v as? NSNumber)?.doubleValue { prefs.pageZoom = d }
   case "ai.provider":
    if let s = v as? String, let p = AIProvider.named(s) { prefs.aiProvider = p }
   case "ai.models":
    if let m = v as? [String: String] {
     for (id, model) in m {
      if let p = AIProvider.named(id) { prefs.setAIModel(model, for: p) }
     }
    }
   case "shortcuts":
    if let d = v as? Data {
     Store.settings.set(d, forKey: "shortcuts")
     ShortcutStore.shared.reload()
    }
   default:
    if key.hasPrefix("zoom.") {
     Store.settings.set(v, forKey: key)
    }
   }

  case .chats:
   guard let chat = try? JSONDecoder().decode(Chat.self, from: data) else { return }
   Shared.chats.put(chat)

  case .history, .tabs:
   break
  }
 }

 private func removeRecord(_ kind: Kind, key: String) {
  switch kind {
  case .settings:
   if key.hasPrefix("zoom.") {
    Store.settings.removeObject(forKey: key)
   }
  case .chats:
   if let id = UUID(uuidString: key) {
    Shared.chats.remove(id)
   }
  case .bookmarks, .places, .history, .tabs:
   break
  }
 }

 private func applyHistory(_ doc: HistoryDoc) {
  Sync.applying = true
  defer { Sync.applying = false }
  if let c = doc.cleared, c > (state.cleared ?? .distantPast) {
   Shared.history.forget(before: c)
   state.cleared = c
  }
  for (k, at) in doc.forgot where at > (state.forgot[k] ?? .distantPast) {
   Shared.history.forget(k, before: at)
   state.forgot[k] = at
  }
  let clearedCutoff = state.cleared ?? .distantPast
  let allowed = doc.visits.filter { v in
   v.last > clearedCutoff && v.last > (state.forgot[v.key] ?? .distantPast)
  }
  Shared.history.absorb(allowed)
 }

 private static func saveKeychain(account: String, data: Data) {
  deleteKeychain(account: account)
  let query: [String: Any] = [
   kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: service,
   kSecAttrAccount as String: account,
   kSecValueData as String: data,
  ]
  SecItemAdd(query as CFDictionary, nil)
 }

 private static func loadKeychain(account: String) -> Data? {
  let query: [String: Any] = [
   kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: service,
   kSecAttrAccount as String: account,
   kSecReturnData as String: true,
   kSecMatchLimit as String: kSecMatchLimitOne,
  ]
  var item: CFTypeRef?
  guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
  return item as? Data
 }

 private static func deleteKeychain(account: String) {
  let query: [String: Any] = [
   kSecClass as String: kSecClassGenericPassword,
   kSecAttrService as String: service,
   kSecAttrAccount as String: account,
  ]
  SecItemDelete(query as CFDictionary)
 }
}

struct SyncSettings: View {
 @ObservedObject var browser: Browser
 @ObservedObject var prefs: Preferences
 @ObservedObject var sync: Sync

 @State private var endpointField = ""
 @State private var bucketField = ""
 @State private var accessField = ""
 @State private var secretField = ""
 @State private var passphraseField = ""

 var body: some View {
  VStack(alignment: .leading, spacing: 18) {
   Card {
    Line(
     "Sync through",
     "A folder iCloud Drive, Google Drive or Dropbox keeps in step, or a cloud bucket"
    ) {
     Segmented(
      options: [(.off, "Off"), (.folder, "Folder"), (.bucket, "Bucket")], selection: $sync.place)
    }
    if sync.place == .folder {
     Rule()
     Line(
      "Folder",
      sync.folder.isEmpty
       ? "None chosen" : sync.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
     ) {
      Pill("Choose…") { choose() }
     }
    } else if sync.place == .bucket {
     Rule()
     Line("Endpoint", "Google Cloud Storage: https://storage.googleapis.com, with an HMAC key") {
      textField("https://storage.googleapis.com", $endpointField, width: 210)
     }
     Rule()
     Line("Bucket") {
      textField("Bucket", $bucketField, width: 160)
     }
     Rule()
     Line("Access key") {
      textField("Access key", $accessField, width: 160)
     }
     Rule()
     Line("Secret") {
      HStack(spacing: 6) {
       secureField("Secret", $secretField, width: 130) { keepBucket() }
       Pill("Keep") { keepBucket() }
      }
     }
    }
    if sync.place != .off {
     Rule()
     Line("Passphrase", "The same on each of your Macs. Kea can't recover it.") {
      HStack(spacing: 6) {
       secureField("Passphrase", $passphraseField, width: 140) { applyPassphrase() }
       Pill("Use") { applyPassphrase() }
      }
     }
    }
    Rule()
    Line("Status", sync.status) {
     Pill("Sync Now") {
      Task { await sync.now() }
     }
    }
   }

   Card {
    ForEach(Array(Sync.Kind.allCases.enumerated()), id: \.element.id) { index, kind in
     if index > 0 { Rule() }
     Line(kind.title) {
      Switch(
       on: Binding(
        get: { sync.kinds.contains(kind) },
        set: { on in
         if on { sync.kinds.insert(kind) } else { sync.kinds.remove(kind) }
        }
       ))
     }
    }
   }

   Card {
    Line("This Mac", sync.name) {}
    Rule()
    Line("Your other Macs", otherMacsLine) {}
    Rule()
    Line("Handoff", "The page in front shows up on your iPhone, iPad and other Macs") {
     Switch(
      on: Binding(
       get: { prefs.handoff },
       set: { on in
        prefs.handoff = on
        Browsers.all.forEach { $0.handOff() }
       }
      ))
    }
   }
  }
  .onAppear {
   endpointField = sync.endpoint
   bucketField = sync.bucket
   accessField = sync.access
  }
 }

 private var otherMacsLine: String {
  guard !sync.devices.isEmpty else { return "None yet" }
  let formatter = RelativeDateTimeFormatter()
  let now = Date()
  return sync.devices.map { d in
   "\(d.name) · \(formatter.localizedString(for: d.seen, relativeTo: now))"
  }.joined(separator: ", ")
 }

 private func textField(_ prompt: String, _ text: Binding<String>, width: CGFloat) -> some View {
  TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.faint))
   .textFieldStyle(.plain)
   .font(.system(size: 12))
   .frame(width: width)
   .padding(.horizontal, 8)
   .padding(.vertical, 5)
   .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
 }

 private func secureField(
  _ prompt: String, _ text: Binding<String>, width: CGFloat, submit: @escaping () -> Void
 ) -> some View {
  SecureField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.faint))
   .textFieldStyle(.plain)
   .font(.system(size: 12))
   .frame(width: width)
   .padding(.horizontal, 8)
   .padding(.vertical, 5)
   .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
   .onSubmit(submit)
 }

 private func choose() {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.canCreateDirectories = true
  let icloud = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
   "Library/Mobile Documents/com~apple~CloudDocs")
  var isDir: ObjCBool = false
  if FileManager.default.fileExists(atPath: icloud.path, isDirectory: &isDir), isDir.boolValue {
   panel.directoryURL = icloud
  } else {
   panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
  }
  panel.prompt = "Sync here"
  guard panel.runModal() == .OK, let url = panel.url else { return }
  sync.chooseFolder(url)
 }

 private func keepBucket() {
  if let err = sync.useBucket(
   endpoint: endpointField, bucket: bucketField, access: accessField, secret: secretField)
  {
   browser.announce(err)
  } else {
   secretField = ""
  }
 }

 private func applyPassphrase() {
  let pass = passphraseField
  passphraseField = ""
  Task { @MainActor in
   if let error = await sync.use(passphrase: pass) {
    browser.announce(error)
   }
  }
 }
}
