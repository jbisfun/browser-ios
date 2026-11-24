import FossifyCommons
import Observation
import SwiftUI
import UIKit

enum Route: Hashable {
    case combined(CombinedTab)
    case bookmarkEditor(BookmarkDraft)
    case downloads
    case settings
    case settingsGeneral
    case settingsPrivacy
    case settingsAccessibility
    case settingsAdvanced
    case settingsBandwidth
    case websiteSettings
    case customizeColors
    case about
}

@MainActor
@Observable
final class Router {
    var path: [Route] = []

    func push(_ r: Route) { path.append(r) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    func popToRoot() { path.removeAll() }
}

/// The whole app as one view: the standalone app's window content, and what
/// the launcher presents. `openURL` is a web page or a local .html/.webarchive file.
public struct BrowserRoot: View {
    @State private var router = Router()
    private let openURL: URL?

    public init(openURL: URL? = nil) {
        self.openURL = openURL
    }

    public var body: some View {
        RootView()
            .environment(BrowserModel.shared)
            .environment(router)
            .environment(Config.shared)
            .fossifyTheme()
            .onOpenURL { url in
                router.popToRoot()
                BrowserModel.shared.open(url)
            }
            .onAppear {
                if let openURL {
                    router.popToRoot()
                    BrowserModel.shared.open(openURL)
                }
            }
    }
}

struct RootView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var router = router
        @Bindable var model = model
        NavigationStack(path: $router.path) {
            BrowserView()
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route)
                        .toolbar(.hidden, for: .navigationBar)
                        .paletteBackground()
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .toast($model.toast)
        .sheet(item: Binding(get: { model.prompts.first }, set: { if $0 == nil, !model.prompts.isEmpty { model.prompts.removeFirst() } })) { prompt in
            PromptDialog(prompt: prompt)
        }
        .sheet(item: $model.share) { ShareSheet(items: $0.items) }
        .alert("Tab limit reached", isPresented: $model.tabLimitReached) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Can't open a new tab until you close one.")
        }
        .onChange(of: config.pageSettings) { _, _ in model.applySettings() }
        .onChange(of: palette.dark, initial: true) { _, dark in BuiltinPages.dark = dark }
        .onChange(of: phase) { _, p in if p != .active { model.save() } }
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .combined(let tab): CombinedView(initial: tab)
        case .bookmarkEditor(let draft): BookmarkEditorView(draft: draft)
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        case .settingsGeneral: GeneralSettingsView()
        case .settingsPrivacy: PrivacySettingsView()
        case .settingsAccessibility: AccessibilitySettingsView()
        case .settingsAdvanced: AdvancedSettingsView()
        case .settingsBandwidth: BandwidthSettingsView()
        case .websiteSettings: WebsiteSettingsView()
        case .customizeColors: CustomizeColorsView()
        case .about: AboutView(app: .browser)
        }
    }
}
