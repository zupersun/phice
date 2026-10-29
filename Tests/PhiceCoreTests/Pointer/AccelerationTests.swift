import Testing
@testable import PhiceCore

// Expected values were computed by IOHIDFamily's own IOHIDParametricAcceleration,
// IOHIDPointerAccelerator and IOHIDScrollAccelerator, copied verbatim into a C++ harness and fed the
// same input in trackpad counts (pad points x 400/153) at the trackpad's resolution and report rate.

/// (dx, dy, dt) in pad points and seconds; the first nine at the trackpad's 120 Hz.
private let moves: [(Double, Double, Double)] = [
    (0.3, 0.1, 1.0 / 120), (1, 0, 1.0 / 120), (2, -1.5, 1.0 / 120), (5, 3, 1.0 / 120),
    (12, -7, 1.0 / 120), (25, 10, 1.0 / 120), (60, 0, 1.0 / 120), (120, 80, 1.0 / 120),
    (300, -200, 1.0 / 120), (10, 0, 1.0 / 60), (10, 0, 0.004), (10, 0, 0.05), (40, 0, 1.0 / 60),
]

/// Screen points out, x axis; y always keeps the input's direction.
private let pointerGolden: [(speed: Double, x: [Double])] = [
    (0.6875, [0.18070747757140351, 0.74728353458592911, 2.0757325537576317, 8.4761805152163205,
              38.979132295629967, 124.49257093433242, 338.74968570896732, 516.0832148667597,
              864.36431991555207, 15.487280783348174, 25.053796027245969, 9.166718503439677,
              172.53980695839977]),
    (0.6, [0.18246331491364226, 0.7267520154636139, 1.9288167684494069, 7.5096339237182645,
           33.254015052797385, 104.97752957478184, 287.08576598163285, 439.50250413264354,
           737.05978659897437, 13.821442016220727, 21.641428262106562, 8.6529210998713886,
           145.90532480271781]),
    (0, [0.18823529411764703, 0.62745098039215674, 1.2549019607843135, 3.1372549019607834,
         7.5294117647058814, 15.686274509803917, 36.914396873342483, 56.068431697408627,
         93.829466611431684, 6.2745098039215677, 6.2745098039215677, 6.2745098039215677,
         25.098039215686271]),
    (3, [0.18823699452865109, 1.3736571900424628, 5.7715631903120421, 31.920787187498178,
         180.77368836669476, 624.93932957947095, 1452.0108869259057, 2087.6888414521504,
         3438.306068444158, 55.952418231226929, 108.40643336982724, 22.52535687916793,
         847.86287940633247]),
]

@Test(arguments: pointerGolden.indices)
func pointerMatchesIOHIDFamily(_ row: Int) {
    let (speed, golden) = pointerGolden[row]
    var accel = PointerAcceleration(curves: ThisMac.pointer, trackingSpeed: speed)
    for ((dx, dy, dt), want) in zip(moves, golden) {
        let out = accel.apply(dx: dx, dy: dy, dt: dt)
        #expect(close(out.dx, want), "speed \(speed) move (\(dx), \(dy), \(dt))")
        #expect(close(out.dy, want * dy / dx), "speed \(speed) keeps direction")
    }
}

@Test func trackingSpeedAboveTheLastCurveUsesTheLastCurve() {
    var top = PointerAcceleration(curves: ThisMac.pointer, trackingSpeed: 3)
    var beyond = PointerAcceleration(curves: ThisMac.pointer, trackingSpeed: 5)
    for (dx, dy, dt) in moves {
        let a = top.apply(dx: dx, dy: dy, dt: dt), b = beyond.apply(dx: dx, dy: dy, dt: dt)
        #expect(a.dx == b.dx && a.dy == b.dy)
    }
}

@Test func withoutCurvesThePointerMovesAt96PointsPerInch() {
    var accel = PointerAcceleration(curves: [], trackingSpeed: 1)
    let out = accel.apply(dx: 153, dy: 0, dt: 0.1)
    #expect(close(out.dx, 96))
}

/// Finger deltas in pad points at 120 Hz, then pixels out (a reversal resets the history).
private let scrollInput: [Double] = [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 30, 30, 5, -3, -6, -12, 0.2]
private let scrollGolden: [(speed: Double, px: [Double])] = [
    (0.3125, [0.79393560610817981, 1.8014175337044414, 4.314656139035824, 11.049503921603241,
              30.470023645539278, 82.543306592467914, 97.395098272703663, 104.90154634353894,
              113.77976100300529, 118.47952621295507, 118.95350402093094, 117.96802869649582,
              19.761061728273035, -3.6630847472530306, -9.2480863878987982, -24.902562420440049,
              0.12461970978354288]),
    (1.5, [1.6692447540475566, 4.5685204906965913, 13.237144256731449, 40.41463964961298,
           129.04649381720395, 388.33586283683331, 489.45311592603457, 545.92634195571532,
           612.71977321278075, 649.37944167514536, 657.28732700867374, 654.61299518220267,
           109.44547016875902, -12.387920157751541, -35.84611915891638, -108.59316779587716,
           0.13704399359327482]),
]

@Test(arguments: scrollGolden.indices)
func scrollMatchesIOHIDFamily(_ row: Int) {
    let (speed, golden) = scrollGolden[row]
    var vertical = ScrollAcceleration(curves: ThisMac.scroll, speed: speed)
    var horizontal = ScrollAcceleration(curves: ThisMac.scroll, speed: speed)
    for (d, want) in zip(scrollInput, golden) {
        #expect(close(vertical.apply(dx: 0, dy: d, dt: 1.0 / 120).dy, want), "speed \(speed) dy \(d)")
        #expect(close(horizontal.apply(dx: d, dy: 0, dt: 1.0 / 120).dx, want), "speed \(speed) dx \(d)")
    }
}

@Test func scrollAxesAccelerateIndependently() {
    var both = ScrollAcceleration(curves: ThisMac.scroll)
    var alone = ScrollAcceleration(curves: ThisMac.scroll)
    for _ in 0 ..< 6 {
        let b = both.apply(dx: 2, dy: 30, dt: 1.0 / 120)
        let a = alone.apply(dx: 2, dy: 0, dt: 1.0 / 120)
        #expect(close(b.dx, a.dx))
    }
}

@Test func scrollSpeedDoesNotDependOnHowOftenThePhoneSends() {
    var fast = ScrollAcceleration(curves: ThisMac.scroll)
    var slow = ScrollAcceleration(curves: ThisMac.scroll)
    var fastTotal = 0.0, slowTotal = 0.0
    for _ in 0 ..< 24 { fastTotal += fast.apply(dx: 0, dy: 10, dt: 1.0 / 120).dy }
    for _ in 0 ..< 12 { slowTotal += slow.apply(dx: 0, dy: 20, dt: 1.0 / 60).dy }
    #expect(close(fastTotal, slowTotal, 0.02))
}

@Test func resetForgetsThePreviousGesture() {
    var accel = ScrollAcceleration(curves: ThisMac.scroll)
    let first = accel.apply(dx: 0, dy: 4, dt: nil).dy
    for _ in 0 ..< 8 { _ = accel.apply(dx: 0, dy: 30, dt: 1.0 / 120) }
    accel.reset()
    #expect(close(accel.apply(dx: 0, dy: 4, dt: nil).dy, first))
}
