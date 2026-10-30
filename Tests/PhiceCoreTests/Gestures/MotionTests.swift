import Testing
@testable import PhiceCore

private let three: [(UInt16, Double, Double)] = [(1, 350, 200), (2, 400, 190), (3, 450, 200)]
private let four: [(UInt16, Double, Double)] = three + [(4, 500, 210)]
/// A thumb low on the pad and three fingers above it.
private let thumbAndThree: [(UInt16, Double, Double)] = [
    (1, 300, 330), (2, 400, 120), (3, 450, 110), (4, 500, 120),
]

@Test func twoFingersScrollByTheirOwnMotionAndLiftWithAVelocity() {
    var pad = Pad()
    pad.land([(1, 400, 180), (2, 440, 190)])
    pad.move([1, 2], 0, 60)
    pad.lift(1, 2)
    #expect(pad.scrollPhases.first == .began && pad.scrollPhases.last == .ended)
    #expect(Set(pad.scrollPhases.dropFirst().dropLast()) == [.changed])
    // Positive dy is fingers moving down; the Mac decides which way that scrolls.
    #expect(near(pad.scrolled.dx, 0) && near(pad.scrolled.dy, 60))
    #expect(pad.scrollEnds.count == 1)
    #expect(pad.scrollEnds.first?.vx == 0 && pad.scrollEnds.first!.vy > 500)
    #expect(pad.actions.isEmpty && near(pad.travel.dx, 0) && near(pad.travel.dy, 0))
    #expect(pad.events.last == .scrollEnded(vx: pad.scrollEnds[0].vx, vy: pad.scrollEnds[0].vy))
}

@Test func aScrollThatStopsBeforeLiftingLeavesNoMomentum() {
    var pad = Pad()
    pad.land([(1, 400, 180), (2, 440, 190)])
    pad.move([1, 2], 0, 60)
    pad.hold(0.2)
    pad.lift(1, 2)
    #expect(pad.scrollEnds.count == 1 && pad.scrollEnds[0] == (0, 0))
}

@Test func withoutMomentumScrollingNoScrollEndedIsSent() {
    var pad = Pad { $0.momentumScroll = false }
    pad.land([(1, 400, 180), (2, 440, 190)])
    pad.move([1, 2], 0, 60)
    pad.lift(1, 2)
    #expect(pad.scrollPhases.last == .ended && pad.scrollEnds.isEmpty)
}

@Test func aFingerLandingDuringMomentumStopsItOnce() {
    var pad = Pad()
    pad.land([(1, 400, 180), (2, 440, 190)])
    pad.move([1, 2], 0, 60)
    pad.lift(1, 2)
    pad.wait(1)
    pad.clear()
    pad.tap()
    pad.wait(0.6)
    pad.tap()
    #expect(pad.events == [.momentumStop] + click() + click())

    var late = Pad()
    late.land([(1, 400, 180), (2, 440, 190)])
    late.move([1, 2], 0, 60)
    late.lift(1, 2)
    late.wait(3.5)
    late.clear()
    late.tap()
    #expect(late.events == click())
}

@Test func liftingOneOfTwoScrollingFingersEndsTheScroll() {
    var pad = Pad()
    pad.land([(1, 400, 180), (2, 440, 190)])
    pad.move([1, 2], 0, 60)
    pad.lift(1)
    #expect(pad.scrollPhases.last == .ended && pad.scrollEnds.count == 1)
    pad.clear()
    pad.move([2], 0, 40)
    pad.lift(2)
    #expect(pad.events.isEmpty)
}

@Test func pinchingApartZoomsInInRateLimitedSteps() {
    var pad = Pad()
    pad.land([(1, 400, 200), (2, 440, 200)])
    pad.scale([1, 2], by: 2, frames: 12)
    #expect(pad.actions == [.shortcut(.zoomIn)])
    pad.scale([1, 2], by: 2, frames: 60)
    pad.lift(1, 2)
    #expect(pad.actions.count >= 3 && pad.actions.allSatisfy { $0 == .shortcut(.zoomIn) })
    #expect(pad.scrollPhases.isEmpty)
}

