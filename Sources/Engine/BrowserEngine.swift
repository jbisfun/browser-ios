import Foundation
import Observation
import UIKit

// The engine boundary. The UI and the models only talk to `BrowserEngine` and
// `BrowserPage`; WebKitEngine.swift is the one implementation (WKWebView).
// A Blink engine (Chromium's `use_blink` iOS port through BrowserEngineKit,
// see README "Chromium") would be a second implementation of these two
// protocols, selected in `Engines.current`.

/// Settings applied to every page (BrowserSettings.syncSettings).
struct PageSettings: Equatable {
    var javascript = true
    var blockPopups = true
    var loadImages = true
    var acceptCookies = true
    var textZoomPercent = 100
    var minimumFontSize = 0
    var forceUserScalable = false
    var inverted = false
    var contrast = 1.0
    var geolocation = true
    var securityWarnings = true
}

/// Live state of a page (what Tab kept from WebViewClient/WebChromeClient callbacks).
/// Owned by the tab, so it survives when the page itself is freed.
@MainActor
@Observable
final class PageState {
    var url: URL?
    var title: String = ""
    var progress: Double = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var isSecure = false
    var desktopMode = false
    /// The page's icon link (or /favicon.ico) once loaded.
    var faviconURL: URL?

    init(url: URL? = nil, title: String = "") {
        self.url = url
        self.title = title
    }
}

/// Element under a long press (WebView.HitTestResult).
struct ContextTarget {
    var link: URL?
    var linkText: String?
    var image: URL?
}

/// One entry of a long-press menu.
struct ContextAction {
    var title: String
    var icon: String
    var destructive = false
    var handler: @MainActor () -> Void
}

enum PermissionKind: String, Codable, CaseIterable {
    case location, camera, microphone

    var title: String {
        switch self {
        case .location: return "Location"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        }
    }
}

/// Everything a page needs the user to answer (JsDialogHelper, HttpAuthenticationDialog,
/// GeolocationPermissionsPrompt/PermissionsPrompt, the SSL error dialog).
struct PagePrompt: Identifiable {
    enum Kind {
        case alert(String, done: @MainActor () -> Void)
        case confirm(String, done: @MainActor (Bool) -> Void)
        case textInput(String, defaultText: String, done: @MainActor (String?) -> Void)
        case httpAuth(host: String, realm: String, done: @MainActor ((String, String)?) -> Void)
        case permission([PermissionKind], done: @MainActor (_ allow: Bool, _ remember: Bool) -> Void)
        case certificate(String, done: @MainActor (_ proceed: Bool) -> Void)
    }

    let id = UUID()
    var origin: String
    var kind: Kind
}

/// Callbacks from a page to the browser (WebViewController/UiController).
@MainActor
protocol BrowserPageDelegate: AnyObject {
    /// A page finished loading `url` (history, favicon, thumbnail).
    func page(_ page: BrowserPage, didFinish url: URL)
    /// window.open / target=_blank: the engine made `popup`; the browser shows it in a new tab.
    func page(_ page: BrowserPage, adoptPopup popup: BrowserPage, background: Bool)
    func page(_ page: BrowserPage, openInNewTab url: URL)
    /// window.close().
    func pageDidRequestClose(_ page: BrowserPage)
    func page(_ page: BrowserPage, prompt: PagePrompt)
    /// The long-press menu for `target` (BrowserActivity.onCreateContextMenu).
    func page(_ page: BrowserPage, menuFor target: ContextTarget) -> [ContextAction]
    /// A url the engine can't show (tel:, mailto:, app links): UrlHandler.
    func page(_ page: BrowserPage, openExternal url: URL)
    func page(_ page: BrowserPage, startedDownload item: DownloadItem)
}

/// One web view (a tab's WebView).
@MainActor
protocol BrowserPage: AnyObject {
    var state: PageState { get }
    var view: UIView { get }
    var incognito: Bool { get }

