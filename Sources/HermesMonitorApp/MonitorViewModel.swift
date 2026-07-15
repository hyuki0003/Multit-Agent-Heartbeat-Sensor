import Combine
import Foundation
import HermesMonitorCore

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: HermesMonitorSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let client: HermesMonitorClient?

    init(client: HermesMonitorClient?, initialError: String? = nil) {
        self.client = client
        self.errorMessage = initialError
    }

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            snapshot = try await client.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
