import CoreLocation
import Foundation
import UIKit
import WebKit

// The WebKit (WKWebView) implementation of the engine boundary.

/// Routes script messages to the page that owns the sending web view
/// (pop-ups share their opener's WKUserContentController).
private final class ScriptRouter: NSObject, WKScriptMessageHandler {
    weak var engine: WebKitEngine?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let webView = message.webView, let page = engine?.page(for: webView) else { return }
            page.handle(message)
        }
    }
}

/// Serves browser:// pages (most visited, thumbnails).
private final class BuiltinSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        MainActor.assumeIsolated {
            guard let url = task.request.url else { return }
            var data = Data()
            var mime = "text/html"
            switch url.host {
            case "thumb":
                let key = url.lastPathComponent
                data = (try? Data(contentsOf: Thumbnails.file(key: key))) ?? Data()
                mime = "image/jpeg"
            default:
                data = Data(BuiltinPages.mostVisitedHTML(dark: BuiltinPages.dark).utf8)
            }
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class WebKitEngine: BrowserEngine {
    let name = "WebKit"

    private var settings = PageSettings()
    private var pages: [WeakPage] = []
    private let router = ScriptRouter()
    private let schemeHandler = BuiltinSchemeHandler()
    private var incognitoStore: WKWebsiteDataStore?
    private var blockImagesList: WKContentRuleList?
    private var blockCookiesList: WKContentRuleList?

    private struct WeakPage {
        weak var page: WebKitPage?
    }

    init() {
        router.engine = self
        compileRuleLists()
    }

    var livePages: [WebKitPage] {
        pages.removeAll { $0.page == nil }
        return pages.compactMap(\.page)
    }

    func page(for webView: WKWebView) -> WebKitPage? { livePages.first { $0.webView === webView } }

    func register(_ page: WebKitPage) { pages.append(WeakPage(page: page)) }

    func makePage(state: PageState, incognito: Bool, delegate: BrowserPageDelegate) -> BrowserPage {
        let page = WebKitPage(engine: self, configuration: makeConfiguration(incognito: incognito), state: state,
                              incognito: incognito, delegate: delegate)
        page.apply(settings)
        return page
    }

    private func makeConfiguration(incognito: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if incognito {
            if incognitoStore == nil { incognitoStore = .nonPersistent() }
            config.websiteDataStore = incognitoStore!
        } else {
            config.websiteDataStore = .default()
        }
        config.setURLSchemeHandler(schemeHandler, forURLScheme: BuiltinPages.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.userContentController.add(router, name: "fossifyGeo")
        installScripts(config.userContentController)
        return config
    }

    func apply(_ settings: PageSettings) {
        self.settings = settings
        var controllers: [ObjectIdentifier: WKUserContentController] = [:]
        for page in livePages {
            let controller = page.webView.configuration.userContentController
            controllers[ObjectIdentifier(controller)] = controller
            page.apply(settings)
        }
        for controller in controllers.values { installScripts(controller) }
    }

    /// User scripts: long-press hit testing, the geolocation shim and the settings that
    /// WKWebView has no switch for (text scaling, force zoom, inverted rendering).
    func installScripts(_ controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: Scripts.hitTest, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Scripts.geolocation, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Scripts.settings(settings), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.removeAllContentRuleLists()
        if !settings.loadImages, let list = blockImagesList { controller.add(list) }
        if !settings.acceptCookies, let list = blockCookiesList { controller.add(list) }
    }

    private func compileRuleLists() {
        let store = WKContentRuleListStore.default()
        store?.compileContentRuleList(forIdentifier: "fossify-block-images", encodedContentRuleList:
            #"[{"trigger":{"url-filter":".*","resource-type":["image"]},"action":{"type":"block"}}]"#) { list, _ in
            MainActor.assumeIsolated {
                self.blockImagesList = list
                self.apply(self.settings)
            }
        }
        store?.compileContentRuleList(forIdentifier: "fossify-block-cookies", encodedContentRuleList:
            #"[{"trigger":{"url-filter":".*"},"action":{"type":"block-cookies"}}]"#) { list, _ in
            MainActor.assumeIsolated {
                self.blockCookiesList = list
                self.apply(self.settings)
            }
        }
    }

    func clearCache() async {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
                                  WKWebsiteDataTypeOfflineWebApplicationCache]
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
        Thumbnails.clear()
    }

    func clearCookies() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
    }

