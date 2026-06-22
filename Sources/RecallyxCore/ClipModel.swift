import CoreData
import Foundation

/// The Core Data model for Recallyx history, **defined programmatically** (no
/// `.xcdatamodeld`) so the package stays buildable with Command Line Tools only
/// — no Xcode. One entity, `ClipEntity`, mirroring `HistoryItem`.
///
/// Modeled for CloudKit from day one (mirroring is OFF in Phase 1d, but
/// `NSPersistentCloudKitContainer`'s constraints are painful to retrofit):
/// **every attribute is optional or has a default**, and there are **no unique
/// constraints** (dedupe stays at the app layer via `ContentHash`). `kind` is a
/// String (the `ClipKind` raw value); timestamps are `Date`.
public enum ClipModel {
    public static let entityName = "ClipEntity"

    /// Builds a fresh `NSManagedObjectModel`. Each call returns a new instance;
    /// the persistence controller caches one per store so multiple containers
    /// in one process don't fight over the entity description.
    public static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let entity = NSEntityDescription()
        entity.name = entityName
        entity.managedObjectClassName = NSStringFromClass(ClipEntity.self)

        var properties: [NSPropertyDescription] = []

        // UUID — optional (CloudKit), but always set by us; no unique constraint.
        properties.append(attribute("id", .UUIDAttributeType, optional: true))
        // ClipKind raw value ("text" / "image"); default to "text".
        properties.append(attribute("kind", .stringAttributeType, optional: true, defaultValue: ClipKind.text.rawValue))
        properties.append(attribute("text", .stringAttributeType, optional: true))
        properties.append(attribute("imageFilename", .stringAttributeType, optional: true))
        properties.append(attribute("preview", .stringAttributeType, optional: true, defaultValue: ""))
        properties.append(attribute("byteSize", .integer64AttributeType, optional: true, defaultValue: 0))
        properties.append(attribute("sourceAppBundleID", .stringAttributeType, optional: true))
        properties.append(attribute("sourceAppName", .stringAttributeType, optional: true))
        properties.append(attribute("sourceAppPath", .stringAttributeType, optional: true))
        properties.append(attribute("createdAt", .dateAttributeType, optional: true))
        properties.append(attribute("lastUsedAt", .dateAttributeType, optional: true))
        properties.append(attribute("contentHash", .stringAttributeType, optional: true))
        properties.append(attribute("imageDimensions", .stringAttributeType, optional: true))
        properties.append(attribute("pinned", .booleanAttributeType, optional: true, defaultValue: false))
        // Denormalized recency = max(createdAt, lastUsedAt), maintained on
        // add/bump so a fetch can sort cheaply by a single descriptor.
        properties.append(attribute("recency", .dateAttributeType, optional: true))
        // Image dimension components, stored separately to mirror the iPhone
        // foundation's split fields (imageDimensions is the human string).
        properties.append(attribute("imageWidth", .integer64AttributeType, optional: true))
        properties.append(attribute("imageHeight", .integer64AttributeType, optional: true))

        entity.properties = properties
        model.entities = [entity]
        return model
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attr = NSAttributeDescription()
        attr.name = name
        attr.attributeType = type
        attr.isOptional = optional
        if let defaultValue { attr.defaultValue = defaultValue }
        return attr
    }
}

/// `NSManagedObject` subclass for `ClipEntity`. Attributes are declared
/// `@NSManaged` so Core Data backs them; the model above wires the schema.
public final class ClipEntity: NSManagedObject {
    @NSManaged public var id: UUID?
    @NSManaged public var kind: String?
    @NSManaged public var text: String?
    @NSManaged public var imageFilename: String?
    @NSManaged public var preview: String?
    @NSManaged public var byteSize: Int64
    @NSManaged public var sourceAppBundleID: String?
    @NSManaged public var sourceAppName: String?
    @NSManaged public var sourceAppPath: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var lastUsedAt: Date?
    @NSManaged public var contentHash: String?
    @NSManaged public var imageDimensions: String?
    @NSManaged public var pinned: Bool
    @NSManaged public var recency: Date?
    @NSManaged public var imageWidth: Int64
    @NSManaged public var imageHeight: Int64
}

extension ClipEntity {
    static func clipFetchRequest() -> NSFetchRequest<ClipEntity> {
        NSFetchRequest<ClipEntity>(entityName: ClipModel.entityName)
    }

    /// Copy a value-type `HistoryItem` into this managed object.
    func apply(_ item: HistoryItem) {
        id = item.id
        kind = item.kind.rawValue
        text = item.text
        imageFilename = item.imageFilename
        preview = item.preview
        byteSize = Int64(item.byteSize)
        sourceAppBundleID = item.sourceAppBundleID
        sourceAppName = item.sourceAppName
        sourceAppPath = item.sourceAppPath
        createdAt = item.createdAt
        lastUsedAt = item.lastUsedAt
        contentHash = item.contentHash
        imageDimensions = item.imageDimensions
        pinned = item.isPinned
        recency = item.recency
        let (w, h) = ClipEntity.parseDimensions(item.imageDimensions)
        imageWidth = Int64(w ?? 0)
        imageHeight = Int64(h ?? 0)
    }

    /// Map this managed object back to a value-type `HistoryItem` so the VM and
    /// views keep using value types. Returns nil when a required field is absent
    /// (a malformed row is skipped rather than crashing).
    func toItem() -> HistoryItem? {
        guard let id, let createdAt, let lastUsedAt, let contentHash else { return nil }
        let kindValue = ClipKind(rawValue: kind ?? "") ?? .text
        return HistoryItem(
            id: id,
            kind: kindValue,
            text: text,
            imageFilename: imageFilename,
            preview: preview ?? "",
            byteSize: Int(byteSize),
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            sourceAppPath: sourceAppPath,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            contentHash: contentHash,
            imageDimensions: imageDimensions,
            pinned: pinned
        )
    }

    /// Parse "1920 × 1080" into components for the split width/height fields.
    static func parseDimensions(_ s: String?) -> (Int?, Int?) {
        guard let s else { return (nil, nil) }
        let parts = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count == 2 else { return (nil, nil) }
        return (parts[0], parts[1])
    }
}
