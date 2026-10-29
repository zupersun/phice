import Testing
@testable import PhiceCore

private typealias Scroll = (dx: Double, dy: Double, phase: ScrollPhase?, momentum: MomentumPhase?)

private func scrolls(_ poster: FakePoster) -> [Scroll] {
    poster.calls.compactMap {
        if case let .scroll(dx, dy, phase, momentum) = $0 { (dx, dy, phase, momentum) } else { nil }
    }
}

/// A two-finger scroll at 120 Hz with the fingers moving down, then a lift at `speed` points/s.
private func flick(_ driver: MacDriver, speed: Double = 1500, from t: Double = 0) {
    driver.send(.scroll(dx: 0, dy: 4, phase: .began, t: t), now: t)
    for i in 1 ... 6 {
        driver.send(.scroll(dx: 0, dy: 12, phase: .changed, t: t + Double(i) / 120), now: t)
    }
    driver.send(.scroll(dx: 0, dy: 0, phase: .ended, t: t + 7.0 / 120), .scrollEnded(vx: 0, vy: speed),
                now: t)
}

// MARK: - Scrolling

@Test func naturalScrollingMovesTheContentWithTheFingers() {
    // CGEvent: positive scrolls toward the top/left, so the content moves down/right.
    let (driver, poster) = makeDriver { $0.naturalScrolling = true }
    driver.send(.scroll(dx: 5, dy: 5, phase: .began, t: 0))
    let posted = scrolls(poster)[0]
    #expect(posted.dx > 0 && posted.dy > 0)
}

@Test func traditionalScrollingMovesTheContentAgainstTheFingers() {
    let (driver, poster) = makeDriver { $0.naturalScrolling = false }
    driver.send(.scroll(dx: 5, dy: 5, phase: .began, t: 0))
    let posted = scrolls(poster)[0]
    #expect(posted.dx < 0 && posted.dy < 0)
}

@Test func scrollsKeepTheirPhaseAndAreAccelerated() {
    let (driver, poster) = makeDriver()
    driver.send(.scroll(dx: 0, dy: 1, phase: .began, t: 0))
    for i in 1 ... 5 { driver.send(.scroll(dx: 0, dy: 30, phase: .changed, t: Double(i) / 120)) }
    driver.send(.scroll(dx: 0, dy: 0, phase: .ended, t: 6.0 / 120))
    let posted = scrolls(poster)
    #expect(posted.map(\.phase) == [.began] + Array(repeating: .changed, count: 5) + [.ended])
    #expect(posted.allSatisfy { $0.momentum == nil })
    var accel = ScrollAcceleration(curves: ThisMac.scroll)
    #expect(close(posted[0].dy, accel.apply(dx: 0, dy: 1, dt: nil).dy))
    #expect(posted[5].dy / 30 > 2 * posted[0].dy, "a sustained fast scroll gains more per point")
    #expect(posted[6].dy == 0)
}

@Test func scrollDeltasAreClampedLikeMoves() {
    let (huge, hugePoster) = makeDriver()
    let (capped, cappedPoster) = makeDriver()
    huge.send(.scroll(dx: -1e12, dy: 1e12, phase: .began, t: 0))
    capped.send(.scroll(dx: -500, dy: 500, phase: .began, t: 0))
    #expect(scrolls(hugePoster)[0].dy == scrolls(cappedPoster)[0].dy)
    #expect(scrolls(hugePoster)[0].dx == scrolls(cappedPoster)[0].dx)
}

// MARK: - Momentum

@Test func momentumRunsFromTheTickAfterTheLift() {
    let (driver, poster) = makeDriver()
    flick(driver)
    poster.clear()
    var t = 0.0
    while t < 4 { t += 1.0 / 60; _ = driver.handle(.heartbeat, now: t); driver.tick(now: t) }
    let posted = scrolls(poster)
    #expect(posted.first?.momentum == .begin && posted.last?.momentum == .end)
    #expect(posted.dropFirst().dropLast().allSatisfy { $0.momentum == .continue })
    #expect(posted.allSatisfy { $0.phase == nil })
    let moving = posted.dropLast()
    #expect(moving.count > 10 && moving.allSatisfy { $0.dy > 0 }, "coasts the way the fingers went")
    #expect(posted.last.map { $0.dx == 0 && $0.dy == 0 } == true)
}

@Test func momentumFollowsTheScrollDirectionSetting() {
    let (driver, poster) = makeDriver { $0.naturalScrolling = false }
    flick(driver)
    poster.clear()
    driver.tick(now: 1.0 / 60)
    #expect(scrolls(poster).first.map { $0.momentum == .begin && $0.dy < 0 } == true)
}

@Test func noMomentumWhenItIsSwitchedOffOrTheLiftIsSlow() {
    let (off, offPoster) = makeDriver { $0.momentumScroll = false }
    let (slow, slowPoster) = makeDriver()
    flick(off)
    flick(slow, speed: 5)
    offPoster.clear()
    slowPoster.clear()
    for driver in [off, slow] { driver.tick(now: 0.02); driver.tick(now: 0.04) }
    #expect(offPoster.calls.isEmpty && slowPoster.calls.isEmpty)
}

