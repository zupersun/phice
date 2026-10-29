import Foundation
import IOKit
import PhiceCore

/// Apple's pointer and scroll acceleration curves, as the built-in trackpad's driver publishes them.
enum AccelCurveReader {
    /// The curves of the first multitouch device that has them, else this Mac's tables, for Macs
    /// with no built-in trackpad.
    static func read() -> (pointer: [AccelCurve], scroll: [AccelCurve]) {
        var pointer: [AccelCurve] = [], scroll: [AccelCurve] = []
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"),
                                        &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while pointer.isEmpty || scroll.isEmpty {
                let device = IOIteratorNext(iterator)
                guard device != 0 else { break }
                defer { IOObjectRelease(device) }
                if pointer.isEmpty { pointer = curves(from: property(device, "HIDAccelCurves")) }
                if scroll.isEmpty { scroll = curves(from: property(device, "HIDScrollAccelCurves")) }
            }
        }
        return (pointer.isEmpty ? DefaultCurves.pointerCurves : pointer,
                scroll.isEmpty ? DefaultCurves.scrollCurves : scroll)
    }

    /// Entries without a numeric `HIDAccelIndex` are skipped; the rest are sorted by it.
    static func curves(from entries: [[String: Any]]) -> [AccelCurve] {
        entries.compactMap { entry -> AccelCurve? in
            let numbers = entry.compactMapValues { ($0 as? NSNumber)?.intValue }
            return numbers["HIDAccelIndex"] == nil ? nil : AccelCurve(ioreg: numbers)
        }
        .sorted { $0.index < $1.index }
    }

    private static func property(_ device: io_registry_entry_t, _ key: String) -> [[String: Any]] {
        let value = IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? [[String: Any]] ?? []
    }
}
