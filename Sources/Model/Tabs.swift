import FossifyCommons
import Foundation
import Observation
import SwiftUI
import UIKit

/// Tab: one page plus what TabControl remembers about it.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let incognito: Bool
    let state: PageState
    /// Tab that opened this one (closing a pop-up returns to it).
    var parent: UUID?
    var thumbnail: UIImage?
    var page: BrowserPage?
    @ObservationIgnored var pendingSession: Data?
    @ObservationIgnored var lastUsed = Date()

    init(id: UUID = UUID(), url: URL?, title: String = "", incognito: Bool) {
        self.id = id
        self.incognito = incognito
        state = PageState(url: url, title: title)
    }

    /// A tab around a page the engine already made (pop-ups).
    init(page: BrowserPage) {
        id = UUID()
        incognito = page.incognito
        state = page.state
        self.page = page
    }

    var displayTitle: String {
        if BuiltinPages.isBuiltin(state.url) { return "Most visited" }
        if !state.title.isEmpty { return state.title }
        return state.url.map { UrlUtils.strip($0.absoluteString) } ?? "New tab"
    }
}

/// What TabControl.saveState wrote into the bundle.
private struct TabRecord: Codable {
    var id: UUID
    var url: String?
    var title: String
    var session: Data?
    var desktop: Bool
    var parent: UUID?
}

private struct TabsFile: Codable {
    var tabs: [TabRecord]
    var current: UUID?
}

struct ShareURL: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Controller + TabControl: tabs, page callbacks and the browser-wide actions.
@MainActor
@Observable
final class BrowserModel: BrowserPageDelegate {
    static let shared = BrowserModel()
    static let maxTabs = 16
    /// Pages kept alive at once (TabControl frees the WebViews of old tabs).
    private static let livePages = 8

    let engine: BrowserEngine = Engines.current
    private(set) var tabs: [BrowserTab] = []
    var currentID: UUID?
    var toast: String?
    var prompts: [PagePrompt] = []
    var share: ShareURL?
    var showTabs = false
    var tabLimitReached = false

    private init() {
        restore()
        engine.apply(Config.shared.pageSettings)
    }

    var current: BrowserTab? { tabs.first { $0.id == currentID } ?? tabs.first }

    // MARK: Tabs

    func page(for tab: BrowserTab) -> BrowserPage {
        if let page = tab.page { return page }
        let page = engine.makePage(state: tab.state, incognito: tab.incognito, delegate: self)
        tab.page = page
        if let session = tab.pendingSession, page.restore(session) {
            tab.pendingSession = nil
        } else if let url = tab.state.url {
            page.load(url)
        }
        freePages()
        return page
    }

    /// Drop the web views of the least recently used tabs (their back/forward list is kept).
    private func freePages() {
        let live = tabs.filter { $0.page != nil && $0.id != currentID }.sorted { $0.lastUsed > $1.lastUsed }
        for tab in live.dropFirst(Self.livePages - 1) {
            tab.pendingSession = tab.page?.sessionState
            tab.page = nil
        }
    }

    func select(_ tab: BrowserTab) {
        currentID = tab.id
        tab.lastUsed = Date()
        showTabs = false
        _ = page(for: tab)
        save()
    }

