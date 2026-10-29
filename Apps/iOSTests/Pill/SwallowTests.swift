import CoreGraphics
import SwiftUI
import Testing
@testable import PhiceiOS

private let pill = CGPoint(x: 30, y: 196.5)
private let fingers = CGPoint(x: 100, y: 200)

private func swallowed(at t: Double = 1, distance: Double = 100) -> Swallow {
    var s = Swallow()
    s.begin(at: 0)
    s.end(at: t, bead: fingers, distance: distance, swallowed: true)
    return s
}

private func frame(_ s: Swallow, _ t: Double, live: CGPoint? = nil, distance: Double? = nil,
                   reduceMotion: Bool = false) -> Swallow.Frame {
    s.frame(at: t, live: live, distance: distance, pill: pill, reduceMotion: reduceMotion)
}

@Test func theSpringsAreSwiftUIsSpringByDurationAndBounce() {
    for curve in [Swallow.appear, Swallow.gulp, Swallow.pop, Swallow.relax] {
        let spring = Spring(duration: curve.duration, bounce: curve.bounce)
        for t in stride(from: 0.02, through: 1.0, by: 0.07) {
            #expect(abs(curve.step(t) - spring.value(target: 1.0, time: t)) < 1e-6)
        }
    }
    #expect(Swallow.appear == SpringCurve(duration: 0.35, bounce: 0.45))
    #expect(Swallow.gulp == SpringCurve(duration: 0.55, bounce: 0.5))
    #expect(Swallow.pop.bounce == 0.5)
    #expect(Swallow.relax == SpringCurve(duration: 0.4, bounce: 0.4))
}

@Test func nothingShowsBeforeAGrab() {
    let f = frame(Swallow(), 5)
    #expect(f.beadRadius == 0)
    #expect(f.target == 0)
    #expect(f.reach == 0)
    #expect(f.stretch == CGSize(width: 1, height: 1))
}

@Test func theBeadGrowsOnASpringAndFollowsTheFingers() {
    var s = Swallow()
    s.begin(at: 0)
    #expect(frame(s, 0, live: fingers, distance: 400).beadRadius == 0)
    let grown = frame(s, 0.35, live: fingers, distance: 400)
    #expect(grown.bead == fingers)
    #expect(abs(grown.beadRadius - 16 * Swallow.appear.step(0.35)) < 1e-9)
    let peak = (1 ... 60).map { frame(s, Double($0) / 100, live: fingers, distance: 400).beadRadius }.max()!
    #expect(peak > 16.5)
    #expect(abs(frame(s, 2, live: fingers, distance: 400).beadRadius - 16) < 0.05)
}

@Test func thePillLightsAsTheTargetOnceTheBeadAppears() {
    var s = Swallow()
    s.begin(at: 0)
    #expect(frame(s, 0.1, live: fingers, distance: 400).target == 0.5)
    #expect(frame(s, 0.3, live: fingers, distance: 400).target == 1)
}

@Test func thePillReachesTowardTheBeadAsItNears() {
    var s = Swallow()
    s.begin(at: 0)
    #expect(frame(s, 1, live: fingers, distance: 300).reach == 0)
    #expect(frame(s, 1, live: fingers, distance: 190).reach == 8)
    #expect(frame(s, 1, live: fingers, distance: 100).reach == 16)
}

@Test func liftingInTheZonePullsTheBeadInAcceleratingOverPointThreeSeconds() {
    let s = swallowed()
    let quarter = frame(s, 1.15)
    #expect(abs(quarter.bead.x - (100 + (30 - 100) * 0.25)) < 1e-9)
    #expect(quarter.beadRadius < 16 && quarter.beadRadius > 11)
    #expect(frame(s, 1.3).beadRadius == 0)
    #expect(s.merge == 1.3)
}

@Test func theGulpStretchesAboutAThirdWiderAndWobblesOnce() {
    let s = swallowed()
    let widths = stride(from: 1.3, through: 2.5, by: 0.005).map { frame(s, $0).stretch.width }
    let peak = widths.max()!
    #expect(abs(peak - 1.33) < 0.01)
    #expect(widths.min()! < 0.96)
    #expect(abs(widths.last! - 1) < 0.002)
    let crossings = zip(widths, widths.dropFirst()).filter { ($0 - 1) * ($1 - 1) < 0 }.count
    #expect(crossings <= 3)
    #expect(frame(s, 1.4).stretch.height < 1)
}

@Test func theGlyphPopsAndTheReachRelaxesAfterTheMerge() {
    let s = swallowed()
    #expect(frame(s, 1.29).glyphPop == 1)
    #expect(frame(s, 1.37).glyphPop > 1.1)
    #expect(frame(s, 1.29).reach == 16)
    #expect(frame(s, 2.5).reach < 0.5)
    #expect(frame(s, 2.5).target == 0)
}

@Test func liftingOutsideTheZoneShrinksTheBeadAwayInAQuarterSecond() {
    var s = Swallow()
    s.begin(at: 0)
    s.end(at: 1, bead: fingers, distance: 400, swallowed: false)
    #expect(frame(s, 1.1).bead == fingers)
    #expect(frame(s, 1.1).beadRadius < 16)
    #expect(frame(s, 1.25).beadRadius == 0)
    #expect(s.merge == nil)
    #expect(frame(s, 1.3).stretch == CGSize(width: 1, height: 1))
}

@Test func reduceMotionCrossFadesInsteadOfSquashing() {
    let s = swallowed()
    for t in stride(from: 1.0, through: 2.5, by: 0.05) {
        let f = frame(s, t, reduceMotion: true)
        #expect(f.stretch == CGSize(width: 1, height: 1))
        #expect(f.glyphPop == 1)
        #expect(f.reach == 0)
    }
    let fading = frame(s, 1.15, reduceMotion: true)
    #expect(fading.bead == fingers)
    #expect(fading.beadOpacity > 0.3 && fading.beadOpacity < 0.7)
}

@Test func itSettlesWellAfterTheEnd() {
    let s = swallowed()
    #expect(!s.isSettled(at: 1.5))
    #expect(s.isSettled(at: 3))
}
