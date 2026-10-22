import Foundation
import Network

/// Online / offline. Tells the notch once when the connection drops (after a short grace period, so Wi-Fi blips stay silent).
@MainActor
final class Connectivity {
    static let shared = Connectivity()
    private(set) var online = true
    var onOffline: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var pending: Task<Void, Never>?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.update(up) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    private func update(_ up: Bool) {
        pending?.cancel()
        if up { online = true; return }
        pending = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let wasOnline = self.online
            self.online = false
            if wasOnline { self.onOffline?() }
        }
    }
}
