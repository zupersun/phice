import CoreGraphics
import Foundation

/// Global because neither C callback below can carry context; every access takes the lock, since
/// the event tap calls back on the main thread and MultitouchSupport on its own.
let recorder = Recorder()

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: FileHandle?
    private var counts: [String: Int] = [:]
    private var tap: CFMachPort?

    func start(_ file: FileHandle) { lock.withLock { self.file = file } }

    func summary() -> String {
        lock.withLock {
            counts.isEmpty ? "recorded nothing"
                : "recorded " + counts.sorted { $0.key < $1.key }
                    .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        }
    }

    fileprivate func write(_ kind: String, _ record: [String: Any]) {
        var record = record
        record["kind"] = kind
        guard let line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        lock.withLock {
            file?.write(line + Data("\n".utf8))
            counts[kind, default: 0] += 1
        }
    }

    /// Listen-only, at the HID level, so it sees the trackpad's events before any app changes them.
    func listen() -> Bool {
        let types: [CGEventType] = [.scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: onEvent, userInfo: nil)
        else { return false }
        lock.withLock { self.tap = tap }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func reenable() {
        if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Every finger on every multitouch device, through the private framework the system uses.
    /// Returns what went wrong, if anything.
    func listenToFingers() -> String? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let mt = dlopen(path, RTLD_NOW) else { return "cannot load MultitouchSupport" }
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias Register = @convention(c) (UnsafeRawPointer, FrameCallback) -> Void
        typealias Start = @convention(c) (UnsafeRawPointer, Int32) -> Void
        guard let createList = dlsym(mt, "MTDeviceCreateList"),
              let register = dlsym(mt, "MTRegisterContactFrameCallback"),
              let start = dlsym(mt, "MTDeviceStart"),
              let devices = unsafeBitCast(createList, to: CreateList.self)()?.takeRetainedValue()
        else { return "MultitouchSupport no longer has the functions this expects" }
        guard CFArrayGetCount(devices) > 0 else { return "no multitouch device found" }
        for i in 0 ..< CFArrayGetCount(devices) {
            guard let device = CFArrayGetValueAtIndex(devices, i) else { continue }
            unsafeBitCast(register, to: Register.self)(device, onFrame)
            unsafeBitCast(start, to: Start.self)(device, 0)
        }
        // The devices must outlive the recording; the process ends with it.
        _ = Unmanaged.passRetained(devices)
        return nil
    }
}

// MARK: - The event tap

private let hid = HID()

/// Private IOKit/CoreGraphics calls that reach the HID event behind a CGEvent: its own timestamp
/// and the deltas before acceleration (what WebKit's momentum dispatcher reads).
private struct HID: @unchecked Sendable {
    typealias Copy = @convention(c) (CGEvent) -> UnsafeMutableRawPointer?
    typealias Value = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double
    typealias Stamp = @convention(c) (UnsafeMutableRawPointer) -> UInt64
    let copy: Copy?, float: Value?, stamp: Stamp?
    let tick: Double

    init() {
        let any = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        copy = dlsym(any, "CGEventCopyIOHIDEvent").map { unsafeBitCast($0, to: Copy.self) }
        float = dlsym(any, "IOHIDEventGetFloatValue").map { unsafeBitCast($0, to: Value.self) }
        stamp = dlsym(any, "IOHIDEventGetTimeStamp").map { unsafeBitCast($0, to: Stamp.self) }
        var base = mach_timebase_info()
        mach_timebase_info(&base)
        tick = Double(base.numer) / Double(base.denom) / 1e9
    }

    /// The event's time and its raw x/y for an IOHIDEvent type (6 scroll, 17 pointer).
    func read(_ event: CGEvent, type: UInt32) -> (t: Double, raw: [Double]?) {
        guard let copy, let float, let stamp, let e = copy(event) else {
            return (Double(mach_absolute_time()) * tick, nil)
        }
        defer { Unmanaged<AnyObject>.fromOpaque(e).release() }
        return (Double(stamp(e)) * tick, [float(e, type << 16), float(e, type << 16 | 1)])
    }
}

private func onEvent(_: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                     _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        recorder.reenable()
    case .scrollWheel:
        let (t, raw) = hid.read(event, type: 6)
        func pair(_ x: CGEventField, _ y: CGEventField) -> [Double] {
            [event.getDoubleValueField(x), event.getDoubleValueField(y)]
        }
        var record: [String: Any] = [
            "t": t,
            "px": pair(.scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis1),
            "fixed": pair(.scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis1),
            "lines": pair(.scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis1),
            "phase": event.getIntegerValueField(.scrollWheelEventScrollPhase),
            "momentum": event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            "continuous": event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
        ]
        record["raw"] = raw
        recorder.write("scroll", record)
    default:
        let (t, raw) = hid.read(event, type: 17)
        var record: [String: Any] = [
            "t": t,
            "d": [event.getDoubleValueField(.mouseEventDeltaX),
                  event.getDoubleValueField(.mouseEventDeltaY)],
        ]
        record["raw"] = raw
        recorder.write("move", record)
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Raw fingers

typealias FrameCallback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, Double, Int32)
    -> Int32

/// `MTTouch` is 96 bytes; offsets from the reverse-engineered header everyone uses
/// (OpenMultitouchSupport). If a macOS update changes it, these numbers go wrong, not the build.
private func onFrame(_: UnsafeRawPointer?, _ touches: UnsafeRawPointer?, _ count: Int32,
                     _ t: Double, _ frame: Int32) -> Int32 {
    guard let touches else { return 0 }
    let fingers: [[String: Any]] = (0 ..< Int(max(count, 0))).map { i in
        let p = touches + i * 96
        func f(_ at: Int) -> Double { Double(p.loadUnaligned(fromByteOffset: at, as: Float.self)) }
        return [
            "id": p.loadUnaligned(fromByteOffset: 16, as: Int32.self),
            "state": p.loadUnaligned(fromByteOffset: 20, as: Int32.self),
            "x": f(32), "y": f(36), "vx": f(40), "vy": f(44),
            "size": f(48), "angle": f(56), "major": f(60), "minor": f(64),
            "mm": [f(68), f(72)],
        ]
    }
    recorder.write("touches", ["t": t, "frame": frame, "touches": fingers])
    return 0
}
