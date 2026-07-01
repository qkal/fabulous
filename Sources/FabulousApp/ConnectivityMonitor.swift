import Foundation
import Network
import Observation

/// Tracks whether the network is reachable, so the Models tab can say
/// "offline" before a download fails instead of after.
@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "fabulous.connectivity"))
    }

    func stop() {
        monitor.cancel()
    }
}
