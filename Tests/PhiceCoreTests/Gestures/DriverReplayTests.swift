import Foundation
import Testing
@testable import PhiceCore

@Test func posterLogWritesOneSortedObjectPerCall() {
    let calls: [FakePoster.Call] = [
        .move(dx: 1.5, dy: -2, dragging: .left), .move(dx: 1.5, dy: -2, dragging: nil),
        .moveTo(x: 10, y: 20, dragging: .left), .button(.left, down: true, clicks: 1),
        .scroll(dx: 0, dy: 12.5, phase: .began, momentum: nil),
        .scroll(dx: 0, dy: -3.25, phase: nil, momentum: .continue),
        .shortcut(.spaceLeft), .forceClick, .perform(.copy), .perform(.shortcut(name: "Save")),
        .paste(itemID: "abc"),
    ]
    #expect(PosterLog.lines(calls) == """
        {"move":{"dragging":"left","dx":1.5,"dy":-2}}
        {"move":{"dx":1.5,"dy":-2}}
        {"moveTo":{"dragging":"left","x":10,"y":20}}
        {"button":{"_0":"left","clicks":1,"down":true}}
        {"scroll":{"dx":0,"dy":12.5,"phase":"began"}}
        {"scroll":{"dx":0,"dy":-3.25,"momentum":"continue"}}
        {"shortcut":{"_0":"spaceLeft"}}
        {"forceClick":{}}
        {"perform":{"_0":{"copy":{}}}}
        {"perform":{"_0":{"shortcut":{"name":"Save"}}}}
        {"paste":{"itemID":"abc"}}

        """)
}

/// The script played through the recogniser and then the real driver, as the Mac would post it.
private func posted(_ play: (inout Pad) -> Void) -> [FakePoster.Call] {
    var pad = Pad()
    play(&pad)
    var recogniser = Recogniser(settings: TrackpadSettings(), geometry: Replay.defaultGeometry)
    let poster = FakePoster()
    let driver = MacDriver(poster: poster, settings: TrackpadSettings(), curves: ThisMac.pointer,
                           scrollCurves: ThisMac.scroll)
    Replay.drive(pad.frames, through: &recogniser, into: driver)
    return poster.calls
}

private func isMove(_ call: FakePoster.Call) -> Bool {
    if case .move = call { true } else { false }
}

@Test func aTapDragPostsAClickThenADragWithTheButtonHeld() {
    let calls = posted { pad in
        pad.tap()
        pad.wait(0.1)
        pad.land(1, 400, 200)
        pad.hold(0.2)
        pad.move([1], 80, 30, frames: 12)
        pad.lift(1)
    }
    let down = FakePoster.Call.button(.left, down: true, clicks: 1)
    let up = FakePoster.Call.button(.left, down: false, clicks: 1)
    #expect(calls.filter { !isMove($0) } == [down, up, down, up])
    let moves = calls.filter(isMove)
    #expect(moves.count == 12)
    #expect(moves.allSatisfy { call in
        if case let .move(dx, dy, .left) = call { dx > 0 && dy > 0 } else { false }
    })
}

@Test func aFastStrokesFirstPointsPostWhatTheSameTravelPostsMidStroke() {
    // 4 pt a frame at 120 Hz: the slop is crossed on the third, and those three must not post as
    // one slow lump. From landing, and after resting first, when no frames come at all.
    for rest in [0.0, 0.3] {
        let calls = posted { pad in
            pad.land(1, 300, 200)
            pad.wait(rest)
            pad.move([1], 48, 0, frames: 12)
            pad.lift(1)
        }
        let steps = calls.compactMap { call -> Double? in
            if case let .move(dx, _, _) = call, dx != 0 { dx } else { nil }
        }
        #expect(steps.count == 12)
        #expect(steps.allSatisfy { close($0, steps[6]) }, "rest \(rest): \(steps)")
    }
}

@Test func aHeldDragSurvivesAStillPauseLongerThanTheSilenceTimeout() {
    // The phone heartbeats while nothing happens; replay must too, or the driver lets go.
    let calls = posted { pad in
        pad.tap()
        pad.wait(0.1)
        pad.land(1, 400, 200)
        pad.wait(1.0)
        pad.move([1], 40, 0)
        pad.lift(1)
    }
    let down = FakePoster.Call.button(.left, down: true, clicks: 1)
    let up = FakePoster.Call.button(.left, down: false, clicks: 1)
    #expect(calls.filter { !isMove($0) } == [down, up, down, up])
    #expect(calls.last == up)
    #expect(calls.filter(isMove).allSatisfy { call in
        if case .move(_, _, .left) = call { true } else { false }
    })
}

@Test func aCopyDropPerformsThenReleasesWhereThePressWas() {
    let calls = posted { pad in
        pad.tap()
        pad.wait(0.1)
        pad.land(1, 600, 200)
        pad.hold(0.2)
        pad.land(2, 640, 220)
        pad.move([1, 2], -500, 0, frames: 20)
        pad.lift(1, 2)
    }
    #expect(calls == [
        .button(.left, down: true, clicks: 1), .button(.left, down: false, clicks: 1),
        .button(.left, down: true, clicks: 1), .perform(.copy),
        .moveTo(x: 0, y: 0, dragging: .left), .button(.left, down: false, clicks: 1),
    ])
}
