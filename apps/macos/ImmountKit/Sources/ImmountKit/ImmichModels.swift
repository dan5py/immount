import Foundation

/// The subset of Immich API responses Immount needs. Unknown fields are ignored,
/// so newer servers keep decoding as long as these fields stay.

public struct ImmichUser: Codable, Sendable, Equatable {
    public var id: String
}

public struct ImmichAPIKey: Codable, Sendable, Equatable {
    public var name: String
    public var permissions: [String]

    /// Permissions Immount needs for everything it shows in Finder. `all` grants every one.
    public static let requiredPermissions = [
        "asset.read",       // timeline buckets and search
        "asset.view",       // thumbnails
        "asset.download",   // originals
        "album.read",
        "person.read",
        "tag.read",
        "user.read",        // identifies the account behind the key
    ]

    public var missingPermissions: [String] {
        permissions.contains("all") ? [] : Self.requiredPermissions.filter { !permissions.contains($0) }
    }
}

public struct ImmichServerVersion: Codable, Sendable, Equatable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Release candidate number, added in Immich 3.0.
    public var prerelease: Int?

    public init(major: Int, minor: Int, patch: Int, prerelease: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-rc.\($0)" } ?? "")
    }

    public func isAtLeast(major: Int, minor: Int) -> Bool {
        (self.major, self.minor) >= (major, minor)
    }
}

public struct ImmichAlbum: Codable, Sendable, Equatable {
    public var id: String
    public var albumName: String
    public var assetCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// When an asset was last added or changed. `updatedAt` does not move when assets are added.
    public var lastModifiedAssetTimestamp: Date?

    public var modified: Date {
        max(updatedAt, lastModifiedAssetTimestamp ?? updatedAt)
    }
}

public struct ImmichPerson: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isHidden: Bool
    public var updatedAt: Date?
}

public struct ImmichPeoplePage: Codable, Sendable {
    public var people: [ImmichPerson]
    public var hasNextPage: Bool?
}

public struct ImmichTag: Codable, Sendable, Equatable {
    public var id: String
    /// The leaf name, without its ancestors.
    public var name: String
    /// Immich's full tag path, with ancestors separated by `/`.
    public var value: String
    public var parentId: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, name: String, value: String, parentId: String? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.value = value
        self.parentId = parentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ImmichTimeBucket: Codable, Sendable, Equatable {
    /// First day of the month, e.g. `2024-10-01`.
    public var timeBucket: String
    public var count: Int

    /// Year and month parsed from `timeBucket`.
    public var yearMonth: YearMonth? { YearMonth(prefixOf: timeBucket) }
}

public struct ImmichAsset: Codable, Sendable, Equatable {
    public struct ExifInfo: Codable, Sendable, Equatable {
        public var fileSizeInByte: Int64?
    }

    public var id: String
    public var ownerId: String
    public var type: String
    public var originalFileName: String
    public var originalMimeType: String?
    public var fileCreatedAt: Date
    public var fileModifiedAt: Date
    /// Wall-clock time where the photo was taken, encoded as if it were UTC.
    /// Immich's timeline groups assets by this value.
    public var localDateTime: String
    public var updatedAt: Date
    public var checksum: String
    public var visibility: String?
    public var isOffline: Bool?
    public var exifInfo: ExifInfo?

    /// Live photo video parts and locked-folder assets are not meant to be browsed,
    /// and offline external-library files cannot be downloaded.
    public var isBrowsable: Bool {
        visibility != "hidden" && visibility != "locked" && isOffline != true
    }
}

struct ImmichSearchResponse: Decodable, Sendable {
    struct Assets: Decodable, Sendable {
        var items: [ImmichAsset]
        /// Pagination before Immich 3.2.
        var nextPage: String?
        /// Pagination from Immich 3.2.
        var nextCursor: String?
        /// Immich 3.2 always sends `nextCursor`, null on the last page. Without it, the server
        /// is older and ignored the 3.2 filter.
        var hasCursorField: Bool

        enum CodingKeys: String, CodingKey { case items, nextPage, nextCursor }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = try container.decode([ImmichAsset].self, forKey: .items)
            nextPage = try container.decodeIfPresent(String.self, forKey: .nextPage)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            hasCursorField = container.contains(.nextCursor)
        }
    }

    var assets: Assets
}

/// What to list from `POST /api/search/metadata`, independent of the request shape
/// the server understands.
public struct AssetQuery: Sendable, Equatable {
    public var albumIDs: [String]?
    public var personIDs: [String]?
    /// Require every specified tag. A tag also matches assets tagged with its descendants.
    public var tagIDs: [String]?
    public var isFavorite: Bool?
    public var takenAfter: Date?
    public var takenBefore: Date?
    /// A single visibility such as `timeline`. Nil means timeline and archived assets.
    public var visibility: String?

