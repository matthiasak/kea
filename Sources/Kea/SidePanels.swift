import AppKit
import Combine
import SwiftUI

enum SidePanel: String {
 case chat, bookmarks

 var range: ClosedRange<CGFloat> {
  self == .chat ? Metrics.chatMin...Metrics.chatMax : Metrics.sideMin...Metrics.sideMax
 }
 var standard: CGFloat {
  self == .chat ? Metrics.chat : Metrics.side
 }
}

/// The column's edge: pull it to make the column wider or narrower,
/// double-click it to put it back. The hairline darkens under the pointer
/// so the edge says it can be taken before it is.
struct EdgeHandle: View {
 @Binding var width: CGFloat
 let range: ClosedRange<CGFloat>
 let standard: CGFloat
 /// The column's inner edge is on its right: pulling right widens it.
 let growsRight: Bool

 /// The width the column had when the edge was picked up.
 @State private var grabbed: CGFloat?
 @State private var onEdge = false

 var body: some View {
  Rectangle()
   .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
   .frame(width: onEdge || grabbed != nil ? 2 : 1)
   .frame(width: 9)
   .contentShape(Rectangle())
   .onHover { over in
    onEdge = over
    if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
   }
   .onDisappear {
    if onEdge {
     NSCursor.pop()
     onEdge = false
    }
   }
   .gesture(
    DragGesture(minimumDistance: 1, coordinateSpace: .global)
     .onChanged { value in
      if grabbed == nil { grabbed = width }
      let delta = growsRight ? value.translation.width : -value.translation.width
      let wanted = (grabbed ?? width) + delta
      width = min(range.upperBound, max(range.lowerBound, wanted))
     }
     .onEnded { _ in grabbed = nil }
   )
   .modifier(
    OneClick(double: true) {
     withAnimation(Motion.settle) { width = standard }
    }
   )
   .animation(Motion.quick, value: onEdge)
 }
}

struct PanelHeaderGesture: ViewModifier {
 let browser: Browser
 let panel: SidePanel
 let active: Bool

 func body(content: Content) -> some View {
  if active {
   content
    .contentShape(Rectangle())
    .gesture(
     DragGesture(minimumDistance: 12, coordinateSpace: .global)
      .onEnded { browser.dropPanel(panel, atX: $0.location.x) }
    )
    .modifier(OneClick(double: true) { browser.toggleExpanded(panel) })
  } else {
   content.contentShape(Rectangle())
  }
 }
}

extension Browser {
 /// The side a panel sits on: the one chosen, or the one away from the tab column.
 func panelOnLeft(_ panel: SidePanel) -> Bool {
  if let chosen = panel == .chat ? prefs.chatSide : prefs.marksSide { return chosen == .left }
  return prefs.sidebar && prefs.sidePosition == .right
 }
 func movePanel(_ panel: SidePanel, toLeft left: Bool) {
  withAnimation(Motion.glide) {
   if panel == .chat {
    prefs.chatSide = left ? .left : .right
   } else {
    prefs.marksSide = left ? .left : .right
   }
  }
 }
 /// A header let go of: the panel goes to the half of the window it was let go in.
 func dropPanel(_ panel: SidePanel, atX x: CGFloat) {
  guard let width = window?.contentView?.bounds.width, width > 0 else { return }
  movePanel(panel, toLeft: x < width / 2)
 }
 func toggleExpanded(_ panel: SidePanel) {
  withAnimation(Motion.glide) { expandedPanel = expandedPanel == panel ? nil : panel }
 }
 func togglePopped(_ panel: SidePanel) {
  if expandedPanel == panel { expandedPanel = nil }
  if panel == .chat { prefs.chatPopped.toggle() } else { prefs.marksPopped.toggle() }
 }
 func setPanelWidth(_ panel: SidePanel, _ width: CGFloat) {
  let clamped = min(panel.range.upperBound, max(panel.range.lowerBound, width))
  if panel == .chat { prefs.chatWidth = clamped } else { prefs.marksWidth = clamped }
 }
 /// Ubi Chat's own window follows the chat being open and popped out.
 func followChatWindow() -> AnyCancellable {
  $assisting.map { $0 != nil }.combineLatest(prefs.$chatPopped)
   .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
   .sink { [weak self] open, popped in self?.placeChatWindow(open && popped) }
 }
 func placeChatWindow(_ on: Bool) {
  guard on, let assistant = assisting else {
   chatWindow?.close()
   chatWindow = nil
   return
  }
  guard chatWindow == nil else { return }
  chatWindow = PanelWindow(
   title: "Ubi Chat", frameKey: "ai.window", size: NSSize(width: 420, height: 640),
   content: AssistantPanel(
    browser: self, assistant: assistant, onLeft: false, width: nil, popped: true)
  ) { [weak self] in
   self?.chatWindow = nil
   self?.closeAssistant()
  }
 }
}

