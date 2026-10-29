import CoreGraphics
import PhiceCore
import SwiftUI
import Testing
@testable import PhiceiOS

/// A pill whose flat side faces the pad at x = 50 (left side), straight from y = 120 to 280.
private let pill = CGRect(x: 10, y: 100, width: 40, height: 200)

/// The neck to a bead of radius 16 with fillets of 8: it joins once the gap is under 16.
private func neck(_ x: CGFloat, _ y: CGFloat = 200, pill: CGRect = pill, side: Side = .left) -> Path? {
    Neck.path(pill: pill, side: side, bead: CGPoint(x: x, y: y), radius: 16, fillet: 8)
}

@Test func aBeadFarFromThePillGrowsNoNeck() {
    #expect(neck(100) == nil)
}

@Test func theNeckFormsOnceTheGapIsUnderTwoFillets() {
    let box = neck(81)?.boundingRect ?? .null
    #expect(!box.isNull)
    #expect(abs(box.minX - 50) < 0.01)
    #expect(box.maxX <= 81)
    #expect(abs(box.midY - 200) < 0.01)
}

@Test func theNeckWidensAsTheBeadNears() {
    #expect(neck(70)!.boundingRect.height > neck(81)!.boundingRect.height)
}

@Test func onTheRightTheNeckIsMirrored() {
    let right = CGRect(x: 300, y: 100, width: 40, height: 200)
    #expect(neck(269, pill: right, side: .right).map { abs($0.boundingRect.maxX - 300) < 0.01 } == true)
}

@Test func aBeadOffTheStraightSideGrowsNoNeck() {
    #expect(neck(70, 110) == nil)
}
