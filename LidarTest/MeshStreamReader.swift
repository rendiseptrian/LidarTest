import Foundation
import Network

/// Reads `MeshFrameCodec` frames off one connection, entirely on a background queue.
///
/// Any error, short read, corrupt length or undecodable frame closes the connection. A desynced
/// TCP stream cannot be recovered in place, and the phone resends its whole mesh on reconnect,
/// so closing is always the safe answer. `onClose` fires exactly once.
nonisolated final class MeshStreamReader: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let onReady: @Sendable () -> Void
    private let onPayload: @Sendable (MeshChunkPayload, Int) -> Void
    private let onClose: @Sendable (String?) -> Void

    /// Only touched on `queue`.
    private var closed = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        onReady: @escaping @Sendable () -> Void,
        onPayload: @escaping @Sendable (MeshChunkPayload, Int) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.onReady = onReady
        self.onPayload = onPayload
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady()
                self.readPrefix()
            case .failed(let error), .waiting(let error):
                self.close(error.localizedDescription)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        queue.async { self.close(nil) }
    }

    private func close(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose(reason)
    }

    private func readPrefix() {
        connection.receive(minimumIncompleteLength: MeshFrameCodec.lengthPrefixSize,
                           maximumLength: MeshFrameCodec.lengthPrefixSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error {
                return self.close("Read error: \(error.localizedDescription)")
            }
            guard let data, data.count == MeshFrameCodec.lengthPrefixSize else {
                return self.close(isComplete ? nil : "Short read")
            }
            guard let length = MeshFrameCodec.frameLength(fromPrefix: data) else {
                return self.close("Corrupt frame length")
            }
            self.readFrame(length: length)
        }
    }

    private func readFrame(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error {
                return self.close("Read error: \(error.localizedDescription)")
            }
            guard let data, data.count == length else {
                return self.close(isComplete ? nil : "Short read")
            }
            guard let payload = MeshFrameCodec.decode(frame: data) else {
                return self.close("Corrupt frame")
            }
            self.onPayload(payload, length + MeshFrameCodec.lengthPrefixSize)
            self.readPrefix()
        }
    }
}
