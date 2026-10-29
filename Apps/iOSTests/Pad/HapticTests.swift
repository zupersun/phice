import PhiceCore
import Testing
@testable import PhiceiOS

@Test func aDetentWhenATouchFirstBecomesForce() {
    #expect(Haptic.cues(verdicts: [1: .live], [1: .force], grab: nil, nil) == [.detent])
    #expect(Haptic.cues(verdicts: [1: .force], [1: .force], grab: nil, nil) == [])
    #expect(Haptic.cues(verdicts: [:], [1: .force], grab: nil, nil) == [.detent])
    #expect(Haptic.cues(verdicts: [1: .rejected], [1: .force], grab: nil, nil) == [.detent])
    #expect(Haptic.cues(verdicts: [1: .force, 2: .live], [1: .force, 2: .force], grab: nil, nil)
        == [.detent])
    #expect(Haptic.cues(verdicts: [1: .force], [1: .live], grab: nil, nil) == [])
}

@Test func oneDetentForFingersPressingAtOnce() {
    #expect(Haptic.cues(verdicts: [1: .live, 2: .live], [1: .force, 2: .force], grab: nil, nil)
        == [.detent])
}

@Test func aTickWhenTheHeldItemEntersTheDropZone() {
    let outside = Grab(x: 400, y: 200, inZone: false)
    let inside = Grab(x: 50, y: 200, inZone: true)
    #expect(Haptic.cues(verdicts: [:], [:], grab: nil, outside) == [])
    #expect(Haptic.cues(verdicts: [:], [:], grab: outside, inside) == [.zone])
    #expect(Haptic.cues(verdicts: [:], [:], grab: inside, Grab(x: 40, y: 190, inZone: true)) == [])
    #expect(Haptic.cues(verdicts: [:], [:], grab: inside, outside) == [])
    #expect(Haptic.cues(verdicts: [:], [:], grab: inside, nil) == [])
    #expect(Haptic.cues(verdicts: [:], [:], grab: nil, inside) == [.zone])
}
