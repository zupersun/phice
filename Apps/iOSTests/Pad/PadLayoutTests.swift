import PhiceCore
import Testing
import UIKit
@testable import PhiceiOS

private let screen = CGSize(width: 874, height: 402)

@Test func withTheColumnClosedThePadIsTheWholeScreen() {
    #expect(PadLayout.frame(screen: screen, column: 0, side: .left)
        == CGRect(origin: .zero, size: screen))
}

@Test func theColumnTakesItsWidthFromThePillsSide() {
    #expect(PadLayout.frame(screen: screen, column: 300, side: .left)
        == CGRect(x: 300, y: 0, width: 574, height: 402))
    #expect(PadLayout.frame(screen: screen, column: 300, side: .right)
        == CGRect(x: 0, y: 0, width: 574, height: 402))
}

@Test func theRecogniserSeesThePadsOwnSize() {
    let size = PadLayout.frame(screen: screen, column: 300, side: .right).size
    #expect(PadLayout.geometry(size: size, side: .right)
        == PadGeometry(width: 574, height: 402, pillSide: .right))
}

@Test func onboardingStandsUpAndThePadLiesDown() {
    #expect(PadLayout.orientations(onboarding: true) == .portrait)
    #expect(PadLayout.orientations(onboarding: false) == .landscape)
}

@Test func thePillSideFollowsTheInterfaceOrientation() {
    #expect(PadLayout.pillSide(for: .landscapeLeft) == .left)
    #expect(PadLayout.pillSide(for: .landscapeRight) == .right)
    #expect(PadLayout.pillSide(for: .portrait) == nil)
}

/// These turn the app's own window, so they take turns.
@Suite(.serialized) @MainActor struct TheWindow {
    let model = AppDelegate.setup.model
    let app = UIApplication.shared

    /// Through SwiftUI's own delegate, which must hand the question on to ours.
    @Test func mayOnlyLieDownOnceOnboardingIsDone() {
        let onboarding = model.showOnboarding
        defer { model.showOnboarding = onboarding }
        model.showOnboarding = true
        #expect(app.delegate?.application?(app, supportedInterfaceOrientationsFor: nil) == .portrait)
        model.showOnboarding = false
        #expect(app.delegate?.application?(app, supportedInterfaceOrientationsFor: nil) == .landscape)
    }

    /// Then checks the side table against UIKit itself: turn the window each way and find where the
    /// device's bottom edge (the far end of the screen's fixed, portrait coordinate space) landed.
    @Test func liesDownWhenOnboardingEndsWithThePillOnTheDevicesBottomEdge() async throws {
        let scene = try #require(app.connectedScenes.first as? UIWindowScene)
        let onboarding = model.showOnboarding
        defer { model.showOnboarding = onboarding }
        model.showOnboarding = false
        try await until { scene.effectiveGeometry.interfaceOrientation.isLandscape }
        try #require(scene.effectiveGeometry.interfaceOrientation.isLandscape)
        let turns: [(UIInterfaceOrientation, UIInterfaceOrientationMask)] =
            [(.landscapeLeft, .landscapeLeft), (.landscapeRight, .landscapeRight)]
        for (orientation, mask) in turns {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { Issue.record($0) }
            try await until { scene.effectiveGeometry.interfaceOrientation == orientation }
            try #require(scene.effectiveGeometry.interfaceOrientation == orientation)
            let fixed = scene.screen.fixedCoordinateSpace
            let bottom = fixed.convert(CGPoint(x: fixed.bounds.midX, y: fixed.bounds.maxY),
                                       to: scene.screen.coordinateSpace)
            let side: Side = bottom.x < scene.screen.bounds.midX ? .left : .right
            #expect(PadLayout.pillSide(for: orientation) == side)
        }
    }

    private func until(_ done: () -> Bool) async throws {
        for _ in 0 ..< 500 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }
}
