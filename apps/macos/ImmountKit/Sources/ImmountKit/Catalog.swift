import Foundation

/// Builds the folder tree Finder shows from Immich data:
///
///     Albums/<album>/<files>
///     Favorites/<files>
///     People/<person>/<files>
///     Tags/<tag>/<nested tags and files>
///     Timeline/<year>/<MM Month>/<files>
public struct Catalog: Sendable {
    public let client: ImmichClient
    /// The Immich user the API key belongs to. Searches also return assets of partners who
    /// share into the user's timeline; Timeline and Favorites keep only the user's own, like
    /// the timeline buckets they are built from.
    public let ownerID: String
    private let buckets = Memo<[ImmichTimeBucket]>()
    private let tags = Memo<TagTree>()

    public init(client: ImmichClient, ownerID: String) {
        self.client = client
        self.ownerID = ownerID
    }

    public static let rootEntry = Entry.folder(.root, name: "Immich")

    public static let rootFolders: [Entry] = [
        .folder(.albums, name: "Albums"),
        .folder(.favorites, name: "Favorites"),
        .folder(.people, name: "People"),
        .folder(.tags, name: "Tags"),
        .folder(.timeline, name: "Timeline"),
    ]

    /// Every child of `container`, sorted and with unique filenames.
    public func children(of container: ItemID) async throws -> [Entry] {
        switch container {
        case .root:
            return Self.rootFolders

        case .albums:
            let albums = try await client.albums().sorted { ($0.albumName.localizedLowercase, $0.id) < ($1.albumName.localizedLowercase, $1.id) }
            return uniquifyFilenames(albums.map(Self.albumEntry))

        case .people:
            let people = try await client.people()
                .filter { !$0.isHidden && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
            return uniquifyFilenames(people.map(Self.personEntry))

        case .tags:
            return uniquifyFilenames(try await tagTree().children(of: .tags))

        case .tag(_, let id):
            let tree = try await tagTree()
            guard tree.identifiers[id] == container else { throw ImmichError.notFound }
            // Immich includes assets tagged with descendants in this search. Child tag
            // folders and files share one filename namespace, just as they do in Finder.
            let assets = try await client.searchAssets(AssetQuery(tagIDs: [id]))
            return entries(for: assets, in: container, alongside: tree.children(of: container))

        case .timeline:
            let years = Set(try await timeBuckets().compactMap(\.yearMonth?.year))
            return years.sorted().map(Self.yearEntry)

        case .year(let year):
            let months = try await timeBuckets()
                .compactMap { bucket in bucket.yearMonth.map { ($0, bucket.count) } }
                .filter { $0.0.year == year }
                .sorted { $0.0 < $1.0 }
            guard !months.isEmpty else { throw ImmichError.notFound }
            return months.map { Self.monthEntry($0.0, count: $0.1) }

        case .month(let month):
            return try await assets(in: container, matching: Self.monthSearch(month)) { asset in
                YearMonth(prefixOf: asset.localDateTime) == month && isOwn(asset)
            }

        case .album(let id):
            return entries(for: try await client.albumAssets(id: id), in: container)

        case .person(let id):
            return try await assets(in: container, matching: AssetQuery(personIDs: [id]))

        case .favorites:
            return try await assets(in: container, matching: AssetQuery(isFavorite: true), where: isOwn)

        case .asset:
            throw ImmichError.notFound
        }
    }

    /// Looks up a single item, fetching only what is needed to name it.
    public func entry(for id: ItemID) async throws -> Entry {
        switch id {
        case .root:
            return Self.rootEntry
        case .albums, .timeline, .favorites, .people, .tags:
            return Self.rootFolders.first { $0.id == id }!
        case .album(let albumID):
            return Self.albumEntry(try await client.album(id: albumID))
        case .person(let personID):
            return Self.personEntry(try await client.person(id: personID))
        case .tag(_, let tagID):
            guard try await tagTree().identifiers[tagID] == id else { throw ImmichError.notFound }
            // A tag name can collide with its sibling tags or its parent's files. Resolve
            // from that same listing so direct item lookups keep the enumerated filename.
            guard let entry = try await children(of: id.parent).first(where: { $0.id == id }) else {
                throw ImmichError.notFound
            }
            return entry
        case .year(let year):
            return Self.yearEntry(year)
        case .month:
            // The enumerated month carries its bucket's asset count, which is part of its
            // metadata version. Build it the same way, or Finder sees the folder change.
            guard let entry = try await children(of: id.parent).first(where: { $0.id == id }) else {
                throw ImmichError.notFound
            }
            return entry
        case .asset:
            // Asset names depend on their siblings (see `uniquifyFilenames`), so list the parent.
            guard let entry = try await children(of: id.parent).first(where: { $0.id == id }) else {
                throw ImmichError.notFound
            }
            return entry
        }
    }

    private func isOwn(_ asset: ImmichAsset) -> Bool {
        asset.ownerId == ownerID
    }

    /// The month buckets, fetched once per catalog: a refresh lists Timeline and every
    /// year folder with the same catalog.
    private func timeBuckets() async throws -> [ImmichTimeBucket] {
        try await buckets.value { [client] in try await client.timeBuckets() }
    }

    /// One complete hierarchy per refresh, shared by every tag folder and item lookup.
    private func tagTree() async throws -> TagTree {
        try await tags.value { [client] in try TagTree(try await client.tags()) }
    }

    private func assets(
        in container: ItemID,
        matching query: AssetQuery,
        where include: (ImmichAsset) -> Bool = { _ in true }
    ) async throws -> [Entry] {
        entries(for: try await client.searchAssets(query).filter(include), in: container)
    }

    private func entries(for assets: [ImmichAsset], in container: ItemID, alongside folders: [Entry] = []) -> [Entry] {
        let assets = assets
            .filter(\.isBrowsable)
            .sorted { ($0.fileCreatedAt, $0.id) < ($1.fileCreatedAt, $1.id) }
        var seen = Set<String>()
        let unique = assets.filter { seen.insert($0.id).inserted }
        return uniquifyFilenames(folders + unique.map { Entry.asset($0, in: container) })
    }

    // MARK: Entry builders

    static func albumEntry(_ album: ImmichAlbum) -> Entry {
        .folder(.album(album.id), name: album.albumName, created: album.createdAt, modified: album.modified, childCount: album.assetCount)
    }

    static func personEntry(_ person: ImmichPerson) -> Entry {
        .folder(.person(person.id), name: person.name, modified: person.updatedAt)
    }

    private struct TagTree: Sendable {
        let identifiers: [String: ItemID]
        private let children: [ItemID: [Entry]]

        init(_ tags: [ImmichTag]) throws {
            var byID: [String: ImmichTag] = [:]
            for tag in tags {
                guard !tag.id.isEmpty, !tag.id.contains("/"),
                      byID[tag.id].map({ $0 == tag }) ?? true else { throw ImmichError.invalidResponse }
                byID[tag.id] = tag
            }

            var identifiers: [String: ItemID] = [:]
            for id in byID.keys.sorted() {
                var ancestry: [String] = []
                var visited = Set<String>()
                var next: String? = id
                var parent: ItemID = .tags
                while let current = next {
                    if let known = identifiers[current] {
                        parent = known
                        break
                    }
                    // A partial or cyclic hierarchy is not an empty folder. Propagate a
                    // failure so refresh keeps its previously valid Finder listings.
                    guard visited.insert(current).inserted, let tag = byID[current] else {
                        throw ImmichError.invalidResponse
                    }
                    ancestry.append(current)
                    next = tag.parentId
                }
                for ancestor in ancestry.reversed() {
                    parent = .tag(parent: parent, id: ancestor)
                    identifiers[ancestor] = parent
                }
            }
            self.identifiers = identifiers

            var children: [ItemID: [Entry]] = [:]
            for tag in byID.values.sorted(by: { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }) {
                guard let id = identifiers[tag.id] else { throw ImmichError.invalidResponse }
                children[id.parent, default: []].append(.folder(id, name: tag.name, created: tag.createdAt, modified: tag.updatedAt))
            }
            self.children = children
        }

        func children(of parent: ItemID) -> [Entry] { children[parent] ?? [] }
    }

    static func yearEntry(_ year: Int) -> Entry {
        let start = YearMonth(year: year, month: 1).start
        return .folder(.year(year), name: String(year), created: start, modified: start)
    }

    static func monthEntry(_ month: YearMonth, count: Int) -> Entry {
        let name = String(format: "%02d ", month.month) + monthNames[month.month - 1]
        return .folder(.month(month), name: name, created: month.start, modified: month.start, childCount: count)
    }

    /// Immich buckets the timeline by local time but searches by UTC, so search a
    /// slightly wider window and filter on `localDateTime` afterwards.
    static func monthSearch(_ month: YearMonth) -> AssetQuery {
        let day: TimeInterval = 24 * 60 * 60
        return AssetQuery(
            takenAfter: month.start.addingTimeInterval(-day),
            takenBefore: month.end.addingTimeInterval(day),
            visibility: "timeline"
        )
    }

    /// Localized month names, capitalized because some languages (e.g. Italian) lowercase them.
    private static let monthNames = (DateFormatter().standaloneMonthSymbols ?? []).map { $0.capitalized(with: .current) }
}
