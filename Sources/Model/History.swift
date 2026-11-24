import Foundation
import Observation

/// A row of the history provider (BrowserContract.History).
struct HistoryItem: Codable, Identifiable, Hashable {
    var url: String
    var title: String
    var date: Date
    var visits: Int
    var id: String { url }
}

/// History + Controller.updateVisitedHistory, with DateSorter's groups.
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var items: [HistoryItem] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        items = BrowserFiles.load([HistoryItem].self, "history.json") ?? []
    }

    private func save() {
        saveTask?.cancel()
        saveTask = Task { [items] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            BrowserFiles.save(items, "history.json")
        }
    }

    func visit(_ url: URL, title: String?) {
        guard let scheme = url.scheme, ["http", "https", "file"].contains(scheme) else { return }
        let key = url.absoluteString
        if let i = items.firstIndex(where: { $0.url == key }) {
            var item = items.remove(at: i)
            item.visits += 1
            item.date = Date()
            if let title, !title.isEmpty { item.title = title }
            items.insert(item, at: 0)
        } else {
            items.insert(HistoryItem(url: key, title: title ?? "", date: Date(), visits: 1), at: 0)
        }
        if items.count > 5000 { items.removeLast(items.count - 5000) }
        save()
    }

    func updateTitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, let i = items.firstIndex(where: { $0.url == url.absoluteString }), items[i].title != title else { return }
        items[i].title = title
        save()
    }

    func remove(_ url: String) {
        items.removeAll { $0.url == url }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// "Most visited" (HistoryQuery ordered by visits).
    func mostVisited(_ limit: Int = 12) -> [HistoryItem] {
        Array(items.sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.date > $1.date }.prefix(limit))
    }

    func matching(_ query: String, limit: Int = 4) -> [HistoryItem] {
        let q = query.lowercased()
        return items.filter { UrlUtils.strip($0.url).lowercased().hasPrefix(q) || $0.title.lowercased().contains(q) }
            .sorted { $0.visits > $1.visits }
            .prefix(limit).map { $0 }
    }

    /// DateSorter: Today, Yesterday, Last 7 days, Last month, Older.
    func grouped() -> [(String, [HistoryItem])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let week = cal.date(byAdding: .day, value: -7, to: today)!
        let month = cal.date(byAdding: .month, value: -1, to: today)!
        let bins: [(String, (Date) -> Bool)] = [
            ("Today", { $0 >= today }),
            ("Yesterday", { $0 >= yesterday && $0 < today }),
            ("Last 7 days", { $0 >= week && $0 < yesterday }),
            ("Last month", { $0 >= month && $0 < week }),
            ("Older", { $0 < month }),
        ]
        return bins.compactMap { name, test in
            let list = items.filter { test($0.date) }
            return list.isEmpty ? nil : (name, list)
        }
    }
}
