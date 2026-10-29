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

@Test func aForcePressBloomsThenDispersesAsTheFingerEasesOff() {
    var glow = GlowState()
    _ = glow.step(contact: 10, verdict: .live, now: 1)
    let start = glow.step(contact: 14, verdict: .force, now: 1.1)
    let mid = glow.step(contact: 14, verdict: .force, now: 1.1 + GlowState.bloomTime / 2)
    let full = glow.step(contact: 14, verdict: .force, now: 1.1 + GlowState.bloomTime)
    #expect(start.bloom < mid.bloom && mid.bloom < full.bloom)
    #expect(start.bloomAlpha < mid.bloomAlpha && mid.bloomAlpha <= full.bloomAlpha)
    #expect(full.bloom > full.light)

    // Easing off: the contact shrinks and the extra light spreads out and fades, for good.
    var now = 1.1 + GlowState.bloomTime
    var last = full
    for contact in [12.0, 10, 9, 9, 9, 9, 9, 9, 9, 9] {
        now += 0.05
        let shape = glow.step(contact: contact, verdict: .force, now: now)
        #expect(shape.bloomAlpha <= last.bloomAlpha)
        #expect(shape.bloom >= shape.light)
        last = shape
    }
    #expect(last.bloomAlpha == 0)
    #expect(glow.step(contact: 14, verdict: .force, now: now + 0.05).bloomAlpha == 0)
}

@Test func aSecondForcePressBloomsAgain() {
    var glow = GlowState()
    _ = glow.step(contact: 14, verdict: .force, now: 1)
    _ = glow.step(contact: 9, verdict: .live, now: 2)
    _ = glow.step(contact: 14, verdict: .force, now: 3)
    #expect(glow.step(contact: 14, verdict: .force, now: 3 + GlowState.bloomTime).bloomAlpha > 0)
}

@Test func aRejectedTouchIsDrawnHollow() {
    var glow = GlowState()
    #expect(glow.step(contact: 30, verdict: .rejected, now: 1).hollow)
}