struct PanelMenu<Extra: View>: View {
 let browser: Browser
 let panel: SidePanel
 let onLeft: Bool
 let popped: Bool
 @ViewBuilder let extra: () -> Extra

 var body: some View {
  Menu {
   extra()
   if !popped {
    Button(onLeft ? "Move to Right Side" : "Move to Left Side") {
     browser.movePanel(panel, toLeft: !onLeft)
    }
    Button(browser.expandedPanel == panel ? "Back to Sidebar Width" : "Expand") {
     browser.toggleExpanded(panel)
    }
   }
   Button(popped ? "Back to the Window" : "Open in Separate Window") {
    browser.togglePopped(panel)
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
}

final class SidePanelWindow: NSPanel {
 override var canBecomeKey: Bool { true }
 override var canBecomeMain: Bool { false }
}

/// A side panel in a window of its own; its place and size remembered, given back only while a screen still shows most of it.
@MainActor
final class PanelWindow: NSObject, NSWindowDelegate {
 /// The bookmarks', one for the app: the same bookmarks in every window, opened in the window in front.
 static var bookmarks: PanelWindow?
 private static var bookmarksCancellable: AnyCancellable?

 private let window: SidePanelWindow
 private let frameKey: String
 private var closed: (() -> Void)?

 var frame: NSRect { window.frame }

 init(
  title: String, frameKey: String, size: NSSize, content: some View, closed: @escaping () -> Void
 ) {
  self.frameKey = frameKey
  self.closed = closed
  let spot: NSRect
  if Store.testing {
   spot = NSRect(origin: NSPoint(x: -20000, y: -20000), size: size)
  } else if let saved = Self.remembered(frameKey) {
   spot = saved
  } else {
   let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
   spot = NSRect(
    x: round(screen.midX - size.width / 2),
    y: round(screen.midY - size.height / 2),
    width: size.width,
    height: size.height
   )
  }
  window = SidePanelWindow(
   contentRect: spot,
   styleMask: [.titled, .closable, .resizable],
   backing: .buffered,
   defer: false
  )
  window.isReleasedWhenClosed = false
  window.hidesOnDeactivate = false
  window.minSize = NSSize(width: 280, height: 360)
  window.title = title
  super.init()
  window.delegate = self
  window.contentView = NSHostingView(rootView: content)
  window.setFrame(spot, display: true)
  if Store.testing {
   window.orderFront(nil)
  } else {
   window.makeKeyAndOrderFront(nil)
  }
 }

 private static func remembered(_ key: String) -> NSRect? {
  guard let text = Store.settings.string(forKey: key) else { return nil }
  let frame = NSRectFromString(text)
  let shown = NSScreen.screens.contains {
   let seen = $0.visibleFrame.intersection(frame)
   return seen.width * seen.height > 0.6 * frame.width * frame.height
  }
  return frame.width > 100 && shown ? frame : nil
 }

 private func saveFrame() {
  guard !Store.testing else { return }
  Store.settings.set(NSStringFromRect(window.frame), forKey: frameKey)
 }

 func windowDidMove(_ notification: Notification) { saveFrame() }
 func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

 func windowWillClose(_ notification: Notification) {
  saveFrame()
  let action = closed
  closed = nil
  action?()
 }

 func close() {
  closed = nil
  window.close()
 }

 static func followBookmarks() {
  guard bookmarksCancellable == nil else { return }
  bookmarksCancellable = Shared.prefs.$bookmarksSidebar.combineLatest(Shared.prefs.$marksPopped)
   .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
   .sink { open, popped in
    if open && popped {
     guard bookmarks == nil else { return }
     bookmarks = PanelWindow(
      title: "Bookmarks",
      frameKey: "bookmarks.window",
      size: NSSize(width: 280, height: 560),
      content: FrontBookmarks()
     ) {
      bookmarks = nil
      Shared.prefs.bookmarksSidebar = false
     }
    } else {
     bookmarks?.close()
     bookmarks = nil
    }
   }
 }
}

private struct FrontBookmarks: View {
 @ObservedObject var front = Front.shared

 var body: some View {
  BookmarksSidebar(
   browser: front.browser ?? SceneSlot.shared.browser,
   bookmarks: Shared.bookmarks,
   onLeft: false,
   width: nil,
   popped: true
  )
 }
}
