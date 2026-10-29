import PhiceCore
import SwiftUI
import Testing
@testable import PhiceiOS

/// Renders the pill's key moments to PNGs for looking at without a phone. Does nothing unless
/// `PILL_SNAPSHOTS` names a folder: `TEST_RUNNER_PILL_SNAPSHOTS=/tmp/pill xcodebuild … test`.
@MainActor @Test func renderPillSnapshots() throws {
    guard let folder = ProcessInfo.processInfo.environment["PILL_SNAPSHOTS"] else { return }
    let g = PillGeometry(screen: CGSize(width: 852, height: 393), side: .left)
    let centre = CGPoint(x: g.pill.midX, y: g.pill.midY)
    let bead = CGPoint(x: 120, y: 200)
    var s = Swallow()
    s.begin(at: 0)
    func pill(_ t: Double, live: CGPoint? = nil, filled: Bool = false, press: Double = 0) -> some View {
        let f = s.frame(at: t, live: live, distance: live.map { Double($0.x) }, pill: centre,
                        reduceMotion: false)
        return PillCanvas(press: press, geometry: g, frame: f, border: 0.85, filled: filled,
                          drawsPill: true)
    }
    var shots: [(String, AnyView)] = [
        ("1-rest", AnyView(PillCanvas(press: 0, geometry: g, frame: .init(), border: 0.85,
                                      filled: false, drawsPill: true))),
        ("2-pressed", AnyView(pill(-1, press: 1))),
        ("3-grab-far", AnyView(pill(1, live: CGPoint(x: 420, y: 180)))),
        ("4-grab-near", AnyView(pill(1, live: bead))),
    ]
    s.end(at: 1, bead: bead, distance: 120, swallowed: true)
    shots += [
        ("5-pull-in", AnyView(pill(1.22))),
        ("6-gulp-peak", AnyView(pill(1.41, filled: true))),
        ("7-settled-full", AnyView(pill(3, filled: true))),
        ("8-menu", AnyView(ZStack(alignment: .topLeading) {
            MorphSurface(surface: .menu, geometry: g, border: 0.85)
            HoldMenuView(geometry: g, highlight: .settings, enabled: true)
        })),
        ("9-column", AnyView(ZStack(alignment: .topLeading) {
            MorphSurface(surface: .column, geometry: g, border: 0.85)
            ClipboardColumn(geometry: g, items: [
                ClipItem(id: "1", kind: .text, preview: "Meeting moved to 3pm, can you still make it?",
                         date: .now),
                ClipItem(id: "2", kind: .link, preview: "https://phice.app/mac", date: .now),
                ClipItem(id: "3", kind: .image, preview: "Screenshot 14.02.31.png", date: .now),
                ClipItem(id: "4", kind: .file, preview: "Q3-deck.key", date: .now),
            ], carried: "2") { _ in }
        })),
    ]
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for (name, view) in shots {
        // The pill's moments are cropped to the edge it lives on, the menu and column shown whole.
        let width: CGFloat = name.hasPrefix("8") || name.hasPrefix("9") ? 852 : 200
        let renderer = ImageRenderer(content: view.frame(width: 852, height: 393)
            .frame(width: width, height: 393, alignment: .leading).clipped().background(Color.black)
            .environment(\.colorScheme, .dark))
        renderer.scale = 3
        let png = try #require(renderer.uiImage?.pngData())
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
