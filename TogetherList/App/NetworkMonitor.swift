import Foundation
import Network

/// Publishes connectivity changes as an async stream.
final class NetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "TogetherList.NetworkMonitor")

    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { path in
            continuation.yield(path.status == .satisfied)
        }
        continuation.onTermination = { [monitor] _ in monitor.cancel() }
        monitor.start(queue: queue)
        return stream
    }
}
