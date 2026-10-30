import Testing
@testable import PhiceCore

func makeDriver(_ configure: (inout TrackpadSettings) -> Void = { _ in }) -> (MacDriver, FakePoster) {
    var settings = TrackpadSettings()
    configure(&settings)
    let poster = FakePoster()
    let driver = MacDriver(poster: poster, settings: settings,
                           curves: ThisMac.pointer, scrollCurves: ThisMac.scroll)
    return (driver, poster)
}

extension MacDriver {
    @discardableResult
    func send(_ events: PadEvent..., now: Double = 0) -> [MacToPhone] {
        handle(.events(events), now: now)
    }
}

/// What Apple's curve makes of one move, for comparing against what the driver posted.
private func accelerated(_ dx: Double, _ dy: Double, dt: Double,
                         speed: Double = TrackpadSettings().trackingSpeed) -> (Double, Double) {
    var accel = PointerAcceleration(curves: ThisMac.pointer, trackingSpeed: speed)
    let out = accel.apply(dx: dx, dy: dy, dt: dt)
    return (out.dx, out.dy)
}

private func onlyMove(_ poster: FakePoster) -> (dx: Double, dy: Double, dragging: MouseButton?)? {
    guard poster.calls.count == 1, case let .move(dx, dy, dragging) = poster.calls[0]
    else { return nil }
    return (dx, dy, dragging)
}

// MARK: - Validation at the trust boundary

@Test func nonFiniteNumbersAreDropped() {
    let (driver, poster) = makeDriver()
    driver.send(.move(dx: .nan, dy: 1, t: 0), .move(dx: 1, dy: .infinity, t: 0),
                .move(dx: 1, dy: 1, t: .nan), .scroll(dx: .nan, dy: 0, phase: .began, t: 0),
                .scroll(dx: 0, dy: 1, phase: .changed, t: -.infinity), .scrollEnded(vx: .nan, vy: 0))
    driver.tick(now: 0.1)
    #expect(poster.calls.isEmpty)
}

@Test func aHugeDeltaMovesNoFurtherThanFiveHundredPoints() {
    let (driver, poster) = makeDriver()
    driver.send(.move(dx: 1e9, dy: -1e9, t: 1))
    let want = accelerated(500, -500, dt: MacDriver.maxInterval)
    #expect(onlyMove(poster).map { close($0.dx, want.0) && close($0.dy, want.1) } == true)
}

@Test func intervalsAreClampedToATenthOfASecond() {
    let (driver, poster) = makeDriver()
    driver.send(.move(dx: 1, dy: 0, t: 5))
    driver.send(.move(dx: 10, dy: 0, t: 50))        // a 45 s gap counts as 0.1 s
    driver.send(.move(dx: 10, dy: 0, t: 49))        // time running backwards counts as 0
    guard case let .move(slow, _, _) = poster.calls[1], case let .move(back, _, _) = poster.calls[2]
    else { Issue.record("expected three moves"); return }
    #expect(close(slow, accelerated(10, 0, dt: 0.1).0))
    #expect(close(back, accelerated(10, 0, dt: 0).0))
}

@Test func clickCountsAreClampedToOneThroughThree() {
    let (driver, poster) = makeDriver()
    driver.send(.button(.left, down: true, clicks: 9), .button(.left, down: false, clicks: 0))
    #expect(poster.calls == [.button(.left, down: true, clicks: 3),
                             .button(.left, down: false, clicks: 1)])
}

@Test func settingsFromThePhoneAreClamped() {
    let (driver, poster) = makeDriver()
    var wild = TrackpadSettings()
    wild.trackingSpeed = .nan
    _ = driver.handle(.settings(wild), now: 0)
    driver.send(.move(dx: 10, dy: 0, t: 0), .move(dx: 10, dy: 0, t: 1.0 / 120))
    wild.trackingSpeed = 40
    _ = driver.handle(.settings(wild), now: 0)
    driver.send(.move(dx: 10, dy: 0, t: 2.0 / 120))
    guard case let .move(unchanged, _, _) = poster.calls[1],
          case let .move(capped, _, _) = poster.calls[2]
    else { Issue.record("expected three moves"); return }
    #expect(close(unchanged, accelerated(10, 0, dt: 1.0 / 120).0))
    #expect(close(capped, accelerated(10, 0, dt: 1.0 / 120, speed: 3).0))
}

// MARK: - Moving and clicking

@Test func movesAreAcceleratedWithTheIntervalBetweenEventStamps() {
    let (driver, poster) = makeDriver()
    driver.send(.move(dx: 1, dy: 1, t: 2))
    poster.clear()
    driver.send(.move(dx: 12, dy: -7, t: 2 + 1.0 / 120))
    let want = accelerated(12, -7, dt: 1.0 / 120)
    #expect(onlyMove(poster).map { close($0.dx, want.0) && close($0.dy, want.1) && $0.dragging == nil }
        == true)
}