    @discardableResult
    func newTab(_ url: URL?, incognito: Bool = false, background: Bool = false, parent: UUID? = nil) -> BrowserTab? {
        guard tabs.count < Self.maxTabs else {
            tabLimitReached = true
            return nil
        }
        let tab = BrowserTab(url: url ?? homepageURL, incognito: incognito)
        tab.parent = parent
        tab.state.desktopMode = Config.shared.desktopUserAgent
        if let current, let i = tabs.firstIndex(where: { $0.id == current.id }), parent != nil {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
        if background {
            tab.lastUsed = .distantPast
            toast = "Opened in a new tab"
        } else {
            select(tab)
        }
        save()
        return tab
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.page?.stop()
        tab.page = nil
        tabs.remove(at: index)
        if tab.incognito { engine.resetIncognito() }
        if currentID == tab.id {
            let next = tab.parent.flatMap { id in tabs.first { $0.id == id } }
                ?? (tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)])
            if let next { select(next) } else { currentID = nil }
        }
        if tabs.isEmpty {
            newTab(nil)
        }
        save()
    }

    func closeOthers() {
        guard let current else { return }
        for tab in tabs where tab.id != current.id { close(tab) }
    }

    func closeAllIncognito() {
        for tab in tabs where tab.incognito { close(tab) }
    }

    // MARK: Loading

    var homepageURL: URL {
        switch Config.shared.homepage {
        case Homepage.defaultPage: return URL(string: Config.shared.engine.home)!
        case Homepage.mostVisited: return BuiltinPages.mostVisited
        default: return URL(string: Config.shared.homepage) ?? BuiltinPages.mostVisited
        }
    }

    /// UrlInputView.onAction: a url or a web search.
    func url(for input: String) -> URL? {
        UrlUtils.smartUrl(input) ?? Config.shared.engine.searchURL(input)
    }

    func load(_ input: String, in tab: BrowserTab? = nil) {
        guard let url = url(for: input) else { return }
        load(url, in: tab)
    }

    func load(_ url: URL, in tab: BrowserTab? = nil) {
        guard let tab = tab ?? current ?? newTab(nil) else { return }
        if url.isFileURL {
            page(for: tab).loadFile(url)
        } else if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "data", BuiltinPages.scheme].contains(scheme) {
            open(external: url)
        } else {
            page(for: tab).load(url)
        }
    }

    /// The launcher / an "Open in" handed over a page or an .html file (IntentHandler).
    func open(_ url: URL) {
        if let existing = tabs.first(where: { $0.state.url == url }) {
            select(existing)
        } else {
            newTab(url)
        }
    }

    func goHome() { load(homepageURL) }

    func open(external url: URL) {
        UIApplication.shared.open(url) { [weak self] ok in
            if !ok { self?.toast = "No app found to open this link" }
        }
    }

    func applySettings() { engine.apply(Config.shared.pageSettings) }

    // MARK: Actions

    func sharePage() {
        guard let tab = current, let url = tab.state.url, !BuiltinPages.isBuiltin(url) else { return }
        share = ShareURL(items: [url])
    }

    func savePage() {
        guard let tab = current, let page = tab.page else { return }
        toast = "Saving…"
        Task {
            guard let (data, ext) = await page.archive() else {
                toast = "Couldn't save for offline reading."
                return
            }
            let name = tab.displayTitle.isEmpty ? "page" : String(tab.displayTitle.prefix(60))
            let dest = BrowserFiles.uniqueDownload("\(name).\(ext)")
            do {
                try data.write(to: dest)
                DownloadStore.shared.refresh()
                toast = "Saved to Download/\(dest.lastPathComponent)"
            } catch {
                toast = "Couldn't save for offline reading."
            }
        }
    }

    func download(_ url: URL) {
        guard let tab = current else { return }
        page(for: tab).download(url)
    }

    // MARK: Persistence

    func save() {
        let records = tabs.filter { !$0.incognito }.map { tab in
            TabRecord(id: tab.id, url: tab.state.url?.absoluteString, title: tab.state.title,
                      session: tab.page?.sessionState ?? tab.pendingSession, desktop: tab.state.desktopMode, parent: tab.parent)
        }
        let current = self.current.flatMap { $0.incognito ? nil : $0.id }
        BrowserFiles.save(TabsFile(tabs: records, current: current), "tabs.json")
    }

    private func restore() {
        if let file = BrowserFiles.load(TabsFile.self, "tabs.json") {
            tabs = file.tabs.map { record in
                let tab = BrowserTab(id: record.id, url: record.url.flatMap(URL.init(string:)), title: record.title, incognito: false)
                tab.pendingSession = record.session
                tab.state.desktopMode = record.desktop
                tab.parent = record.parent
                tab.thumbnail = record.url.flatMap { Thumbnails.image($0) }
                return tab
            }
            currentID = file.current ?? tabs.first?.id
        }
        if tabs.isEmpty {
            let tab = BrowserTab(url: homepageURL, incognito: false)
            tabs = [tab]
            currentID = tab.id
        }
    }

    // MARK: BrowserPageDelegate

    private func tab(of page: BrowserPage) -> BrowserTab? { tabs.first { $0.page === page } }

    func page(_ page: BrowserPage, didFinish url: URL) {
        guard let tab = tab(of: page) else { return }
        if !tab.incognito && !BuiltinPages.isBuiltin(url) {
            HistoryStore.shared.visit(url, title: page.state.title)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard let image = await page.snapshot(width: 320) else { return }
            tab.thumbnail = image
            if !tab.incognito && !BuiltinPages.isBuiltin(url) { Thumbnails.save(image, for: url.absoluteString) }
        }
        save()
    }

    func page(_ page: BrowserPage, adoptPopup popup: BrowserPage, background: Bool) {
        guard tabs.count < Self.maxTabs else {
            tabLimitReached = true
            return
        }
        let source = tab(of: page)
        let tab = BrowserTab(page: popup)
        tab.parent = source?.id
        if let source, let i = tabs.firstIndex(where: { $0.id == source.id }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        if !background { select(tab) }
    }

    func page(_ page: BrowserPage, openInNewTab url: URL) {
        newTab(url, incognito: page.incognito, background: Config.shared.openInBackground, parent: tab(of: page)?.id)
    }

    func pageDidRequestClose(_ page: BrowserPage) {
        if let tab = tab(of: page) { close(tab) }
    }

    func page(_ page: BrowserPage, prompt: PagePrompt) {
        prompts.append(prompt)
    }

    func page(_ page: BrowserPage, openExternal url: URL) {
        open(external: url)
    }

    func page(_ page: BrowserPage, startedDownload item: DownloadItem) {
        toast = "Starting download…"
    }

    /// BrowserActivity.onCreateContextMenu (browsercontext.xml).
    func page(_ page: BrowserPage, menuFor target: ContextTarget) -> [ContextAction] {
        var actions: [ContextAction] = []
        let incognito = page.incognito
        let parent = tab(of: page)?.id
        if let link = target.link {
            switch link.scheme?.lowercased() {
            case "tel":
                let number = link.absoluteString.replacingOccurrences(of: "tel:", with: "").removingPercentEncoding ?? ""
                actions += [
                    ContextAction(title: "Dial…", icon: "phone") { [weak self] in self?.open(external: link) },
                    ContextAction(title: "Copy", icon: "doc.on.doc") { [weak self] in self?.toast = Launcher.copy(number) },
                ]
            case "mailto":
                let address = link.absoluteString.replacingOccurrences(of: "mailto:", with: "").components(separatedBy: "?")[0]
                actions += [
                    ContextAction(title: "Send email", icon: "envelope") { [weak self] in self?.open(external: link) },
                    ContextAction(title: "Copy", icon: "doc.on.doc") { [weak self] in self?.toast = Launcher.copy(address) },
                ]
            default:
                let background = Config.shared.openInBackground
                actions += [
                    ContextAction(title: "Open", icon: "arrow.up.right.square") { [weak page] in page?.load(link) },
                    ContextAction(title: background ? "Open in new background tab" : "Open in new tab", icon: "plus.square.on.square") { [weak self] in
                        self?.newTab(link, incognito: incognito, background: background, parent: parent)
                    },
                    ContextAction(title: "Save link", icon: "arrow.down.circle") { [weak page] in page?.download(link) },
                    ContextAction(title: "Copy link URL", icon: "link") { [weak self] in self?.toast = Launcher.copy(link.absoluteString) },
                    ContextAction(title: "Share link", icon: "square.and.arrow.up") { [weak self] in self?.share = ShareURL(items: [link]) },
                ]
            }
        }
        if let image = target.image {
            actions += [
                ContextAction(title: "Save image", icon: "square.and.arrow.down") { [weak page] in page?.download(image) },
                ContextAction(title: "View image", icon: "photo") { [weak page] in page?.load(image) },
                ContextAction(title: "Copy image URL", icon: "doc.on.doc") { [weak self] in self?.toast = Launcher.copy(image.absoluteString) },
                ContextAction(title: "Share image", icon: "square.and.arrow.up") { [weak self] in self?.shareImage(image) },
            ]
        }
        return actions
    }

    private func shareImage(_ url: URL) {
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
                share = ShareURL(items: [image])
            } else {
                share = ShareURL(items: [url])
            }
        }
    }
}
