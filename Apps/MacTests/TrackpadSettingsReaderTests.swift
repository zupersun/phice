import PhiceCore
import Testing
@testable import Phice

/// This Mac's com.apple.AppleMultitouchTrackpad, as `defaults read` prints it.
private var thisMac: [String: Any] { [
    "Clicking": 1, "DragLock": 0, "Dragging": 0, "TrackpadThreeFingerDrag": 0,
    "TrackpadRightClick": 1, "TrackpadCornerSecondaryClick": 0, "TrackpadPinch": 1,
    "TrackpadTwoFingerDoubleTapGesture": 1, "TrackpadThreeFingerHorizSwipeGesture": 2,
    "TrackpadFourFingerHorizSwipeGesture": 2, "TrackpadThreeFingerVertSwipeGesture": 2,
    "TrackpadFourFingerVertSwipeGesture": 2, "TrackpadFourFingerPinchGesture": 2,
    "TrackpadFiveFingerPinchGesture": 2, "TrackpadTwoFingerFromRightEdgeSwipeGesture": 3,
    "TrackpadThreeFingerTapGesture": 0, "TrackpadMomentumScroll": 1,
] }

private func read(_ overrides: [String: Any] = [:], global: [String: Any] = [:],
                  dock: [String: Any] = [:]) -> TrackpadSettings {
    TrackpadSettingsReader.settings(
        trackpad: thisMac.merging(overrides) { $1 }, global: global, dock: dock)
}

@Test func thisMacReadsAsMacOSDefaults() {
    #expect(read(global: ["com.apple.swipescrolldirection": 1]) == TrackpadSettings())
}

@Test func emptyPreferencesGiveDefaults() {
    let empty = TrackpadSettingsReader.settings(trackpad: [:], global: [:], dock: [:])
    #expect(empty == TrackpadSettings())
}

@Test func tapDragAndClicksFollowTheirKeys() {
    let s = read(["Clicking": 0, "DragLock": 1, "TrackpadThreeFingerDrag": 1,
                  "TrackpadMomentumScroll": 0, "TrackpadPinch": 0,
                  "TrackpadTwoFingerDoubleTapGesture": 0])
    #expect(!s.tapToClick)
    #expect(s.dragLock)
    #expect(s.threeFingerDrag)
    #expect(!s.momentumScroll)
    #expect(!s.pinchZoom)
    #expect(!s.smartZoom)
}

@Test func secondaryClickPrefersACornerOverTwoFingers() {
    #expect(read(["TrackpadCornerSecondaryClick": 2]).secondaryClick == .bottomRight)
    #expect(read(["TrackpadCornerSecondaryClick": 1]).secondaryClick == .bottomLeft)
    #expect(read(["TrackpadRightClick": 0]).secondaryClick == .off)
    #expect(read().secondaryClick == .twoFingers)
}

@Test func naturalScrollingFollowsTheGlobalKey() {
    #expect(read(global: ["com.apple.swipescrolldirection": false]).naturalScrolling == false)
    #expect(read(global: ["com.apple.swipescrolldirection": 0]).naturalScrolling == false)
    #expect(read(global: ["com.apple.swipescrolldirection": 1]).naturalScrolling)
}

@Test func trackingSpeedIsClamped() {
    #expect(read(global: ["com.apple.trackpad.scaling": 0.6875]).trackingSpeed == 0.6875)
    #expect(read(global: ["com.apple.trackpad.scaling": 9.0]).trackingSpeed == 3)
    #expect(read(global: ["com.apple.trackpad.scaling": -1.0]).trackingSpeed == 0)
}

@Test func lookUpMovesToAThreeFingerTap() {
    #expect(read().lookUpForceClick)
    #expect(!read(["TrackpadThreeFingerTapGesture": 2]).lookUpForceClick)
}

@Test func pagesComeFromTheScrollKeyAndTheThreeFingerKey() {
    let two: [String: Any] = ["AppleEnableSwipeNavigateWithScrolls": 1]
    let none: [String: Any] = ["AppleEnableSwipeNavigateWithScrolls": 0]
    #expect(read(global: two).swipePages == .twoFingerScroll)
    let three: [String: Any] = ["TrackpadThreeFingerHorizSwipeGesture": 1]
    #expect(read(three, global: none).swipePages == .threeFingerSwipe)
    #expect(read(three, global: two).swipePages == .both)
    #expect(read(global: none).swipePages == .off)
}

@Test func spacesUseThreeFingersThenFour() {
    #expect(read().swipeSpaces == .three)
    #expect(read(["TrackpadThreeFingerHorizSwipeGesture": 0]).swipeSpaces == .four)
    #expect(read(["TrackpadThreeFingerHorizSwipeGesture": 0,
                  "TrackpadFourFingerHorizSwipeGesture": 0]).swipeSpaces == nil)
}

@Test func appExposeNeedsTheDockKey() {
    let fourOnly: [String: Any] = ["TrackpadThreeFingerVertSwipeGesture": 0]
    #expect(read().appExpose == nil)
    #expect(read(dock: ["showAppExposeGestureEnabled": 1]).appExpose == .three)
    let s = read(fourOnly, dock: ["showAppExposeGestureEnabled": true])
    #expect(s.appExpose == .four)
    #expect(s.missionControl == .four)
    #expect(read(["TrackpadThreeFingerVertSwipeGesture": 0,
                  "TrackpadFourFingerVertSwipeGesture": 0]).missionControl == nil)
}

@Test func edgeSwipeAndPinchesMapToTheirFeatures() {
    let off = read(["TrackpadTwoFingerFromRightEdgeSwipeGesture": 0,
                    "TrackpadFourFingerPinchGesture": 0, "TrackpadFiveFingerPinchGesture": 0])
    #expect(!off.notificationCenter)
    #expect(!off.launchpad)
    #expect(!off.showDesktop)
}

@Test func theLiveReadStaysInRange() {
    let s = TrackpadSettingsReader.current()
    #expect((0...3).contains(s.trackingSpeed))
}
