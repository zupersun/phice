import Foundation
import Testing
@testable import PhiceCore

private func run(_ momentum: Momentum, dt: Double) -> [(dx: Double, dy: Double)] {
    var momentum = momentum
    var steps: [(dx: Double, dy: Double)] = []
    while let step = momentum.step(dt: dt), steps.count < 10_000 { steps.append(step) }
    return steps
}

@Test func momentumDecaysInTheLiftDirectionAndEnds() {
    let steps = run(Momentum(vx: -300, vy: 2000), dt: 1.0 / 60)
    #expect(!steps.isEmpty && steps.count < 5 * 60)
    #expect(steps.allSatisfy { $0.dy > 0 && $0.dx <= 0 })
    #expect(zip(steps, steps.dropFirst()).allSatisfy { abs($1.dy) <= abs($0.dy) })
}

@Test func aFlickCoastsAboutOneTimeConstantOfItsSpeed() {
    // Fast momentum keeps 0.975 of its speed every 8 ms: a time constant of ~0.316 s.
    let tau = 0.008 / -log(0.975)
    let distance = run(Momentum(vx: 0, vy: 3000), dt: 1.0 / 60).reduce(0) { $0 + $1.dy }
    #expect(distance > 0.75 * 3000 * tau && distance < 3000 * tau)
}

@Test func aSlowLiftDoesNotCoast() {
    #expect(run(Momentum(vx: 10, vy: 20), dt: 1.0 / 60).isEmpty)
}

@Test func momentumDistanceDoesNotDependOnTheTickRate() {
    let at60 = run(Momentum(vx: 0, vy: 1500), dt: 1.0 / 60).reduce(0) { $0 + $1.dy }
    let at120 = run(Momentum(vx: 0, vy: 1500), dt: 1.0 / 120).reduce(0) { $0 + $1.dy }
    #expect(close(at60, at120, 0.03))
}

@Test func weakMomentumDiesFasterThanStrong() {
    // Below the tail speed the retention falls toward 0.91 per 8 ms.
    var strong = Momentum(vx: 0, vy: 1000), weak = Momentum(vx: 0, vy: 80)
    let s0 = strong.step(dt: 0.008)!.dy / 1000, w0 = weak.step(dt: 0.008)!.dy / 80
    #expect(w0 < s0)
}