@Test func pinchingTogetherZoomsOut() {
    var pad = Pad()
    pad.land([(1, 300, 200), (2, 500, 200)])
    pad.scale([1, 2], by: 0.4, frames: 40)
    pad.lift(1, 2)
    #expect(!pad.actions.isEmpty && pad.actions.allSatisfy { $0 == .shortcut(.zoomOut) })
}

@Test func withoutPinchZoomAPinchIsNoShortcut() {
    var pad = Pad { $0.pinchZoom = false }
    pad.land([(1, 400, 200), (2, 440, 200)])
    pad.scale([1, 2], by: 3, frames: 30)
    pad.lift(1, 2)
    #expect(pad.actions.isEmpty)
}

@Test func threeFingerSwipesSidewaysChangeSpaceOnceHoweverFarTheyGo() {
    var pad = Pad()
    pad.land(three)
    pad.move([1, 2, 3], -400, 0, frames: 20)
    pad.lift(1, 2, 3)
    pad.wait(0.6)
    pad.land(three)
    pad.move([1, 2, 3], 100, 0, frames: 8)
    pad.lift(1, 2, 3)
    // Swiping left brings in the space to the right, as on a Mac.
    #expect(pad.events == [.shortcut(.spaceRight), .shortcut(.spaceLeft)])
}

/// Fingers landing one after another while the hand is already on its way, as real hands do.
private func raggedSwipe(_ pad: inout Pad, fingers: Int, gap: Double, dx: Double, dy: Double) {
    let ids = (1 ... fingers).map(UInt16.init)
    let rate = (dx / 0.15, dy / 0.15)
    for (i, id) in ids.enumerated() {
        pad.land(id, 350 + Double(i) * 50, 200)
        guard i < ids.count - 1 else { break }
        let step = (rate.0 * gap, rate.1 * gap)
        pad.move(Dictionary(uniqueKeysWithValues: ids[...i].map { ($0, step) }), frames: Int(gap * 120))
    }
    pad.move(ids, dx, dy, frames: 12)
    ids.forEach { pad.lift($0) }
}

@Test func threeFingersLandingRaggedlyMidSwipeStillChangeSpace() {
    var pad = Pad()
    raggedSwipe(&pad, fingers: 3, gap: 0.06, dx: -120, dy: 0)
    #expect(pad.actions == [.shortcut(.spaceRight)])
}

@Test func fourFingersLandingRaggedlyMidSwipeStillOpenMissionControl() {
    var pad = Pad { $0.missionControl = [.four] }
    raggedSwipe(&pad, fingers: 4, gap: 0.08, dx: 0, dy: -120)
    #expect(pad.actions == [.shortcut(.missionControl)])
}

@Test func threeFingersUpOpenMissionControlAndDownOpensAppExposeOnlyIfSet() {
    var pad = Pad()
    pad.land(three)
    pad.move([1, 2, 3], 0, -100, frames: 8)
    pad.lift(1, 2, 3)
    pad.wait(0.6)
    pad.land(three)
    pad.move([1, 2, 3], 0, 100, frames: 8)
    pad.lift(1, 2, 3)
    #expect(pad.events == [.shortcut(.missionControl)])

    var expose = Pad { $0.appExpose = [.three] }
    expose.land(three)
    expose.move([1, 2, 3], 0, 100, frames: 8)
    expose.lift(1, 2, 3)
    #expect(expose.events == [.shortcut(.appExpose)])
}

@Test func whenTheMacEnablesThreeAndFourFingersBothSwipe() {
    // This Mac's own setting: both swipe keys at 2, as macOS ships.
    var pad = Pad()
    pad.land(three)
    pad.move([1, 2, 3], -100, 0, frames: 8)
    pad.lift(1, 2, 3)
    pad.wait(0.6)
    pad.land(four)
    pad.move([1, 2, 3, 4], -100, 0, frames: 8)
    pad.lift(1, 2, 3, 4)
    pad.wait(0.6)
    pad.land(four)
    pad.move([1, 2, 3, 4], 0, -100, frames: 8)
    pad.lift(1, 2, 3, 4)
    #expect(pad.events == [.shortcut(.spaceRight), .shortcut(.spaceRight), .shortcut(.missionControl)])
}

