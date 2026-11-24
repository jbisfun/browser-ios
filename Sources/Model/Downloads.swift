import CoreLocation
import Foundation
import Observation

/// A download in flight or done (DownloadHandler + the system DownloadManager's row).
@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum Status { case running, done, failed(String), cancelled }

    let id = UUID()
    var filename: String
    var destination: URL?
    var progress: Double = 0
    var status: Status = .running
    let source: URL?
    @ObservationIgnored var cancelHandler: (() -> Void)?

    init(filename: String, source: URL?) {
        self.filename = filename
        self.source = source
    }

    var isRunning: Bool { if case .running = status { return true } else { return false } }
}

/// Downloads list: the running ones plus everything in Documents/Download.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    private(set) var active: [DownloadItem] = []
    private(set) var files: [URL] = []

    private init() { refresh() }

    func add(_ item: DownloadItem) {
        active.insert(item, at: 0)
    }

    func finished(_ item: DownloadItem) {
        active.removeAll { $0.id == item.id }
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: BrowserFiles.downloads, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        files = urls.filter { !$0.hasDirectoryPath }.sorted { modified($0) > modified($1) }
    }

    var savedPages: [URL] { files.filter { $0.pathExtension.lowercased() == "webarchive" } }

    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    /// "Save image" / "Save link": a plain fetch into Documents/Download.
    func fetch(_ source: URL, suggestedName: String? = nil) -> DownloadItem {
        let name = suggestedName ?? (source.lastPathComponent.isEmpty || source.lastPathComponent == "/" ? "downloadfile" : source.lastPathComponent)
        let item = DownloadItem(filename: name, source: source)
        add(item)
        let task = Task {
            do {
                if source.scheme == "data" {
                    let data = try Data(contentsOf: source)
                    let dest = BrowserFiles.uniqueDownload(name.contains(".") ? name : name + ".png")
                    try data.write(to: dest)
                    item.destination = dest
                } else {
                    let (tmp, response) = try await URLSession.shared.download(from: source)
                    let suggested = response.suggestedFilename ?? name
                    let dest = BrowserFiles.uniqueDownload(suggested)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    item.destination = dest
                    item.filename = dest.lastPathComponent
                }
                item.progress = 1
                item.status = .done
            } catch {
                item.status = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            finished(item)
        }
        item.cancelHandler = { task.cancel() }
        return item
    }
}

/// Per-site permission decisions (GeolocationPermissions + the "Remember preferences" box).
@MainActor
@Observable
final class SitePermissions {
    static let shared = SitePermissions()

    /// origin -> kind -> allowed
    private(set) var decisions: [String: [String: Bool]]

    private init() {
        decisions = BrowserFiles.load([String: [String: Bool]].self, "permissions.json") ?? [:]
    }

    private func save() { BrowserFiles.save(decisions, "permissions.json") }

    func decision(_ kind: PermissionKind, _ origin: String) -> Bool? { decisions[origin]?[kind.rawValue] }

    func set(_ kind: PermissionKind, _ origin: String, _ allowed: Bool) {
        decisions[origin, default: [:]][kind.rawValue] = allowed
        save()
    }

    func clear(_ kind: PermissionKind? = nil, origin: String? = nil) {
        if let origin {
            if let kind { decisions[origin]?[kind.rawValue] = nil } else { decisions[origin] = nil }
            if decisions[origin]?.isEmpty == true { decisions[origin] = nil }
        } else if let kind {
            for key in decisions.keys {
                decisions[key]?[kind.rawValue] = nil
                if decisions[key]?.isEmpty == true { decisions[key] = nil }
            }
        } else {
            decisions = [:]
        }
        save()
    }
}

/// Device location for the pages' navigator.geolocation (the shim in WebKitEngine).
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var waiting: [(Result<CLLocation, Error>) -> Void] = []
    private var watchers: [UUID: (Result<CLLocation, Error>) -> Void] = [:]

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func current(_ done: @escaping (Result<CLLocation, Error>) -> Void) {
        waiting.append(done)
        start()
        manager.requestLocation()
    }

    func watch(_ handler: @escaping (Result<CLLocation, Error>) -> Void) -> UUID {
        let id = UUID()
        watchers[id] = handler
        start()
        manager.startUpdatingLocation()
        return id
    }

    func stopWatching(_ id: UUID) {
        watchers[id] = nil
        if watchers.isEmpty { manager.stopUpdatingLocation() }
    }

    private func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    private func deliver(_ result: Result<CLLocation, Error>) {
        let list = waiting
        waiting = []
        list.forEach { $0(result) }
        watchers.values.forEach { $0(result) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { deliver(.success(last)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { deliver(.failure(error)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let status = manager.authorizationStatus
            if status == .denied || status == .restricted {
                deliver(.failure(CLError(.denied)))
            } else if status == .authorizedWhenInUse || status == .authorizedAlways, !waiting.isEmpty {
                manager.requestLocation()
            }
        }
    }
}
