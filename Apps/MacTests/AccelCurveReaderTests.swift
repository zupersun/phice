import Foundation
import PhiceCore
import Testing
@testable import Phice

@Test func ioregDictionariesBecomeCurvesSortedByIndex() {
    let raw: [[String: Any]] = [
        ["HIDAccelIndex": 8192, "HIDAccelGainLinear": 64881, "HIDAccelGainCubic": 5243]
            as [String: Any],
        ["HIDAccelIndex": 0, "HIDAccelGainLinear": 65536] as [String: Any],
    ]
    let curves = AccelCurveReader.curves(from: raw)
    #expect(curves.map(\.index) == [0, 0.125])
    #expect(curves[0].gainLinear == 1)
    #expect(curves[1].gainCubic == 5243.0 / 65536)
}

@Test func entriesThatAreNotNumbersAreSkipped() {
    let raw: [[String: Any]] = [["HIDAccelIndex": "zero"], ["HIDAccelIndex": 65536]]
    #expect(AccelCurveReader.curves(from: raw).map(\.index) == [1])
}

@Test func theEmbeddedDefaultsAreThisMacsTables() {
    #expect(DefaultCurves.pointerCurves.count == 10)
    #expect(DefaultCurves.scrollCurves.count == 10)
    #expect(DefaultCurves.pointerCurves.first?.gainLinear == 1)
    let indexes = DefaultCurves.pointerCurves.map(\.index)
    #expect(indexes == indexes.sorted())
    #expect(DefaultCurves.scrollCurves.last?.index == 3)
}

@Test func readingNeverReturnsNothing() {
    let (pointer, scroll) = AccelCurveReader.read()
    #expect(!pointer.isEmpty)
    #expect(!scroll.isEmpty)
}
