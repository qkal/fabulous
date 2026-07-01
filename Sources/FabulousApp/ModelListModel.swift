import FabCore
import Foundation
import Observation

/// UI state for the Models settings tab. Owned and mutated by AppController;
/// the view only reads it and calls actions.
@MainActor
@Observable
final class ModelListModel {
    enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case active
        case failed(String)
    }

    struct Item: Identifiable {
        let descriptor: ModelDescriptor
        var status: Status
        /// Actual size on disk once installed; nil otherwise.
        var sizeOnDiskMB: Int?

        var id: String { descriptor.id }
    }

    var items: [Item] = ModelCatalog.all.map {
        Item(descriptor: $0, status: .notInstalled, sizeOnDiskMB: nil)
    }

    func update(_ modelID: String, to status: Status, sizeOnDiskMB: Int?? = nil) {
        guard let index = items.firstIndex(where: { $0.id == modelID }) else { return }
        items[index].status = status
        if let sizeOnDiskMB {
            items[index].sizeOnDiskMB = sizeOnDiskMB
        }
    }
}
