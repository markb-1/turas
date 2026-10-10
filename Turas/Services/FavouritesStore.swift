import Foundation

/// A route the user selected or starred, as stored in UserDefaults.
struct SavedRoute: Codable, Hashable, Identifiable, Sendable {
    let mode: TransportMode
    let route: RouteRef
    /// The direction chosen, if any; selecting the entry restores it.
    let direction: Int?
    /// Operator name, shown when two agencies share the route name.
    let agencyName: String?

    /// One entry per route: a later selection of the same route replaces
    /// the earlier one whatever its direction.
    var id: String { "\(mode.rawValue)|\(route.agencyId ?? "")|\(route.name)" }

    /// Whether two entries are the same route. An entry saved without an
    /// agency (from the bundled list or an older server) matches the same
    /// name under any agency, so entries do not split when the route list
    /// gains agency IDs.
    func isSameRoute(as other: SavedRoute) -> Bool {
        guard mode == other.mode, route.name == other.route.name else { return false }
        guard let a = route.agencyId, let b = other.route.agencyId else { return true }
        return a == b
    }
}

/// Recent and starred routes, persisted in UserDefaults.
@MainActor
final class FavouritesStore: ObservableObject {
    static let maxRecents = 20

    /// Most recent first, at most `maxRecents`.
    @Published private(set) var recents: [SavedRoute]
    /// In the order they were starred.
    @Published private(set) var starred: [SavedRoute]

    private let defaults: UserDefaults
    private static let recentsKey = "turas.recentRoutes.v1"
    private static let starredKey = "turas.starredRoutes.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.recents = Self.load(Self.recentsKey, from: defaults)
        self.starred = Self.load(Self.starredKey, from: defaults)
    }

    func recents(for mode: TransportMode) -> [SavedRoute] {
        recents.filter { $0.mode == mode }
    }

    func starred(for mode: TransportMode) -> [SavedRoute] {
        starred.filter { $0.mode == mode }
    }

    /// Records a selection as the most recent, replacing any earlier entry
    /// for the same route.
    func recordSelection(_ entry: SavedRoute) {
        recents.removeAll { $0.isSameRoute(as: entry) }
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents {
            recents.removeLast(recents.count - Self.maxRecents)
        }
        save(recents, key: Self.recentsKey)
    }

    func isStarred(_ entry: SavedRoute) -> Bool {
        starred.contains { $0.isSameRoute(as: entry) }
    }

    /// Stars the route, or unstars it if already starred.
    func toggleStar(_ entry: SavedRoute) {
        if isStarred(entry) {
            starred.removeAll { $0.isSameRoute(as: entry) }
        } else {
            starred.append(entry)
        }
        save(starred, key: Self.starredKey)
    }

    private func save(_ entries: [SavedRoute], key: String) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> [SavedRoute] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([SavedRoute].self, from: data) else {
            return []
        }
        return entries
    }
}
