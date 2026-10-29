import Foundation
import PhiceCore

/// The pad's loop on the main thread: frames into the recogniser, its events to the Mac, its
/// verdicts and grab to the model, haptics on their transitions. Free of UIKit so it can be tested.
@MainActor final class PadLoop {
    let model: AppModel
    /// The pad's own size; see `PadLayout`.
    var size = CGSize.zero
    var play: (Haptic) -> Void = { _ in }
    private var builder = FrameBuilder()
    private var recogniser: Recogniser
    private var batch = FrameBatch()

    init(model: AppModel) {
        self.model = model
        let geometry = PadLayout.geometry(size: .zero, side: model.pillSide)
        recogniser = Recogniser(settings: model.settings, geometry: geometry)
    }

    /// Fingers down now, by id.
    var live: [UInt16: Touch] { builder.live }
    var verdicts: [UInt16: TouchVerdict] { recogniser.verdicts }

    func touches(_ samples: [TouchSample]) {
        let frames = builder.frames(from: samples)
        guard !frames.isEmpty else { return }
        sync()
        var events: [PadEvent] = []
        for frame in frames {
            events += recogniser.feed(frame)
            if model.recording { batch.append(frame) }
        }
        // To the second is all the pill's dimming needs, and every write redraws the pill.
        let now = Date()
        if now.timeIntervalSince(model.lastTouch) >= 1 { model.lastTouch = now }
        publish(events)
    }

    /// `now` is seconds since boot, the clock touch timestamps use.
    func tick(now: Double) {
        sync()
        publish(recogniser.tick(now: now))
        if let frames = batch.take(now: now, recording: model.recording) {
            model.link.send(.frames(frames))
        }
    }

    private func sync() {
        if recogniser.settings != model.settings { recogniser.settings = model.settings }
        if recogniser.dropAction != model.dropAction { recogniser.dropAction = model.dropAction }
        let geometry = PadLayout.geometry(size: size, side: model.pillSide)
        if recogniser.geometry != geometry { recogniser.geometry = geometry }
    }

    private func publish(_ events: [PadEvent]) {
        model.send(events)
        let verdicts = recogniser.verdicts
        let grab = recogniser.grab
        if model.enabled {
            Haptic.cues(verdicts: model.verdicts, verdicts, grab: model.grab, grab).forEach(play)
        }
        // Only on change: the pill observes these, and the pad steps 120 times a second.
        if model.verdicts != verdicts { model.verdicts = verdicts }
        if model.grab != grab { model.grab = grab }
    }
}
