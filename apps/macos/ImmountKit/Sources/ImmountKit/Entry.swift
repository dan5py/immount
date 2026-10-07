import Foundation

/// A folder or file as presented to Finder. Entries are what the File Provider
/// extension turns into `NSFileProviderItem`s, and what the listing store persists
/// to detect remote changes.
public struct Entry: Codable, Hashable, Sendable, Identifiable {
    public var id: ItemID
    public var filename: String
    public var size: Int64?
    public var created: Date?
    public var modified: Date?
    public var childCount: Int?
    public var mimeType: String?
    /// Changes when the file bytes change (the asset checksum).
    public var contentVersion: String
    /// Changes when anything Finder displays changes (name, dates, size).
    public var metadataVersion: String

    public var parent: ItemID { id.parent }
    public var isFolder: Bool { id.isFolder }

    public init(
        id: ItemID,
        filename: String,
        size: Int64? = nil,
        created: Date? = nil,
        modified: Date? = nil,
        childCount: Int? = nil,
        mimeType: String? = nil,
        contentVersion: String = "",
        metadataVersion: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.size = size
        self.created = created
        self.modified = modified
        self.childCount = childCount
        self.mimeType = mimeType
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion ?? Self.metadataVersion(filename: filename, modified: modified, childCount: childCount)
    }

    static func metadataVersion(filename: String, modified: Date?, childCount: Int?) -> String {
        [filename, modified.map { String($0.timeIntervalSince1970) } ?? "", childCount.map(String.init) ?? ""]
            .joined(separator: "|")
    }

    static func folder(_ id: ItemID, name: String, created: Date? = nil, modified: Date? = nil, childCount: Int? = nil) -> Entry {
        Entry(id: id, filename: sanitizeFilename(name), created: created, modified: modified, childCount: childCount)
    }

    static func asset(_ asset: ImmichAsset, in parent: ItemID) -> Entry {
        let filename = sanitizeFilename(asset.originalFileName)
        return Entry(
            id: .asset(parent: parent, id: asset.id),
            filename: filename,
            size: asset.exifInfo?.fileSizeInByte,
            created: asset.fileCreatedAt,
            modified: asset.fileModifiedAt,
            mimeType: asset.originalMimeType,
            contentVersion: asset.checksum,
            metadataVersion: [filename, asset.checksum, String(asset.updatedAt.timeIntervalSince1970)].joined(separator: "|")
        )
    }
}

/// Makes a server-provided name safe to use as a single path component.
public func sanitizeFilename(_ name: String) -> String {
    var cleaned = name
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: "\0", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix(".") { cleaned = "_" + cleaned.dropFirst() }
    return cleaned.isEmpty ? "Untitled" : cleaned
}

/// Finder folders are case-insensitive by default and cannot hold two items with the
/// same name. Entries keep their name in order; later duplicates get a short id suffix,
/// e.g. `IMG_0001 (efa7c20c).JPG`. Callers sort entries first so the result is stable.
public func uniquifyFilenames(_ entries: [Entry]) -> [Entry] {
    var used = Set<String>()
    return entries.map { entry in
        var entry = entry
        let key = entry.filename.lowercased()
        if used.contains(key) {
            let suffix = sanitizeFilename(String((entry.id.assetID ?? entry.id.tagID
                ?? entry.id.rawValue.split(separator: ":").last.map(String.init) ?? "").prefix(8)))
            let name = entry.filename as NSString
            let ext = name.pathExtension
            let base = entry.isFolder || ext.isEmpty ? entry.filename : name.deletingPathExtension
            func candidateName(_ counter: Int) -> String {
                let disambiguator = counter == 1 ? suffix : "\(suffix)-\(counter)"
                let extensionSuffix = !entry.isFolder && !ext.isEmpty ? ".\(ext)" : ""
                return "\(base) (\(disambiguator))\(extensionSuffix)"
            }
            var counter = 1
            var candidate = candidateName(counter)
            while used.contains(candidate.lowercased()) {
                counter += 1
                candidate = candidateName(counter)
            }
            entry.filename = candidate
            entry.metadataVersion = candidate + "|" + entry.metadataVersion
        }
        used.insert(entry.filename.lowercased())
        return entry
    }
}
