import AppKit
import Foundation
@testable import Phice

func tempDirectory() -> URL {
    let name = "phice-tests-\(UUID().uuidString)"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// One pasteboard item holding plain text, the way most apps write it.
func text(_ string: String) -> [[String: Data]] {
    [["public.utf8-plain-text": Data(string.utf8)]]
}

let concealedType = "org.nspasteboard.ConcealedType"
let transientType = "org.nspasteboard.TransientType"

/// A PNG of the given size, made without touching the screen.
func png(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

/// Every file under `url`, concatenated: lets a test prove a secret reached no file.
func everythingWritten(under url: URL) -> Data {
    var all = Data()
    guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
        return all
    }
    for case let file as URL in files {
        if let data = try? Data(contentsOf: file) { all.append(data) }
    }
    return all
}
