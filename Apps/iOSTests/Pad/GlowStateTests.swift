import PhiceCore
import Testing
@testable import PhiceiOS

@Test func theLightReachesPastTheFingersEdge() {
    var glow = GlowState()
    let shape = glow.step(contact: 10, verdict: .live, now: 1)
    #expect(shape.light == 10 * GlowState.spread)
    #expect(GlowState.spread > 1)
    #expect(shape.bloomAlpha == 0)
    #expect(!shape.hollow)
}

@Test func contactSizeStepsAreEasedNotJumped() {
    var glow = GlowState()
    _ = glow.step(contact: 10, verdict: .live, now: 1)
    let next = glow.step(contact: 20, verdict: .live, now: 1.008)
    #expect(next.light > 10 * GlowState.spread)
    #expect(next.light < 20 * GlowState.spread)
}

@Test func aContactStepTakesAbout80msToArrive() {
    // The digitizer reports radius in steps of 2 x majorRadiusTolerance: 12.1 pt on an iPhone 17.
    var glow = GlowState()
    _ = glow.step(contact: 24.3, verdict: .live, now: 1)
    let halfway = (24.3 + 36.4) / 2 * GlowState.spread
    #expect(glow.step(contact: 36.4, verdict: .live, now: 1.04).light < halfway)
    #expect(glow.step(contact: 36.4, verdict: .live, now: 1.24).light > 35 * GlowState.spread)
}

@Test func aPressLiftsTheLightAndItsReleaseDropsItAtOnce() {
    var glow = GlowState()
    #expect(glow.step(contact: 24.3, verdict: .live, now: 1).bloomAlpha == 0)
    let pressed = glow.step(contact: 24.3, verdict: .pressed, now: 1.01)
    #expect(pressed.bloomAlpha > 0)
    #expect(pressed.bloom > pressed.light)
    #expect(glow.step(contact: 36.4, verdict: .live, now: 2).bloomAlpha == 0)
}

@Test func aRejectedTouchIsDrawnHollow() {
    var glow = GlowState()
    #expect(glow.step(contact: 30, verdict: .rejected, now: 1).hollow)
}