    func load(_ url: URL)
    /// A local .html/.webarchive file.
    func loadFile(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stop()
    func setDesktopMode(_ on: Bool)
    /// Download `url` with the page's cookies into Documents/Download.
    func download(_ url: URL)

    /// FindActionModeCallback: returns (current match, total matches).
    func find(_ text: String, backwards: Bool, restart: Bool) async -> (Int, Int)
    func clearFind()

    func snapshot(width: CGFloat) async -> UIImage?
    /// The page as a self-contained archive ("Save for offline reading").
    func archive() async -> (data: Data, fileExtension: String)?
    /// The certificate summary of the current page ("Page info" > "View certificate").
    var certificateSummary: String? { get }

    /// Back/forward list for persistence (Tab.saveState / restoreState).
    var sessionState: Data? { get }
    func restore(_ session: Data) -> Bool

    func apply(_ settings: PageSettings)
}

/// A web data record ("Website settings").
struct SiteDataRecord: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var kinds: [String]
}

/// Engine-wide operations (WebStorage, CookieManager, the caches).
@MainActor
protocol BrowserEngine: AnyObject {
    var name: String { get }
    func makePage(state: PageState, incognito: Bool, delegate: BrowserPageDelegate) -> BrowserPage
    func apply(_ settings: PageSettings)

    func clearCache() async
    func clearCookies() async
    func clearAllSiteData() async
    func siteData() async -> [SiteDataRecord]
    func clearSiteData(_ record: SiteDataRecord) async
    /// Drops every incognito cookie/cache once the last incognito tab closes.
    func resetIncognito()
}

@MainActor
enum Engines {
    static let current: BrowserEngine = WebKitEngine()
}

/// Built-in pages served by the engine (the AOSP "content://com.android.browser.home/").
enum BuiltinPages {
    static let scheme = "browser"
    static let mostVisited = URL(string: "browser://most-visited")!
    /// Draw the built-in pages dark (follows the Fossify palette).
    @MainActor static var dark = false

    static func isBuiltin(_ url: URL?) -> Bool { url?.scheme == scheme }

    /// res/raw/most_visited.ktpl filled from history.
    @MainActor
    static func mostVisitedHTML(dark: Bool) -> String {
        let items = HistoryStore.shared.mostVisited(12)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let cells = items.map { item -> String in
            let title = item.title.isEmpty ? UrlUtils.strip(item.url) : item.title
            let thumb = Thumbnails.exists(item.url) ? "browser://thumb/\(BrowserFiles.key(item.url))" : ""
            let img = thumb.isEmpty ? "<div class=\"wrimg ph\">\(esc(String(title.prefix(1)).uppercased()))</div>"
                : "<img class=\"wrimg\" src=\"\(thumb)\"/>"
            return "<li><a href=\"\(esc(item.url))\">\(img)<span class=\"caption\">\(esc(title))</span></a></li>"
        }.joined(separator: "\n")
        let fg = dark ? "#eee" : "#222"
        let bg = dark ? "#202020" : "#fff"
        let empty = items.isEmpty ? "<p class=\"empty\">Sites you visit often will appear here.</p>" : ""
        return """
        <!DOCTYPE html><html><head><title>Most visited</title>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=0"/>
        <style>
        *{padding:0;margin:0}
        body{font-family:-apple-system,sans-serif;text-align:center;margin:0 auto;padding:0 8px;max-width:720px;background:\(bg);color:\(fg)}
        h3{text-align:center;margin:14px 0 10px 0;font-weight:500}
        .thumbwrap li{display:inline-block;margin:0 7px 12px 7px;padding:0;width:44%;max-width:200px;vertical-align:top}
        .thumbwrap a{display:block;text-decoration:none;color:\(fg)}
        .wrimg{border:1px solid #8884;border-radius:6px;width:100%;aspect-ratio:4/3;object-fit:cover;object-position:top}
        .ph{display:flex;align-items:center;justify-content:center;font-size:40px;color:#1C7A8C;background:#8881}
        .caption{margin-top:3px;margin-left:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block;font-size:.8em;text-align:left}
        .empty{opacity:.6;margin-top:40px}
        </style></head><body><h3>Most visited</h3>\(empty)<ul class="thumbwrap">
        \(cells)
        </ul></body></html>
        """
    }
}
