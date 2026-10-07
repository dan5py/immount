import Foundation

/// Identifies every folder and file Immount shows in Finder.
///
/// The same Immich asset can appear in several folders (an album, its month, Favorites),
/// but a File Provider item has exactly one parent, so asset identifiers embed their parent.
public indirect enum ItemID: Hashable, Sendable {
    case root
    case albums
    case timeline
    case favorites
    case people
    case tags
    case album(String)
    case year(Int)
    case month(YearMonth)
    case person(String)
    case tag(parent: ItemID, id: String)
    case asset(parent: ItemID, id: String)

    /// The folder that contains this item. The root is its own parent.
    public var parent: ItemID {
        switch self {
        case .root, .albums, .timeline, .favorites, .people, .tags: .root
        case .album: .albums
        case .year: .timeline
        case .month(let month): .year(month.year)
        case .person: .people
        case .tag(let parent, _): parent
        case .asset(let parent, _): parent
        }
    }

    public var isFolder: Bool {
        if case .asset = self { return false }
        return true
    }

    /// Number of folders between this item and the root.
    public var depth: Int {
        self == .root ? 0 : parent.depth + 1
    }

    public var assetID: String? {
        if case .asset(_, let id) = self { return id }
        return nil
    }

    public var tagID: String? {
        if case .tag(_, let id) = self { return id }
        return nil
    }
}

extension ItemID: RawRepresentable, Codable {
    public var rawValue: String {
        switch self {
        case .root: "root"
        case .albums: "albums"
        case .timeline: "timeline"
        case .favorites: "favorites"
        case .people: "people"
        case .tags: "tags"
        case .album(let id): "album:\(id)"
        case .year(let year): "year:\(year)"
        case .month(let month): String(format: "month:%04d-%02d", month.year, month.month)
        case .person(let id): "person:\(id)"
        case .tag(let parent, let id): "tag:\(parent.rawValue)/\(id)"
        case .asset(let parent, let id): "asset:\(parent.rawValue)/\(id)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "root": self = .root
        case "albums": self = .albums
        case "timeline": self = .timeline
        case "favorites": self = .favorites
        case "people": self = .people
        case "tags": self = .tags
        default:
            guard let colon = rawValue.firstIndex(of: ":") else { return nil }
            let kind = rawValue[..<colon]
            let value = String(rawValue[rawValue.index(after: colon)...])
            guard !value.isEmpty else { return nil }
            switch kind {
            case "album": self = .album(value)
            case "person": self = .person(value)
            case "tag":
                guard let slash = value.lastIndex(of: "/"),
                      let parent = ItemID(rawValue: String(value[..<slash])) else { return nil }
                switch parent {
                case .tags, .tag: break
                default: return nil
                }
                let id = String(value[value.index(after: slash)...])
                guard !id.isEmpty else { return nil }
                self = .tag(parent: parent, id: id)
            case "year":
                guard let year = Int(value) else { return nil }
                self = .year(year)
            case "month":
                guard value.count == 7, let month = YearMonth(prefixOf: value) else { return nil }
                self = .month(month)
            case "asset":
                guard let slash = value.lastIndex(of: "/"),
                      let parent = ItemID(rawValue: String(value[..<slash])),
                      parent.isFolder else { return nil }
                let id = String(value[value.index(after: slash)...])
                guard !id.isEmpty else { return nil }
                self = .asset(parent: parent, id: id)
            default:
                return nil
            }
        }
    }
}
