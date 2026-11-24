import Foundation
import Observation

/// A row of the bookmarks provider (BrowserContract.Bookmarks): a bookmark or a folder.
struct Bookmark: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var url: String
    var isFolder: Bool = false
    /// nil = the root "Bookmarks" folder.
    var parent: UUID?
    var created: Date = Date()
}

/// BrowserBookmarksPage's data + Bookmarks.addBookmark/removeFromBookmarks.
@MainActor
@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var items: [Bookmark] = []

    private init() {
        if let saved = BrowserFiles.load([Bookmark].self, "bookmarks.json") {
            items = saved
        } else {
            // res/values/strings.xml "bookmarks", minus the dead ones.
            let defaults: [(String, String)] = [
                ("Google", "https://www.google.com/"), ("Wikipedia", "https://www.wikipedia.org/"),
                ("Fossify", "https://www.fossify.org/"), ("BBC", "https://www.bbc.co.uk/"),
                ("NY Times", "https://www.nytimes.com/"), ("Weather Channel", "https://weather.com/"),
            ]
            items = defaults.map { Bookmark(title: $0.0, url: $0.1) }
            save()
        }
    }

    private func save() { BrowserFiles.save(items, "bookmarks.json") }

    func children(of folder: UUID?) -> [Bookmark] {
        items.filter { $0.parent == folder }.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.created > $1.created
        }
    }

    func folders(excluding: UUID? = nil) -> [Bookmark] {
        let excluded = excluding.map { Set(descendants(of: $0).map(\.id) + [$0]) } ?? []
        return items.filter { $0.isFolder && !excluded.contains($0.id) }.sorted { path(of: $0.id) < path(of: $1.id) }
    }

    func item(_ id: UUID?) -> Bookmark? { id.flatMap { id in items.first { $0.id == id } } }

    /// "Bookmarks > Work > ..." (BreadCrumbView).
    func path(of folder: UUID?) -> String {
        var names: [String] = []
        var current = item(folder)
        while let f = current {
            names.insert(f.title, at: 0)
            current = item(f.parent)
        }
        return (["Bookmarks"] + names).joined(separator: " › ")
    }

    func crumbs(_ folder: UUID?) -> [Bookmark] {
        var list: [Bookmark] = []
        var current = item(folder)
        while let f = current {
            list.insert(f, at: 0)
            current = item(f.parent)
        }
        return list
    }

    func isBookmarked(_ url: String) -> Bool { items.contains { !$0.isFolder && $0.url == url } }

    func upsert(_ b: Bookmark) {
        if let i = items.firstIndex(where: { $0.id == b.id }) { items[i] = b } else { items.append(b) }
        save()
    }

    func add(title: String, url: String, parent: UUID?) {
        upsert(Bookmark(title: title.isEmpty ? url : title, url: url, parent: parent))
    }

    @discardableResult
    func addFolder(_ name: String, parent: UUID?) -> UUID {
        let f = Bookmark(title: name, url: "", isFolder: true, parent: parent)
        upsert(f)
        return f.id
    }

    func descendants(of folder: UUID) -> [Bookmark] {
        var result: [Bookmark] = []
        var queue = [folder]
        while let id = queue.popLast() {
            for child in items where child.parent == id {
                result.append(child)
                if child.isFolder { queue.append(child.id) }
            }
        }
        return result
    }

    func delete(_ id: UUID) {
        let ids = Set(descendants(of: id).map(\.id) + [id])
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func removeURL(_ url: String) {
        items.removeAll { !$0.isFolder && $0.url == url }
        save()
    }

    func matching(_ query: String, limit: Int = 3) -> [Bookmark] {
        let q = query.lowercased()
        return items.filter { !$0.isFolder && ($0.title.lowercased().contains(q) || UrlUtils.strip($0.url).lowercased().hasPrefix(q)) }
            .prefix(limit).map { $0 }
    }
}