@Test func fourFingerSwipesFollowTheMacsChoiceOfFingers() {
    var pad = Pad { $0.swipeSpaces = [.four]; $0.missionControl = [.four] }
    pad.land(four)
    pad.move([1, 2, 3, 4], -100, 0, frames: 8)
    pad.lift(1, 2, 3, 4)
    pad.wait(0.6)
    pad.land(four)
    pad.move([1, 2, 3, 4], 0, -100, frames: 8)
    pad.lift(1, 2, 3, 4)
    pad.wait(0.6)
    pad.land(three)
    pad.move([1, 2, 3], -100, 0, frames: 8)
    pad.lift(1, 2, 3)
    #expect(pad.events == [.shortcut(.spaceRight), .shortcut(.missionControl)])
}

@Test func threeFingerPageSwipesGoBackAndForwardWhenSpacesUseFour() {
    var pad = Pad { $0.swipePages = .threeFingerSwipe; $0.swipeSpaces = [.four] }
    pad.land(three)
    pad.move([1, 2, 3], 100, 0, frames: 8)
    pad.lift(1, 2, 3)
    pad.wait(0.6)
    pad.land(three)
    pad.move([1, 2, 3], -100, 0, frames: 8)
    pad.lift(1, 2, 3)
    #expect(pad.events == [.shortcut(.back), .shortcut(.forward)])
}

@Test func horizontalTwoFingerMotionIsAScrollTheAppTurnsIntoPages() {
    var pad = Pad()
    pad.land([(1, 400, 180), (2, 440, 190)])
    pad.move([1, 2], 100, 0)
    pad.lift(1, 2)
    #expect(pad.actions.isEmpty && near(pad.scrolled.dx, 100))
}

@Test func thumbAndThreeFingersPinchToLaunchpadAndSpreadToShowDesktop() {
    var pad = Pad()
    pad.land(thumbAndThree)
    pad.scale([1, 2, 3, 4], by: 0.5)
    pad.lift(1, 2, 3, 4)
    pad.wait(0.6)
    pad.land(thumbAndThree)
    pad.scale([1, 2, 3, 4], by: 1.8)
    pad.lift(1, 2, 3, 4)
    #expect(pad.events == [.shortcut(.launchpad), .shortcut(.showDesktop)])

    var off = Pad { $0.launchpad = false; $0.showDesktop = false }
    off.land(thumbAndThree)
    off.scale([1, 2, 3, 4], by: 0.5)
    off.lift(1, 2, 3, 4)
    #expect(off.actions.isEmpty)
}

@Test func twoFingersSwipingInFromTheRightEdgeOpenNotificationCentre() {
    var pad = Pad()
    pad.land([(1, 850, 150), (2, 852, 200)])
    pad.move([1, 2], -100, 0, frames: 8)
    pad.lift(1, 2)
    #expect(pad.events == [.shortcut(.notificationCenter)])

    var inside = Pad()
    inside.land([(1, 600, 150), (2, 602, 200)])
    inside.move([1, 2], -100, 0, frames: 8)
    inside.lift(1, 2)
    #expect(inside.actions.isEmpty && near(inside.scrolled.dx, -100))

    var off = Pad { $0.notificationCenter = false }
    off.land([(1, 850, 150), (2, 852, 200)])
    off.move([1, 2], -100, 0, frames: 8)
    off.lift(1, 2)
    #expect(off.actions.isEmpty && near(off.scrolled.dx, -100))
}

@Test func threeFingerDragHoldsTheButtonWhileTheFingersMove() {
    var pad = Pad { $0.threeFingerDrag = true }
    pad.land(three)
    pad.move([1, 2, 3], 60, 20)
    pad.lift(1, 2, 3)
    #expect(pad.actions == [press, release])
    #expect(near(pad.travel.dx, 60) && near(pad.travel.dy, 20))
}

@Test func threeFingerDragNeedsTheFingersToLandTogether() {
    var pad = Pad { $0.threeFingerDrag = true }
    pad.land(1, 350, 200)
    pad.move([1], 30, 0)
    pad.hold(0.2)
    pad.land([(2, 430, 190), (3, 480, 200)])
    pad.move([1, 2, 3], 0, 60)
    pad.lift(1, 2, 3)
    #expect(!pad.actions.contains(press))
}
