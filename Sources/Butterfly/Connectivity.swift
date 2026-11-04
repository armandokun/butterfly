import Foundation
import Network

/// Online / offline, for explaining failed commands ("No internet"). Never shows anything on its own.
@MainActor
final class Connectivity {
    static let shared = Connectivity()
    private(set) var online = true
    private let monitor = NWPathMonitor()

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.online = up }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    /// The command failed because there's no connection (offline, or the request itself couldn't reach the network).
    func explains(_ error: Error) -> Bool {
        if !online { return true }
        let codes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                         .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed]
        return (error as? URLError).map { codes.contains($0.code) } ?? false
    }
}
