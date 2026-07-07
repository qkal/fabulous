import FabCore
import Foundation
import Observation

/// UI state for the Models settings tab. Owned and mutated by AppController;
/// the view only reads it and calls actions. Status transitions are delegated
/// to `FabCore.ModelRowState` so they are unit-tested.
@MainActor
@Observable
final class ModelListModel {
    typealias Status = ModelRowStatus

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

    /// Drives one row's status through the pure reducer.
    func apply(_ event: ModelRowEvent, to modelID: String) {
        guard let index = items.firstIndex(where: { $0.id == modelID }) else { return }
        items[index].status = ModelRowState.reduce(items[index].status, event)
    }

    func updateSize(_ modelID: String, sizeOnDiskMB: Int?) {
        guard let index = items.firstIndex(where: { $0.id == modelID }) else { return }
        items[index].sizeOnDiskMB = sizeOnDiskMB
    }
}
