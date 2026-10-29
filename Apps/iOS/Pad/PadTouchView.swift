import PhiceCore
import SwiftUI
import UIKit

/// The touch surface, wrapped for SwiftUI.
struct PadSurface: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> PadTouchView { PadTouchView(model: model) }
    func updateUIView(_ view: PadTouchView, context: Context) {}
}

/// UIKit touches in, coalesced samples to the loop, light under the fingers, and a display link
/// that ticks the recogniser.
final class PadTouchView: UIView {
    private let loop: PadLoop
    private let glow = GlowRenderer()
    private lazy var haptics = HapticPlayer(view: self)
    private var link: CADisplayLink?
    private var fast: Bool?
    private var lastTouch = 0.0

    init(model: AppModel) {
        loop = PadLoop(model: model)
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        layer.addSublayer(glow.layer)
        loop.play = { [weak self] in self?.haptics.play($0) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        loop.size = bounds.size
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        fast = nil
        pace(touching: false)
        followRotation()
    }

    @objc private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        followRotation()
        loop.tick(now: now)
        draw(now)
        if loop.live.isEmpty, now - lastTouch > 1 { pace(touching: false) }
    }

    /// Full rate while fingers are down and for a second after, so taps resolve on time; a slow
    /// tick otherwise, so a still pad lets the display drop its refresh rate.
    private func pace(touching: Bool) {
        guard let link, touching != fast else { return }
        fast = touching
        link.preferredFrameRateRange = touching
            ? CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            : CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
    }

    /// A half turn keeps the bounds, so nothing relayouts; the scene is read every tick instead.
    private func followRotation() {
        guard let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
              let side = PadLayout.pillSide(for: orientation), loop.model.pillSide != side
        else { return }
        loop.model.pillSide = side
    }

    private func handle(_ event: UIEvent?) {
        guard let event, let touches = event.allTouches else { return }
        // Every finger in the event, not only the changed ones: one event can reach several of the
        // callbacks below, and the builder skips samples it has already built.
        var samples: [TouchSample] = []
        for touch in touches where touch.view === self {
            let key = UInt(bitPattern: ObjectIdentifier(touch))
            for sample in event.coalescedTouches(for: touch) ?? [touch] {
                let point = sample.location(in: self)
                samples.append(TouchSample(key: key, x: point.x, y: point.y,
                                           radius: sample.majorRadius,
                                           phase: Touch.Phase(sample.phase), t: sample.timestamp,
                                           tolerance: sample.majorRadiusTolerance))
            }
        }
        lastTouch = ProcessInfo.processInfo.systemUptime
        loop.touches(samples)
        draw(lastTouch)
    }

    private func draw(_ now: Double) {
        glow.update(loop.live, verdicts: loop.verdicts, appearance: loop.model.appearance, now: now)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        haptics.prepare()
        pace(touching: true)
        handle(event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { handle(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { handle(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        handle(event)
    }
}

extension Touch.Phase {
    init(_ phase: UITouch.Phase) {
        switch phase {
        case .began: self = .began
        case .stationary: self = .stationary
        case .ended: self = .ended
        case .cancelled: self = .cancelled
        // .moved, and the region phases, which only a hovering pointer reports.
        default: self = .moved
        }
    }
}
