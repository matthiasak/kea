import AppKit
import SwiftUI

/// Kea's own pictures and words: the flying kea (Icon/kea.gif, put in the app
/// by build.sh) and a few true things about the bird.
enum KeaArt {
    /// Nil when run straight out of .build/, with no bundle to find it in.
    static let flight: NSImage? = Bundle.main.url(forResource: "kea", withExtension: "gif").flatMap(NSImage.init(contentsOf:))

    static let facts = [
        "Kea are the world's only alpine parrot.",
        "A group of kea is called a circus.",
        "Kea live in the mountains of New Zealand's South Island.",
        "A kea's play call is so catching that other kea start playing when they hear it.",
        "Under their olive wings, kea hide bright orange-red feathers.",
        "Kea can solve puzzles that need several steps, in the right order.",
        "Kea are famous for taking cars apart: wiper blades and rubber seals are favourites.",
        "The name kea comes from Māori, after the bird's call: 'keee-aa'.",
        "Kea are about 48 cm long and weigh close to a kilogram.",
        "Young kea have a yellow cere and eye-ring that fade as they grow up.",
        "Kea are endangered: only a few thousand are left in the wild.",
        "Kea will slide down snowy roofs, seemingly just for fun.",
        "Kea eat more than 200 kinds of plant, plus insects and grubs.",
        "A kea's long upper beak is a tool for digging, prying and peeling.",
        "Kea were named New Zealand's Bird of the Year in 2017.",
    ]

    /// The same fact all day, a new one tomorrow.
    static func fact(on day: Date = Date()) -> String {
        facts[(Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0) % facts.count]
    }
}

/// The GIF, flying: AppKit plays an animated image by itself.
struct KeaFlight: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = image
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {}
}

/// One kea fact under the address field on a blank tab, gone while anything
/// is typed or offered (Settings › General › Kea facts on new tabs).
struct KeaFact: View {
    @ObservedObject var omni: Browser.Omni
    var body: some View {
        if omni.typed.isEmpty, omni.offers.isEmpty, omni.siteOffer == nil {
            Text(KeaArt.fact())
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(width: Metrics.fieldWidth)
                // Below the field: its 50 points, and 18 of air.
                .offset(y: 50 + 18)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}
