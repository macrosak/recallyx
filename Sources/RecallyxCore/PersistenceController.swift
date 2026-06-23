import CoreData
import Foundation

/// Wraps an `NSPersistentCloudKitContainer` for the history store. CloudKit
/// mirroring is **OFF** in Phase 1d — we never set `cloudKitContainerOptions`,
/// so the container behaves as a plain local SQLite store (no entitlement /
/// Apple account needed). The seam is here for Phase 2 to flip mirroring on.
///
/// The model is built programmatically (`ClipModel.makeModel()`), so no
/// `.xcdatamodeld` and no Xcode are required — the package stays CLT-buildable.
public final class PersistenceController {
    public let container: NSPersistentCloudKitContainer

    /// `viewContext` runs on the main queue; the store reads through it.
    public var viewContext: NSManagedObjectContext { container.viewContext }

    /// - Parameters:
    ///   - storeURL: SQLite location. Pass the on-disk
    ///     `…/Recallyx/Recallyx.sqlite`; omit for the default of an in-memory
    ///     store (used by callers that supply their own URL anyway).
    ///   - inMemory: when true, the store is created at `/dev/null` so nothing
    ///     touches disk — used by the hermetic test suite.
    public init(storeURL: URL? = nil, inMemory: Bool = false) {
        let model = ClipModel.makeModel()
        container = NSPersistentCloudKitContainer(name: "Recallyx", managedObjectModel: model)

        let description: NSPersistentStoreDescription
        if inMemory {
            description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
        } else if let storeURL {
            description = NSPersistentStoreDescription(url: storeURL)
        } else {
            description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
        }
        // CloudKit mirroring intentionally left disabled (no cloudKitContainerOptions).
        description.cloudKitContainerOptions = nil
        // WAL is the SQLite default; spelled out so a future read-only MCP
        // reader (separate process) can read alongside the app's writes.
        description.setOption(["journal_mode": "WAL"] as NSDictionary, forKey: NSSQLitePragmasOption)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            // A failed store load is unrecoverable for the history backend;
            // surface it loudly rather than limping on a broken context.
            Log.error("Core Data store load failed: \(loadError.localizedDescription)")
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}