    public init(
        albumIDs: [String]? = nil,
        personIDs: [String]? = nil,
        tagIDs: [String]? = nil,
        isFavorite: Bool? = nil,
        takenAfter: Date? = nil,
        takenBefore: Date? = nil,
        visibility: String? = nil
    ) {
        self.albumIDs = albumIDs
        self.personIDs = personIDs
        self.tagIDs = tagIDs
        self.isFavorite = isFavorite
        self.takenAfter = takenAfter
        self.takenBefore = takenBefore
        self.visibility = visibility
    }
}

/// Request body for Immich 3.2 and later: a `filter` object paginated with `cursor`.
/// The flat fields of `LegacySearchBody` are deprecated and slated for removal in v4.
struct FilterSearchBody: Encodable {
    var query: AssetQuery
    var cursor: String?
    var size = 1000

    private enum Keys: String, CodingKey { case filter, cursor, size, withExif }
    private enum FilterKeys: String, CodingKey { case albumIds, personIds, tagIds, isFavorite, takenAt, visibility, trashedAt, isOffline }
    private struct AnyOf: Encodable { var any: [String] }
    private struct AllOf: Encodable { var all: [String] }
    private struct Equals<Value: Encodable>: Encodable { var eq: Value }
    private struct OneOf: Encodable { var `in`: [String] }
    private struct DateRange: Encodable { var gte: Date?; var lt: Date? }
    private struct IsNull: Encodable {
        enum CodingKeys: CodingKey { case eq }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeNil(forKey: .eq)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(size, forKey: .size)
        try container.encode(true, forKey: .withExif)
        try container.encodeIfPresent(cursor, forKey: .cursor)

        var filter = container.nestedContainer(keyedBy: FilterKeys.self, forKey: .filter)
        try filter.encodeIfPresent(query.albumIDs.map(AnyOf.init), forKey: .albumIds)
        try filter.encodeIfPresent(query.personIDs.map(AnyOf.init), forKey: .personIds)
        // Legacy tagIds is an intersection; `all` preserves that behavior on Immich 3.2.
        try filter.encodeIfPresent(query.tagIDs.map(AllOf.init), forKey: .tagIds)
        try filter.encodeIfPresent(query.isFavorite.map(Equals.init), forKey: .isFavorite)
        if query.takenAfter != nil || query.takenBefore != nil {
            try filter.encode(DateRange(gte: query.takenAfter, lt: query.takenBefore), forKey: .takenAt)
        }
        if let visibility = query.visibility {
            try filter.encode(Equals(eq: visibility), forKey: .visibility)
        } else {
            try filter.encode(OneOf(in: ["timeline", "archive"]), forKey: .visibility)
        }
        // The 3.2 filter does not exclude trashed assets unless asked to.
        try filter.encode(IsNull(), forKey: .trashedAt)
        try filter.encode(Equals(eq: false), forKey: .isOffline)
    }
}

/// Request body for Immich before 3.2, paginated with `page`. Those servers drop unknown
/// keys, so sending them `FilterSearchBody` would silently return the whole library.
struct LegacySearchBody: Encodable {
    var albumIds: [String]?
    var personIds: [String]?
    var tagIds: [String]?
    var isFavorite: Bool?
    var takenAfter: Date?
    var takenBefore: Date?
    var visibility: String?
    var withExif = true
    var page = 1
    var size = 1000

    init(_ query: AssetQuery, page: Int) {
        albumIds = query.albumIDs
        personIds = query.personIDs
        tagIds = query.tagIDs
        isFavorite = query.isFavorite
        takenAfter = query.takenAfter
        takenBefore = query.takenBefore
        visibility = query.visibility
        self.page = page
    }
}

public struct YearMonth: Hashable, Sendable, Comparable {
    public var year: Int
    public var month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// Parses the leading `yyyy-MM` of strings like `2024-10-01` or `2024-10-28T11:02:50.000Z`.
    public init?(prefixOf string: String) {
        let parts = string.prefix(7).split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else {
            return nil
        }
        self.init(year: year, month: month)
    }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    /// Midnight UTC on the first day of the month.
    public var start: Date {
        DateComponents(calendar: .utc, year: year, month: month, day: 1).date!
    }

    /// Midnight UTC on the first day of the following month.
    public var end: Date {
        Calendar.utc.date(byAdding: .month, value: 1, to: start)!
    }
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
