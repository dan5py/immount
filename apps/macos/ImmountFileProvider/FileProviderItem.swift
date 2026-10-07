import CryptoKit
import FileProvider
import ImmountKit
import UniformTypeIdentifiers

extension NSFileProviderItemIdentifier {
    init(_ id: ItemID) {
        self = id == .root ? .rootContainer : NSFileProviderItemIdentifier(id.rawValue)
    }
}

extension ItemID {
    init?(_ identifier: NSFileProviderItemIdentifier) {
        if identifier == .rootContainer {
            self = .root
        } else {
            self.init(rawValue: identifier.rawValue)
        }
    }
}

final class FileProviderItem: NSObject, NSFileProviderItem {
    /// Increment when provider-side metadata changes independently of Immich's entries.
    static let metadataRevision = 1

    let entry: Entry

    init(_ entry: Entry) {
        self.entry = entry
    }

    var itemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(entry.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { NSFileProviderItemIdentifier(entry.parent) }
    var filename: String { entry.filename }

    var contentType: UTType {
        if entry.isFolder { return .folder }
        let ext = (entry.filename as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? entry.mimeType.flatMap { UTType(mimeType: $0) } ?? .data
    }

    // Read-only for now: Finder disables rename, move, delete and drop.
    var capabilities: NSFileProviderItemCapabilities {
        entry.isFolder ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
    }

    /// Explicitly use the modern policy API. Omitting it while supplying read-only
    /// capabilities makes macOS treat existing downloads as non-evictable.
    var contentPolicy: NSFileProviderContentPolicy {
        entry.id == .root ? .downloadLazily : .inherited
    }

    var fileSystemFlags: NSFileProviderFileSystemFlags {
        entry.isFolder ? [.userReadable, .userExecutable] : [.userReadable]
    }

    var documentSize: NSNumber? { entry.size.map { NSNumber(value: $0) } }
    var childItemCount: NSNumber? { entry.childCount.map { NSNumber(value: $0) } }
    var creationDate: Date? { entry.created }
    var contentModificationDate: Date? { entry.modified }

    /// Version components are limited to 128 bytes, and the metadata version includes the
    /// filename, so both are hashed to a fixed 32 bytes.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Self.digest(entry.contentVersion),
            metadataVersion: Self.digest("\(Self.metadataRevision):\(entry.metadataVersion)")
        )
    }

    private static func digest(_ string: String) -> Data {
        Data(SHA256.hash(data: Data(string.utf8)))
    }
}
