import Foundation

/// Thread-safe shared endpoint state between M5 and M6.
final class ControllerEndpointHolder: @unchecked Sendable {
    enum Endpoint: Sendable, Equatable {
        case tcp(host: String, port: Int)
        case unix(socketPath: String)
    }

    nonisolated(unsafe) private var endpoint: Endpoint?
    private let lock = NSLock()

    nonisolated var current: Endpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoint
    }

    nonisolated func update(_ endpoint: Endpoint) {
        lock.lock()
        self.endpoint = endpoint
        lock.unlock()
    }

    nonisolated func clear() {
        lock.lock()
        endpoint = nil
        lock.unlock()
    }
}
