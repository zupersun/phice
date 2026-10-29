import Foundation
import Testing
@testable import PhiceCore

@Test func framesRoundTripAcrossArbitrarySplits() throws {
    let messages: [PhoneToMac] = [
        .hello(deviceName: "iPhone", appVersion: "2.0"),
        .events([.move(dx: 1.5, dy: -2, t: 0.1), .button(.left, down: true, clicks: 1),
                 .drop(.shortcut(name: "Save"))]),
        .heartbeat,
    ]
    var wire = Data()
    for message in messages { wire.append(try FrameCodec.encode(message)) }
    var decoder = FrameDecoder<PhoneToMac>()
    var got: [PhoneToMac] = []
    for start in stride(from: 0, to: wire.count, by: 3) {
        got += try decoder.push(wire.subdata(in: start ..< min(start + 3, wire.count)))
    }
    #expect(got == messages)
}

@Test func oversizedFrameIsRefusedBeforeItIsBuffered() {
    var decoder = FrameDecoder<PhoneToMac>()
    var header = Data()
    withUnsafeBytes(of: UInt32(FrameCodec.maxFrame + 1).bigEndian) { header.append(contentsOf: $0) }
    #expect(throws: FrameDecoder<PhoneToMac>.Failure.oversized(FrameCodec.maxFrame + 1)) {
        try decoder.push(header)
    }
}

@Test func bodyThatIsNotAMessageThrows() {
    var decoder = FrameDecoder<PhoneToMac>()
    let body = Data(#"{"nope":1}"#.utf8)
    var frame = Data()
    withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
    frame.append(body)
    #expect(throws: (any Error).self) { try decoder.push(frame) }
}

@Test func accelCurveDecodesIoregFixedPoint() {
    // Curve index 2 as this Mac's built-in trackpad reports it.
    let curve = AccelCurve(ioreg: [
        "HIDAccelIndex": 32768, "HIDAccelGainLinear": 64225, "HIDAccelGainCubic": 6554,
        "HIDAccelGainParabolic": 43254, "HIDAccelTangentSpeedLinear": 471859,
        "HIDAccelTangentSpeedParabolicRoot": 1245184,
    ])
    #expect(curve.index == 0.5)
    #expect(curve.tangentSpeedParabolicRoot == 19)
    #expect(curve.gainQuartic == 0)
}