@Test func trackingSpeedComesFromTheSettings() {
    let (slow, slowPoster) = makeDriver { $0.trackingSpeed = 0 }
    let (fast, fastPoster) = makeDriver { $0.trackingSpeed = 3 }
    for driver in [slow, fast] { driver.send(.move(dx: 20, dy: 0, t: 0)) }
    #expect(onlyMove(fastPoster)!.dx > 2 * onlyMove(slowPoster)!.dx)
}

@Test func movesWhileAButtonIsHeldDragIt() {
    let (driver, poster) = makeDriver()
    driver.send(.button(.left, down: true, clicks: 1))
    driver.send(.move(dx: 3, dy: 0, t: 0))
    driver.send(.button(.left, down: false, clicks: 1), .move(dx: 3, dy: 0, t: 0.01))
    let draggings = poster.calls.compactMap { call -> MouseButton?? in
        if case let .move(_, _, dragging) = call { return dragging } else { return nil }
    }
    #expect(draggings == [.left, nil])
}

@Test func aReleaseForAButtonThatIsNotHeldIsNotPosted() {
    let (driver, poster) = makeDriver()
    driver.send(.button(.right, down: false, clicks: 1))
    driver.send(.button(.left, down: true, clicks: 1), .button(.left, down: true, clicks: 1))
    #expect(poster.calls == [.button(.left, down: true, clicks: 1)])
}

@Test func shortcutsAndForceClicksPassThrough() {
    let (driver, poster) = makeDriver()
    driver.send(.shortcut(.missionControl), .forceClick)
    #expect(poster.calls == [.shortcut(.missionControl), .forceClick])
}

// MARK: - The copy gesture

@Test func aFrozenCursorIgnoresMovesUntilThaw() {
    let (driver, poster) = makeDriver()
    driver.send(.freeze(true), .move(dx: 5, dy: 5, t: 0), .freeze(false), .move(dx: 5, dy: 5, t: 0.01))
    #expect(poster.calls.count == 1)
}

@Test func aReleaseAfterAFreezeHappensAtThePressPoint() {
    let (driver, poster) = makeDriver()
    poster.cursor = (100, 200)
    driver.send(.button(.left, down: true, clicks: 1), .move(dx: 30, dy: 0, t: 0), .freeze(true))
    driver.send(.move(dx: 30, dy: 0, t: 0.01), .freeze(false))
    poster.clear()
    driver.send(.button(.left, down: false, clicks: 1))
    #expect(poster.calls == [.moveTo(x: 100, y: 200, dragging: .left),
                             .button(.left, down: false, clicks: 1)])
}

@Test func anOrdinaryReleaseHappensWhereTheCursorIs() {
    let (driver, poster) = makeDriver()
    driver.send(.button(.left, down: true, clicks: 1), .move(dx: 30, dy: 0, t: 0))
    poster.clear()
    driver.send(.button(.left, down: false, clicks: 1))
    #expect(poster.calls == [.button(.left, down: false, clicks: 1)])
}

@Test func aDropPerformsTheActionRepliesAndReleasesAtThePressPoint() {
    for succeeds in [true, false] {
        let (driver, poster) = makeDriver()
        poster.performSucceeds = succeeds
        poster.cursor = (40, 50)
        driver.send(.button(.left, down: true, clicks: 1), .move(dx: 9, dy: 9, t: 0), .freeze(true))
        poster.clear()
        let replies = driver.send(.drop(.cut))
        #expect(replies == [.dropResult(ok: succeeds)])
        #expect(poster.calls == [.perform(.cut), .moveTo(x: 40, y: 50, dragging: .left),
                                 .button(.left, down: false, clicks: 1)])
        poster.clear()
        driver.send(.freeze(false), .button(.left, down: false, clicks: 1))
        #expect(poster.calls.isEmpty, "the phone's own release comes after the drop released it")
    }
}

@Test func aPasteClicksAtTheCursorThenPastes() {
    let (driver, poster) = makeDriver()
    driver.send(.paste(itemID: "clip-7"))
    #expect(poster.calls == [.button(.left, down: true, clicks: 1),
                             .button(.left, down: false, clicks: 1),
                             .paste(itemID: "clip-7")])
}

@Test func otherMessagesPostNothingAndNeedNoReply() {
    let (driver, poster) = makeDriver()
    let replies = driver.handle(.hello(deviceName: "iPhone", appVersion: "2"), now: 0)
        + driver.handle(.heartbeat, now: 0) + driver.handle(.record(true), now: 0)
        + driver.handle(.frames([TouchFrame(t: 0, touches: [])]), now: 0)
    #expect(replies.isEmpty && poster.calls.isEmpty)
}

@Test func aNewPhoneClockDoesNotZeroTheFirstMove() {
    let (driver, poster) = makeDriver()
    driver.send(.move(dx: 1, dy: 0, t: 500))
    // A rebooted or different phone says hello and starts its clock near zero.
    _ = driver.handle(.hello(deviceName: "iPhone", appVersion: "2"), now: 1)
    driver.send(.move(dx: 4, dy: 0, t: 2))
    let expected = accelerated(4, 0, dt: MacDriver.maxInterval)
    guard case let .move(dx, dy, _) = poster.calls.last else { Issue.record("no move"); return }
    #expect(dx == expected.0 && dy == expected.1)
}
