import AppKit
import SwiftUI

// File › Share…: the page, wherever the Mac would send it — Mail, Messages,
// AirDrop, Notes, anything else registered. Safari has a button for this on
// its toolbar; this app has no toolbar, so it lives in the File menu instead.

extension Browser {
    /// With no button to open under, the picker opens from the top right
    /// corner of the page, about where Safari keeps its Share button: just
    /// under the row when the tabs are across the top, and beside the
    /// column's page otherwise. The window's own corner is the fallback.
    func share() {
        guard let url = active?.address, let window = self.window ?? Links.window,
              let view = active?.built.flatMap({ $0.window === window ? $0 : nil }) ?? window.contentView
        else { return }
        // A few points in from the corner, so the arrow points at the page
        // rather than at its edge. Flipped or not, the picker hangs below.
        let inset: CGFloat = 12
        let y = view.isFlipped ? inset : view.bounds.maxY - inset
        let anchor = NSRect(x: view.bounds.maxX - inset, y: y, width: 1, height: 1)
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    /// The page in front, offered to your other devices (Handoff). Never a private tab, never a test run.
    func handOff() {
        guard !Store.testing, window?.isKeyWindow == true else { return }
        guard prefs.handoff, let tab = active, !tab.isPrivatePage, !tab.bench, let url = tab.address,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            handoffActivity?.invalidate(); handoffActivity = nil; return
        }
        let activity = handoffActivity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        activity.title = tab.title
        handoffActivity = activity
        activity.becomeCurrent()
    }
}

/// Tabs › Send to Device, and a tab's own menu: your other Macs through Sync, or anywhere the Mac's share picker reaches.
struct SendToDevice: View {
    let browser: Browser
    let tab: Tab
    @ObservedObject var sync = Sync.shared
    var body: some View {
        Menu("Send to Device") {
            if !sync.ready {
                Button("Set Up Sync…") { browser.settingsPage = .sync; browser.tuning = true }
            } else if sync.devices.isEmpty {
                Button("No Other Macs Yet") {}.disabled(true)
            } else {
                ForEach(sync.devices) { device in Button(device.name) { sync.send(tab, to: device, from: browser) } }
            }
            Divider()
            Button("Share…") { browser.select(tab); browser.share() }
        }
        .disabled(tab.isBlank || tab.isPrivatePage)
    }
}