@Test func aFingerLandingStopsMomentum() {
    let (driver, poster) = makeDriver()
    flick(driver)
    driver.tick(now: 0.02)
    poster.clear()
    driver.send(.momentumStop, now: 0.03)
    driver.tick(now: 0.05)
    #expect(poster.calls == [.scroll(dx: 0, dy: 0, phase: nil, momentum: .end)])
}

@Test func aNewScrollEndsMomentumFirst() {
    let (driver, poster) = makeDriver()
    flick(driver)
    driver.tick(now: 0.02)
    poster.clear()
    driver.send(.scroll(dx: 0, dy: 3, phase: .began, t: 1), now: 0.03)
    #expect(scrolls(poster).map(\.momentum) == [.end, nil])
    #expect(scrolls(poster).map(\.phase) == [nil, .began])
}

// MARK: - On/off and silence

@Test func switchingOffReleasesStopsAndIgnoresUntilOn() {
    let (driver, poster) = makeDriver()
    poster.cursor = (10, 10)
    driver.send(.button(.left, down: true, clicks: 2))
    flick(driver)
    driver.tick(now: 0.02)
    poster.clear()
    _ = driver.handle(.enabled(false), now: 0.03)
    #expect(poster.calls == [.button(.left, down: false, clicks: 2),
                             .scroll(dx: 0, dy: 0, phase: nil, momentum: .end)])
    poster.clear()
    driver.send(.move(dx: 4, dy: 0, t: 1), .button(.right, down: true, clicks: 1), now: 0.04)
    driver.tick(now: 0.06)
    #expect(poster.calls.isEmpty)
    _ = driver.handle(.enabled(true), now: 0.07)
    driver.send(.move(dx: 4, dy: 0, t: 1.1), now: 0.08)
    #expect(poster.calls.count == 1)
}

@Test func silenceReleasesTheButtonAndStopsMomentum() {
    let (driver, poster) = makeDriver()
    driver.send(.button(.left, down: true, clicks: 1), now: 0)
    flick(driver, from: 0)
    driver.tick(now: 0.1)
    poster.clear()
    driver.tick(now: 0.45)
    #expect(!poster.calls.contains(.button(.left, down: false, clicks: 1)))
    poster.clear()
    driver.tick(now: 0.51)
    #expect(poster.calls == [.button(.left, down: false, clicks: 1),
                             .scroll(dx: 0, dy: 0, phase: nil, momentum: .end)])
    poster.clear()
    driver.tick(now: 0.6)
    #expect(poster.calls.isEmpty, "released once, not every tick")
}

@Test func anyMessageKeepsTheButtonHeld() {
    let (driver, poster) = makeDriver()
    driver.send(.button(.left, down: true, clicks: 1), now: 0)
    _ = driver.handle(.heartbeat, now: 0.4)
    _ = driver.handle(.hello(deviceName: "iPhone", appVersion: "2"), now: 0.8)
    _ = driver.handle(.settings(TrackpadSettings()), now: 1.2)
    driver.tick(now: 1.6)
    #expect(poster.calls == [.button(.left, down: true, clicks: 1)])
}

@Test func silenceDuringACopyReleasesAtThePressPointAndThaws() {
    let (driver, poster) = makeDriver()
    poster.cursor = (7, 8)
    driver.send(.button(.left, down: true, clicks: 1), .move(dx: 20, dy: 0, t: 0), .freeze(true),
                now: 0)
    poster.clear()
    driver.tick(now: 1)
    #expect(poster.calls == [.moveTo(x: 7, y: 8, dragging: .left),
                             .button(.left, down: false, clicks: 1)])
    driver.send(.move(dx: 2, dy: 0, t: 1), now: 1)
    #expect(poster.calls.count == 3, "a new connection is not left frozen")
}

@Test func scrollSpeedPicksTheScrollCurve() {
    func firstScroll(_ speed: Double?) -> Double {
        let poster = FakePoster()
        let driver = speed.map {
            MacDriver(poster: poster, settings: TrackpadSettings(), curves: ThisMac.pointer,
                      scrollCurves: ThisMac.scroll, scrollSpeed: $0)
        } ?? MacDriver(poster: poster, settings: TrackpadSettings(), curves: ThisMac.pointer,
                       scrollCurves: ThisMac.scroll)
        driver.send(.scroll(dx: 0, dy: 16, phase: .began, t: 0))
        return scrolls(poster)[0].dy
    }
    var macDefault = ScrollAcceleration(curves: ThisMac.scroll, speed: 0.3125)
    #expect(close(firstScroll(nil), macDefault.apply(dx: 0, dy: 16, dt: nil).dy))
    #expect(firstScroll(1.5) > 2 * firstScroll(nil))
    #expect(firstScroll(.nan) == firstScroll(nil), "a bad speed falls back to the default")
    #expect(firstScroll(40) == firstScroll(3), "clamped to the slider's range")
}
