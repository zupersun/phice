import SwiftUI
import UIKit

/// Throwaway: shows and logs `UITouch.majorRadius`, to learn how finely this phone reports contact
/// size before force press is tuned. Every sample goes to Documents/probe.csv.
struct ProbeView: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeTouchView { ProbeTouchView() }
    func updateUIView(_ view: ProbeTouchView, context: Context) {}
}

final class ProbeTouchView: UIView {
    private let label = UILabel()
    private var file: FileHandle?
    private var seen: Set<CGFloat> = []

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        label.text = "Press normally, then hard, then rest a flat thumb.\nEvery touch is saved to probe.csv."
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
        let url = URL.documentsDirectory.appending(path: "probe.csv")
        FileManager.default.createFile(atPath: url.path,
                                       contents: Data("t,touch,phase,x,y,radius,tolerance\n".utf8))
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func record(_ touches: Set<UITouch>, _ event: UIEvent?) {
        var csv = ""
        for touch in touches {
            let id = UInt(bitPattern: ObjectIdentifier(touch).hashValue)
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                let p = sample.location(in: self)
                seen.insert(sample.majorRadius)
                csv += "\(sample.timestamp),\(id),\(sample.phase.rawValue),\(p.x),\(p.y),"
                    + "\(sample.majorRadius),\(sample.majorRadiusTolerance)\n"
            }
        }
        try? file?.write(contentsOf: Data(csv.utf8))
        let now = touches.map { String(format: "%.2f", $0.majorRadius) }.joined(separator: "  ")
        let steps = seen.sorted().map { String(format: "%.2f", $0) }.joined(separator: " ")
        label.text = "radius now: \(now)\n\(seen.count) distinct values seen:\n\(steps)"
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
}