    func clearAllSiteData() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func siteData() async -> [SiteDataRecord] {
        let records = await WKWebsiteDataStore.default().dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return records.map { SiteDataRecord(name: $0.displayName, kinds: $0.dataTypes.map(Self.describe).sorted()) }
            .sorted { $0.name < $1.name }
    }

    func clearSiteData(_ record: SiteDataRecord) async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName == record.name })
    }

    func resetIncognito() {
        if livePages.contains(where: \.incognito) { return }
        incognitoStore = nil
    }

    private static func describe(_ type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: return "Cookies"
        case WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache: return "Cache"
        case WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage: return "Local storage"
        case WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases: return "Databases"
        case WKWebsiteDataTypeServiceWorkerRegistrations: return "Service workers"
        default: return "Other"
        }
    }
}

/// A tab's WKWebView with the WebViewClient/WebChromeClient/DownloadListener roles.
@MainActor
final class WebKitPage: NSObject, BrowserPage, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let state: PageState
    let incognito: Bool
    let webView: WKWebView
    private unowned let engine: WebKitEngine
    private weak var delegate: BrowserPageDelegate?
    private var settings = PageSettings()
    private var observations: [NSKeyValueObservation] = []
    private var downloads: [ObjectIdentifier: (DownloadItem, NSKeyValueObservation?)] = [:]
    private var geoWatches: [Int: UUID] = [:]
    private var sessionGrants: [PermissionKind: Bool] = [:]
    private var findText = ""
    private var findIndex = 0
    private var findTotal = 0

    var view: UIView { webView }

    init(engine: WebKitEngine, configuration: WKWebViewConfiguration, state: PageState, incognito: Bool, delegate: BrowserPageDelegate) {
        self.engine = engine
        self.state = state
        self.incognito = incognito
        self.delegate = delegate
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isInspectable = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        let sync: (WKWebView) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
        observations = [
            webView.observe(\.url) { w, _ in sync(w) },
            webView.observe(\.title) { w, _ in sync(w) },
            webView.observe(\.estimatedProgress) { w, _ in sync(w) },
            webView.observe(\.isLoading) { w, _ in sync(w) },
            webView.observe(\.canGoBack) { w, _ in sync(w) },
            webView.observe(\.canGoForward) { w, _ in sync(w) },
            webView.observe(\.hasOnlySecureContent) { w, _ in sync(w) },
        ]
        engine.register(self)
    }

    deinit {
        observations.removeAll()
    }

    private func sync() {
        if let url = webView.url { state.url = url }
        state.title = webView.title ?? ""
        state.progress = webView.estimatedProgress
        state.isLoading = webView.isLoading
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        state.isSecure = webView.url?.scheme == "https" && webView.hasOnlySecureContent
    }

    // MARK: BrowserPage

    func load(_ url: URL) {
        if url.isFileURL {
            loadFile(url)
        } else if url.absoluteString == Homepage.blank {
            webView.loadHTMLString("", baseURL: nil)
            state.url = url
        } else {
            webView.load(URLRequest(url: url))
            state.url = url
        }
    }

    func loadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "webarchive", let data = try? Data(contentsOf: url) {
            webView.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: url)
        } else {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        state.url = url
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        if webView.url == nil, let url = state.url { load(url) } else { webView.reload() }
    }

    func stop() { webView.stopLoading() }

    func setDesktopMode(_ on: Bool) {
        guard state.desktopMode != on else { return }
        state.desktopMode = on
        if webView.url != nil { webView.reloadFromOrigin() }
    }

    func find(_ text: String, backwards: Bool, restart: Bool) async -> (Int, Int) {
        guard !text.isEmpty else {
            clearFind()
            return (0, 0)
        }
        if restart || text != findText {
            findText = text
            findTotal = await count(text)
            findIndex = 0
            clearSelection()
        }
        guard findTotal > 0 else { return (0, 0) }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        guard let result = try? await webView.find(text, configuration: config), result.matchFound else { return (0, findTotal) }
        if findIndex == 0 {
            findIndex = backwards ? findTotal : 1
        } else if backwards {
            findIndex = findIndex == 1 ? findTotal : findIndex - 1
        } else {
            findIndex = findIndex % findTotal + 1
        }
        return (findIndex, findTotal)
    }

    private func count(_ text: String) async -> Int {
        let js = """
        (function(q){var t=document.body?document.body.innerText:'';t=t.toLowerCase();q=q.toLowerCase();
        var c=0,i=0;if(!q)return 0;while((i=t.indexOf(q,i))!==-1){c++;i+=q.length;}return c;})(\(Scripts.quote(text)))
        """
        return (await evaluate(js) as? Int) ?? 0
    }

    private func clearSelection() { webView.evaluateJavaScript("window.getSelection&&window.getSelection().removeAllRanges()") }

    func clearFind() {
        findText = ""
        findIndex = 0
        findTotal = 0
        clearSelection()
    }

    func snapshot(width: CGFloat) async -> UIImage? {
        guard webView.bounds.width > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(width))
        config.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: min(webView.bounds.height, webView.bounds.width * 1.2))
        return await withCheckedContinuation { cont in
            webView.takeSnapshot(with: config) { image, _ in cont.resume(returning: image) }
        }
    }

    func archive() async -> (data: Data, fileExtension: String)? {
        await withCheckedContinuation { cont in
            webView.createWebArchiveData { result in
                cont.resume(returning: (try? result.get()).map { ($0, "webarchive") })
            }
        }
    }

    var certificateSummary: String? {
        guard let trust = webView.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? "?"
        let issuer = chain.count > 1 ? (SecCertificateCopySubjectSummary(chain[1]) as String? ?? "?") : subject
        return "Issued to: \(subject)\nIssued by: \(issuer)"
    }

    var sessionState: Data? { webView.interactionState as? Data }

    func restore(_ session: Data) -> Bool {
        webView.interactionState = session
        return webView.url != nil || webView.backForwardList.currentItem != nil
    }

    func apply(_ settings: PageSettings) {
        self.settings = settings
        let prefs = webView.configuration.preferences
        prefs.javaScriptCanOpenWindowsAutomatically = !settings.blockPopups
        prefs.minimumFontSize = CGFloat(settings.minimumFontSize)
        prefs.isFraudulentWebsiteWarningEnabled = settings.securityWarnings
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = settings.javascript
        if webView.url != nil { webView.evaluateJavaScript(Scripts.settings(settings)) }
    }

    func download(_ url: URL) {
        if url.scheme == "data" || url.scheme == "blob" {
            delegate?.page(self, startedDownload: DownloadStore.shared.fetch(url))
            return
        }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            MainActor.assumeIsolated { self?.track(download, source: url) }
        }
    }

    @discardableResult
    private func evaluate(_ js: String) async -> Any? {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, _ in cont.resume(returning: result) }
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = state.desktopMode ? .desktop : .mobile
        preferences.allowsContentJavaScript = settings.javascript
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow, preferences)
            return
        }
        let handled = ["http", "https", "file", "about", "data", "blob", "javascript", BuiltinPages.scheme]
        if handled.contains(scheme) {
            decisionHandler(.allow, preferences)
        } else {
            decisionHandler(.cancel, preferences)
            delegate?.page(self, openExternal: url)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !response.canShowMIMEType || (response.isForMainFrame && disposition.lowercased().hasPrefix("attachment")) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download, source: navigationAction.request.url)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download, source: navigationResponse.response.url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        stopGeoWatches()
        sessionGrants = [:]
        sync()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync()
        guard let url = webView.url else { return }
        delegate?.page(self, didFinish: url)
        webView.evaluateJavaScript(Scripts.favicon) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let href = result as? String, let icon = URL(string: href) else { return }
                self.state.faviconURL = icon
                if !self.incognito { Favicons.shared.remember(icon, for: url) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        sync()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func showError(_ error: Error) {
        sync()
        let ns = error as NSError
        // Cancelled, or interrupted by a download / policy change.
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204)) { return }
        let failing = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? state.url
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Webpage not available</title>
        <style>body{font-family:-apple-system,sans-serif;padding:24px;color:#444}h2{font-weight:500}</style></head>
        <body><h2>Webpage not available</h2><p>The webpage at <b>\(failing?.absoluteString ?? "")</b> could not be loaded because:</p>
        <p>\(ns.localizedDescription)</p></body></html>
        """
        webView.loadHTMLString(html, baseURL: failing)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return completionHandler(.performDefaultHandling, nil) }
            if SecTrustEvaluateWithError(trust, nil) { return completionHandler(.performDefaultHandling, nil) }
            // Tab.onReceivedSslError: proceed silently when warnings are off.
            guard settings.securityWarnings else { return completionHandler(.useCredential, URLCredential(trust: trust)) }
            delegate?.page(self, prompt: PagePrompt(origin: space.host, kind: .certificate(
                "There are problems with the security certificate for this site.") { proceed in
                    if proceed { completionHandler(.useCredential, URLCredential(trust: trust)) } else { completionHandler(.cancelAuthenticationChallenge, nil) }
                }))
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            delegate?.page(self, prompt: PagePrompt(origin: space.host, kind: .httpAuth(host: space.host, realm: space.realm ?? "") { creds in
                if let creds {
                    completionHandler(.useCredential, URLCredential(user: creds.0, password: creds.1, persistence: .forSession))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: UI (WebChromeClient)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WebKitPage(engine: engine, configuration: configuration, state: PageState(url: action.request.url),
                               incognito: incognito, delegate: delegate!)
        popup.apply(settings)
        delegate?.page(self, adoptPopup: popup, background: false)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.pageDidRequestClose(self)
    }

    private func origin(_ frame: WKFrameInfo) -> String {
        let o = frame.securityOrigin
        return o.host.isEmpty ? (state.url?.absoluteString ?? "") : "\(o.protocol)://\(o.host)\(o.port > 0 ? ":\(o.port)" : "")"
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        delegate?.page(self, prompt: PagePrompt(origin: origin(frame), kind: .alert(message, done: completionHandler)))
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        delegate?.page(self, prompt: PagePrompt(origin: origin(frame), kind: .confirm(message, done: completionHandler)))
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        delegate?.page(self, prompt: PagePrompt(origin: origin(frame), kind: .textInput(prompt, defaultText: defaultText ?? "", done: completionHandler)))
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let kinds: [PermissionKind]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        default: kinds = [.camera, .microphone]
        }
        let site = self.origin(frame)
        ask(kinds, site) { decisionHandler($0 ? .grant : .deny) }
    }

    /// PermissionsPrompt/GeolocationPermissionsPrompt with the remembered decisions.
    private func ask(_ kinds: [PermissionKind], _ site: String, done: @escaping (Bool) -> Void) {
        let stored = kinds.map { SitePermissions.shared.decision($0, site) ?? sessionGrants[$0] }
        if stored.allSatisfy({ $0 == true }) { return done(true) }
        if stored.contains(where: { $0 == false }) { return done(false) }
        delegate?.page(self, prompt: PagePrompt(origin: site, kind: .permission(kinds) { [weak self] allow, remember in
            for kind in kinds {
                if remember && !(self?.incognito ?? true) { SitePermissions.shared.set(kind, site, allow) }
                self?.sessionGrants[kind] = allow
            }
            done(allow)
        }))
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        let link = elementInfo.linkURL
        webView.evaluateJavaScript("JSON.stringify(window.__fossifyHit||{})") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let delegate = self.delegate else { return completionHandler(nil) }
                var target = ContextTarget(link: link)
                if let json = (result as? String)?.data(using: .utf8),
                   let hit = try? JSONSerialization.jsonObject(with: json) as? [String: String] {
                    if let img = hit["img"] { target.image = URL(string: img) }
                    if target.link == nil, let href = hit["link"] { target.link = URL(string: href) }
                    target.linkText = hit["text"]
                }
                if target.link == nil && target.image == nil { return completionHandler(nil) }
                let actions = delegate.page(self, menuFor: target)
                guard !actions.isEmpty else { return completionHandler(nil) }
                let title = target.link?.absoluteString ?? target.image?.absoluteString ?? ""
                completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                    UIMenu(title: title, children: actions.map { action in
                        UIAction(title: action.title, image: UIImage(systemName: action.icon),
                                 attributes: action.destructive ? .destructive : []) { _ in action.handler() }
                    })
                })
            }
        }
    }

    // MARK: Downloads

    private func track(_ download: WKDownload, source: URL?) {
        download.delegate = self
        let name = source?.lastPathComponent ?? "downloadfile"
        let item = DownloadItem(filename: name, source: source)
        let progress = download.progress.observe(\.fractionCompleted) { p, _ in
            let value = p.fractionCompleted
            DispatchQueue.main.async { item.progress = value }
        }
        item.cancelHandler = { download.cancel { _ in } }
        downloads[ObjectIdentifier(download)] = (item, progress)
        DownloadStore.shared.add(item)
        delegate?.page(self, startedDownload: item)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let dest = BrowserFiles.uniqueDownload(suggestedFilename)
        if let item = downloads[ObjectIdentifier(download)]?.0 {
            item.filename = dest.lastPathComponent
            item.destination = dest
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let (item, _) = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.progress = 1
        item.status = .done
        DownloadStore.shared.finished(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let (item, _) = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.status = (error as NSError).code == NSURLErrorCancelled ? .cancelled : .failed(error.localizedDescription)
        DownloadStore.shared.finished(item)
    }

    // MARK: Geolocation shim

    func handle(_ message: WKScriptMessage) {
        guard message.name == "fossifyGeo", let body = message.body as? [String: Any],
              let op = body["op"] as? String, let id = body["id"] as? Int else { return }
        if op == "clear" {
            if let watch = geoWatches.removeValue(forKey: id) { LocationProvider.shared.stopWatching(watch) }
            return
        }
        guard settings.geolocation else { return geoError(id, 1, "User denied Geolocation") }
        ask([.location], origin(message.frameInfo)) { [weak self] allowed in
            guard let self else { return }
            guard allowed else { return self.geoError(id, 1, "User denied Geolocation") }
            let deliver: (Result<CLLocationLike, Error>) -> Void = { [weak self] result in
                switch result {
                case .success(let loc): self?.geoSuccess(id, loc)
                case .failure: self?.geoError(id, 2, "Position unavailable")
                }
            }
            if op == "watch" {
                self.geoWatches[id] = LocationProvider.shared.watch { deliver($0.map(CLLocationLike.init)) }
            } else {
                LocationProvider.shared.current { deliver($0.map(CLLocationLike.init)) }
            }
        }
    }

    private func stopGeoWatches() {
        geoWatches.values.forEach { LocationProvider.shared.stopWatching($0) }
        geoWatches = [:]
    }

    private func geoSuccess(_ id: Int, _ l: CLLocationLike) {
        webView.evaluateJavaScript("window.__fossifyGeo&&window.__fossifyGeo.ok(\(id),{lat:\(l.lat),lon:\(l.lon),acc:\(l.acc),alt:\(l.alt),altAcc:\(l.altAcc),heading:\(l.heading),speed:\(l.speed),ts:\(l.ts)})")
    }

    private func geoError(_ id: Int, _ code: Int, _ message: String) {
        webView.evaluateJavaScript("window.__fossifyGeo&&window.__fossifyGeo.err(\(id),\(code),\(Scripts.quote(message)))")
    }
}

/// The fields navigator.geolocation needs, as JS literals.
struct CLLocationLike {
    var lat, lon, acc, alt, altAcc, heading, speed: String
    var ts: Int64

    init(_ l: CLLocation) {
        lat = "\(l.coordinate.latitude)"
        lon = "\(l.coordinate.longitude)"
        acc = "\(l.horizontalAccuracy)"
        alt = l.verticalAccuracy >= 0 ? "\(l.altitude)" : "null"
        altAcc = l.verticalAccuracy >= 0 ? "\(l.verticalAccuracy)" : "null"
        heading = l.course >= 0 ? "\(l.course)" : "null"
        speed = l.speed >= 0 ? "\(l.speed)" : "null"
        ts = Int64(l.timestamp.timeIntervalSince1970 * 1000)
    }
}

/// Injected scripts.
enum Scripts {
    static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Remembers the link/image under the finger for the long-press menu (HitTestResult).
    static let hitTest = """
    (function(){
      function hit(e){var r={};for(var n=e.target;n&&n!==document;n=n.parentNode){
        if(!r.img&&n.tagName==='IMG'&&(n.currentSrc||n.src)){r.img=n.currentSrc||n.src;}
        if(!r.link&&n.tagName==='A'&&n.href){r.link=n.href;r.text=(n.innerText||'').trim().slice(0,200);}}
        window.__fossifyHit=r;}
      document.addEventListener('touchstart',hit,{capture:true,passive:true});
    })();
    """

    /// navigator.geolocation answered natively, so every request goes through the
    /// per-site prompt (WKWebView has no public geolocation permission callback).
    static let geolocation = """
    (function(){
      if(!navigator.geolocation||!window.webkit||!window.webkit.messageHandlers.fossifyGeo)return;
      var cbs={},n=0;function post(m){window.webkit.messageHandlers.fossifyGeo.postMessage(m);}
      window.__fossifyGeo={
        ok:function(id,c){var e=cbs[id];if(!e)return;if(!e.watch)delete cbs[id];
          e.s&&e.s({coords:{latitude:c.lat,longitude:c.lon,accuracy:c.acc,altitude:c.alt,altitudeAccuracy:c.altAcc,heading:c.heading,speed:c.speed},timestamp:c.ts});},
        err:function(id,code,msg){var e=cbs[id];if(!e)return;if(!e.watch)delete cbs[id];
          e.e&&e.e({code:code,message:msg,PERMISSION_DENIED:1,POSITION_UNAVAILABLE:2,TIMEOUT:3});}
      };
      var g=navigator.geolocation;
      g.getCurrentPosition=function(s,e,o){var id=++n;cbs[id]={s:s,e:e};post({op:'get',id:id});};
      g.watchPosition=function(s,e,o){var id=++n;cbs[id]={s:s,e:e,watch:true};post({op:'watch',id:id});return id;};
      g.clearWatch=function(id){delete cbs[id];post({op:'clear',id:id});};
    })();
    """

    static let favicon = """
    (function(){var l=document.querySelector('link[rel~="icon"],link[rel="apple-touch-icon"],link[rel="shortcut icon"]');
    return l&&l.href?l.href:(location.protocol.indexOf('http')===0?location.origin+'/favicon.ico':'');})()
    """

    /// Text scaling, force enable zoom and inverted rendering (Accessibility settings).
    static func settings(_ s: PageSettings) -> String {
        var css = ""
        if s.textZoomPercent != 100 {
            css += "html{-webkit-text-size-adjust:\(s.textZoomPercent)% !important;}"
        }
        if s.inverted {
            css += "html{filter:invert(1) contrast(\(s.contrast)) !important;background:#fff;}"
        }
        return """
        (function(){
          var id='__fossify_settings',st=document.getElementById(id);
          if(!st){st=document.createElement('style');st.id=id;(document.head||document.documentElement).appendChild(st);}
          st.textContent=\(quote(css));
          if(\(s.forceUserScalable)){var m=document.querySelector('meta[name=viewport]');
            if(m)m.setAttribute('content','width=device-width, initial-scale=1, maximum-scale=10, user-scalable=yes');}
        })();
        """
    }
}
