import PhiceCore
import QuartzCore
import Testing
@testable import PhiceiOS

/// A lifted finger's last sample has a zero radius; the light must fade from where it was.
@MainActor @Test func aLiftedFingersLightFadesOutAtItsLastSize() throws {
    let renderer = GlowRenderer()
    let finger = Touch(id: 1, x: 100, y: 100, radius: 24.3, phase: .moved, t: 1)
    renderer.update([1: finger], verdicts: [:], appearance: Appearance(), now: 1)
    let root = try #require(renderer.layer.sublayers?.first)
    let size = try #require(root.sublayers?.first?.bounds.width)
    #expect(size > 0)

    renderer.update([:], verdicts: [:], appearance: Appearance(), now: 1.01)
    #expect(root.opacity == 0)
    #expect(root.sublayers?.first?.bounds.width == size)
    #expect(root.superlayer != nil)

    renderer.update([:], verdicts: [:], appearance: Appearance(), now: 1.3)
    #expect(root.superlayer == nil)
}
