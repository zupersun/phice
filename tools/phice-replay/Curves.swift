import PhiceCore

/// The built-in trackpad's curves on the Mac the goldens are made on, as `ioreg -c
/// AppleMultitouchDevice -r -d1` lists them (16.16 fixed point). The same values as
/// `Tests/PhiceCoreTests/Pointer/ThisMac.swift`, and what the agent reads from ioreg there, so
/// `--driver` output diffs against that agent's `--fake-poster` log.
enum Curves {
    static let pointer: [AccelCurve] = [
        [0, 65536, 484966, 0, 0, 1376256], [8192, 64881, 478413, 5243, 32768, 1310720],
        [32768, 64225, 471859, 6554, 43254, 1245184], [45056, 62915, 465306, 7864, 54395, 1179648],
        [57344, 61604, 458752, 9830, 65536, 1114112], [65536, 60293, 458752, 11796, 75366, 1048576],
        [98304, 58327, 458752, 13763, 85197, 983040], [131072, 56361, 458752, 15729, 95027, 917504],
        [163840, 54395, 458752, 18350, 108790, 851968], [196608, 65536, 458752, 23593, 123208, 786432],
    ].map(curve)

    static let scroll: [AccelCurve] = [
        [0, 65536, 393216, 0, 0, 786432], [8192, 62259, 406323, 0, 39322, 786432],
        [32768, 58982, 419430, 0, 58982, 786432], [45056, 55706, 432538, 0, 78643, 786432],
        [57344, 52429, 445645, 0, 91750, 786432], [65536, 49152, 458752, 0, 104858, 786432],
        [98304, 45875, 471859, 0, 117965, 786432], [131072, 42598, 484966, 0, 131072, 786432],
        [163840, 39322, 498074, 0, 144179, 786432], [196608, 36045, 511181, 0, 157286, 786432],
    ].map(curve)

    /// [index, gainLinear, tangentSpeedLinear, gainCubic, gainParabolic, tangentSpeedParabolicRoot]
    private static func curve(_ v: [Int]) -> AccelCurve {
        AccelCurve(ioreg: [
            "HIDAccelIndex": v[0], "HIDAccelGainLinear": v[1], "HIDAccelTangentSpeedLinear": v[2],
            "HIDAccelGainCubic": v[3], "HIDAccelGainParabolic": v[4],
            "HIDAccelTangentSpeedParabolicRoot": v[5],
        ])
    }
}
