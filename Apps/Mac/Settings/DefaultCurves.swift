import PhiceCore

/// This Mac's `HIDAccelCurves` and `HIDScrollAccelCurves` as ioreg listed them (16.16 fixed point),
/// for Macs with no built-in trackpad to read them from. Columns: index, gain linear, parabolic,
/// cubic, quartic, tangent speed linear, tangent speed parabolic root.
enum DefaultCurves {
    static let pointer: [[Int]] = [
        [0, 65536, 0, 0, 0, 484966, 1376256],
        [8192, 64881, 32768, 5243, 0, 478413, 1310720],
        [32768, 64225, 43254, 6554, 0, 471859, 1245184],
        [45056, 62915, 54395, 7864, 0, 465306, 1179648],
        [57344, 61604, 65536, 9830, 0, 458752, 1114112],
        [65536, 60293, 75366, 11796, 0, 458752, 1048576],
        [98304, 58327, 85197, 13763, 0, 458752, 983040],
        [131072, 56361, 95027, 15729, 0, 458752, 917504],
        [163840, 54395, 108790, 18350, 0, 458752, 851968],
        [196608, 65536, 123208, 23593, 0, 458752, 786432],
    ]

    static let scroll: [[Int]] = [
        [0, 65536, 0, 0, 0, 393216, 786432],
        [8192, 62259, 39322, 0, 0, 406323, 786432],
        [32768, 58982, 58982, 0, 0, 419430, 786432],
        [45056, 55706, 78643, 0, 0, 432538, 786432],
        [57344, 52429, 91750, 0, 0, 445645, 786432],
        [65536, 49152, 104858, 0, 0, 458752, 786432],
        [98304, 45875, 117965, 0, 0, 471859, 786432],
        [131072, 42598, 131072, 0, 0, 484966, 786432],
        [163840, 39322, 144179, 0, 0, 498074, 786432],
        [196608, 36045, 157286, 0, 0, 511181, 786432],
    ]

    static var pointerCurves: [AccelCurve] { pointer.map(curve) }
    static var scrollCurves: [AccelCurve] { scroll.map(curve) }

    private static let keys = [
        "HIDAccelIndex", "HIDAccelGainLinear", "HIDAccelGainParabolic", "HIDAccelGainCubic",
        "HIDAccelGainQuartic", "HIDAccelTangentSpeedLinear", "HIDAccelTangentSpeedParabolicRoot",
    ]

    private static func curve(_ row: [Int]) -> AccelCurve {
        AccelCurve(ioreg: Dictionary(uniqueKeysWithValues: zip(keys, row)))
    }
}
