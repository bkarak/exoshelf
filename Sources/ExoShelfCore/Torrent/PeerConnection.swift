import Foundation
import Network

/// One TCP connection to a peer. Network.framework delivers bytes on a
/// private queue; this class frames them into messages and hands them out as
/// an async stream. All mutable state lives on `queue`.
final class PeerConnection: @unchecked Sendable {
    let address: PeerAddress
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var handshakeDone = false
    private var handshakeContinuation: CheckedContinuation<Handshake, Error>?
    private var streamContinuation: AsyncThrowingStream<PeerMessage, Error>.Continuation?
    private var closed = false

    /// Upper bound on one message; a block is 16 KiB, a bitfield for eXoDOS
    /// about 10 KiB. Anything far larger is a broken or hostile peer.
    private static let maxMessage = 1 << 21

    let messages: AsyncThrowingStream<PeerMessage, Error>

    init(address: PeerAddress) {
        self.address = address
        self.queue = DispatchQueue(label: "exoshelf.peer.\(address)")
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        self.connection = NWConnection(
            host: NWEndpoint.Host(address.host),
            port: NWEndpoint.Port(rawValue: address.port) ?? 6881,
            using: params
        )
        var cont: AsyncThrowingStream<PeerMessage, Error>.Continuation!
        self.messages = AsyncThrowingStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.streamContinuation = cont
    }

    /// Connects, exchanges handshakes and starts reading messages.
    func open(ours: Handshake, timeout: TimeInterval) async throws -> Handshake {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Handshake, Error>) in
            queue.async { [self] in
                handshakeContinuation = c
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.connection.send(content: ours.encoded(), completion: .contentProcessed { _ in })
                        self.receive()
                    case .failed(let error), .waiting(let error):
                        self.fail(error)
                    case .cancelled:
                        self.fail(PeerWireError.closed)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, !self.handshakeDone else { return }
                    self.fail(PeerWireError.timeout)
                }
            }
        }
    }

    func send(_ messages: [PeerMessage]) {
        guard !messages.isEmpty else { return }
        var buffer = Data()
        for m in messages { buffer.append(m.encoded()) }
        let data = buffer
        queue.async { [self] in
            guard !closed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error { self?.fail(error) }
            })
        }
    }

    func send(_ message: PeerMessage) { send([message]) }

    func close() {
        queue.async { [self] in fail(PeerWireError.closed) }
    }

    // MARK: - queue-confined

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if let error {
                self.fail(error)
            } else if isComplete {
                self.fail(PeerWireError.closed)
            } else if !self.closed {
                self.receive()
            }
        }
    }

    private func drain() {
        if !handshakeDone {
            guard buffer.count >= Handshake.length else { return }
            do {
                let hs = try Handshake.decode(buffer.prefix(Handshake.length))
                buffer.removeFirst(Handshake.length)
                handshakeDone = true
                handshakeContinuation?.resume(returning: hs)
                handshakeContinuation = nil
            } catch {
                fail(error)
                return
            }
        }
        var consumed = 0
        let count = buffer.count
        let base = buffer.startIndex
        while count - consumed >= 4 {
            let length = Int(buffer.readUInt32(at: base + consumed))
            guard length <= Self.maxMessage else {
                fail(PeerWireError.messageTooLarge(length))
                return
            }
            guard count - consumed >= 4 + length else { break }
            let start = base + consumed + 4
            if length == 0 {
                streamContinuation?.yield(.keepAlive)
            } else {
                do {
                    let body = buffer.subdata(in: start..<(start + length))
                    streamContinuation?.yield(try PeerMessage.decode(body))
                } catch {
                    fail(error)
                    return
                }
            }
            consumed += 4 + length
        }
        if consumed > 0 { buffer.removeFirst(consumed) }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let c = handshakeContinuation {
            handshakeContinuation = nil
            c.resume(throwing: error)
        }
        if case PeerWireError.closed = error {
            streamContinuation?.finish()
        } else {
            streamContinuation?.finish(throwing: error)
        }
        streamContinuation = nil
    }
}
