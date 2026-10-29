import Foundation
import Network
import PhiceCore

struct LinkTiming {
    var heartbeat = Duration.milliseconds(100)
    /// Without inbound data for this long, the Mac drops the phone.
    var deadAfter = Duration.seconds(2)
    var unreachableAfter = Duration.seconds(5)
    /// A connection not ready by then is given up on. A cold Bonjour connection, racing every
    /// path at once, took 3.5 s to become ready (measured).
    var handshake = Duration.seconds(10)
    var firstRetry = Duration.milliseconds(100)
    var maxRetry = Duration.seconds(2)
}

/// Frames of `Inbound` over one ready connection. A frame that does not decode, or is oversized,
/// closes it, as does the peer closing. Closing cancels the connection, so its owner's state
/// handler is the one place that cleans up.
@MainActor final class FrameChannel<Inbound: Decodable> {
    let connection: NWConnection
    private var decoder = FrameDecoder<Inbound>()
    private var lastInbound = ContinuousClock.now
    private var open = true
    private var watchdog: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private let deliver: @MainActor (Inbound) -> Void

    init(_ connection: NWConnection, deadAfter: Duration?,
         deliver: @escaping @MainActor (Inbound) -> Void) {
        self.connection = connection
        self.deliver = deliver
        expire(after: deadAfter)
        receive()
    }

    /// Close after `limit` without inbound data, counting from now; nil waits forever.
    func expire(after limit: Duration?) {
        watchdog?.cancel()
        lastInbound = .now
        guard let limit else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: limit / 4)
                guard let self, self.open, !Task.isCancelled else { return }
                if ContinuousClock.now - self.lastInbound > limit { self.close() }
            }
        }
    }

    func send(_ value: some Encodable) {
        guard open, let frame = try? FrameCodec.encode(value) else { return }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { MainActor.assumeIsolated { self?.close() } }
        })
    }

    /// Sends `message` every `interval` until closed, so the peer can tell quiet from gone.
    func beat<Message: Encodable & Sendable>(_ message: Message, every interval: Duration) {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.open, !Task.isCancelled else { return }
                self.send(message)
            }
        }
    }

    /// Sends `value`, then closes once it is on its way; cancelling first could drop it.
    func finish(with value: some Encodable) {
        guard open, let frame = try? FrameCodec.encode(value) else { return close() }
        heartbeat?.cancel()
        connection.send(content: frame, completion: .contentProcessed { _ in
            MainActor.assumeIsolated { self.close() }
        })
    }

    func close() {
        guard open else { return }
        open = false
        watchdog?.cancel()
        heartbeat?.cancel()
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, done, err in
            MainActor.assumeIsolated {
                guard let self, self.open else { return }
                if let data, !data.isEmpty {
                    self.lastInbound = .now
                    guard let messages = try? self.decoder.push(data) else { return self.close() }
                    for message in messages where self.open { self.deliver(message) }
                }
                if done || err != nil { self.close() } else if self.open { self.receive() }
            }
        }
    }
}

extension NWConnection {
    /// A handshake that never finishes would hold the socket, and on the phone block reconnecting.
    @MainActor func cancel(unlessReadyWithin limit: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            if let self, self.state != .ready { self.cancel() }
        }
    }
}
