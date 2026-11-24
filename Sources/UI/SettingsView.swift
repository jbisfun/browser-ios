import FossifyCommons
import SwiftUI

extension AppInfo {
    public static let browser = AppInfo(name: "Browser", icon: "globe", upstream: "Browser", port: "browser-ios", policy: "browser", faq: [
        ("Why does it use Safari's engine?", "Apple only lets EU and Japanese browsers with a special entitlement ship another engine, so pages are drawn by WebKit (WKWebView) like in every other iOS browser."),
        ("Where are my downloads?", "In the Download folder of the app's documents, visible in the Files app and in File Manager."),
    ])
}

/// BrowserPreferencesPage: Fossify's color and about rows plus the AOSP preference headers.
struct SettingsView: View {
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Settings")
            ScrollView {
                VStack(spacing: 0) {
                    Text("Color customization").sectionHeader(palette)
                    SettingsItem("Customize colors") { router.push(.customizeColors) }

                    Text("Browser").sectionHeader(palette)
                    SettingsItem("General", value: "Homepage") { router.push(.settingsGeneral) }
                    SettingsItem("Privacy & security", value: "Cache, history, cookies, location") { router.push(.settingsPrivacy) }
                    SettingsItem("Accessibility", value: "Text scaling, zoom, inverted rendering") { router.push(.settingsAccessibility) }
                    SettingsItem("Advanced", value: "Search engine, JavaScript, pop-ups, website settings") { router.push(.settingsAdvanced) }
                    SettingsItem("Bandwidth management", value: "Images") { router.push(.settingsBandwidth) }

                    Text("Other").sectionHeader(palette)
                    SettingsItem("About") { router.push(.about) }
                }
                .padding(.bottom, 32)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
    }
}

/// SettingsItem with a summary line, for the AOSP preferences that have one.
private struct SummaryToggle: View {
    @Environment(\.palette) private var palette
    let title: String
    let summary: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(palette.textColor)
                Text(summary).font(.system(size: 14)).foregroundStyle(palette.secondaryText)
            }
        }
        .tint(palette.primaryColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// BrowserYesNoPreference: a row that asks before clearing something.
private struct YesNoItem: View {
    let title: String
    let summary: String
    let question: String
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        SettingsItem(title, value: summary) { asking = true }
            .alert(title, isPresented: $asking) {
                Button("Cancel", role: .cancel) {}
                Button("OK", role: .destructive, action: action)
            } message: {
                Text(question)
            }
    }
}

/// general_preferences.xml (auto-fill is the system's on iOS).
struct GeneralSettingsView: View {
    @Environment(Config.self) private var config
    @Environment(BrowserModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var picking = false
    @State private var other = false
    @State private var otherURL = ""

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "General")
            ScrollView {
                VStack(spacing: 0) {
                    SettingsItem("Set homepage", value: homepageTitle) { picking = true }
                }
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .sheet(isPresented: $picking) {
            RadioDialog(title: "Set homepage", items: [("current", "Current page"), (Homepage.blank, "Blank page"),
                                                       (Homepage.defaultPage, "Default page"), (Homepage.mostVisited, "Most visited sites"),
                                                       ("other", "Other…")],
                        selected: selectedChoice) { choice in
                switch choice {
                case "current":
                    if let url = model.current?.state.url, !BuiltinPages.isBuiltin(url) { config.homepage = url.absoluteString }
                case "other":
                    otherURL = isCustom ? config.homepage : "https://"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { other = true }
                default:
                    config.homepage = choice
                }
            }
        }
        .sheet(isPresented: $other) {
            DialogFrame(title: "Set homepage") {
                DialogTextField(placeholder: "URL", text: $otherURL).keyboardType(.URL)
                DialogButtons(okEnabled: UrlUtils.smartUrl(otherURL) != nil) {
                    if let url = UrlUtils.smartUrl(otherURL) { config.homepage = url.absoluteString }
                    other = false
                }
            }
        }
    }

    private var isCustom: Bool { ![Homepage.blank, Homepage.defaultPage, Homepage.mostVisited].contains(config.homepage) }

    private var selectedChoice: String { isCustom ? "other" : config.homepage }

    private var homepageTitle: String {
        switch config.homepage {
        case Homepage.blank: return "Blank page"
        case Homepage.defaultPage: return "Default page (\(config.engine.label))"
        case Homepage.mostVisited: return "Most visited sites"
        default: return config.homepage
        }
    }
}

/// privacy_security_preferences.xml (form data and passwords belong to iOS AutoFill).
struct PrivacySettingsView: View {
    @Environment(Config.self) private var config
    @Environment(BrowserModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var config = config
        VStack(spacing: 0) {
            TopBar(title: "Privacy & security")
            ScrollView {
                VStack(spacing: 0) {
                    YesNoItem(title: "Clear cache", summary: "Clear locally cached content and databases",
                              question: "Delete locally cached content and databases?") {
                        Task {
                            await model.engine.clearCache()
                            model.toast = "Cache cleared"
                        }
                    }
                    YesNoItem(title: "Clear history", summary: "Clear the browser navigation history",
                              question: "Delete the browser navigation history?") {
                        HistoryStore.shared.clear()
                        model.toast = "History cleared"
                    }
                    SummaryToggle(title: "Show security warnings", summary: "Show warning if there's a problem with a site's security",
                                  isOn: $config.showSecurityWarnings)

                    Text("Cookies").sectionHeader(palette)
                    SummaryToggle(title: "Accept cookies", summary: "Allow sites to save and read cookie data", isOn: $config.acceptCookies)
                    YesNoItem(title: "Clear all cookie data", summary: "Clear all browser cookies", question: "Delete all cookies?") {
                        Task {
                            await model.engine.clearCookies()
                            model.toast = "Cookies cleared"
                        }
                    }
                    YesNoItem(title: "Clear all site data", summary: "Clear cookies, storage and databases of every website",
                              question: "Delete all website data?") {
                        Task {
                            await model.engine.clearAllSiteData()
                            model.toast = "Website data cleared"
                        }
                    }

                    Text("Location").sectionHeader(palette)
                    SummaryToggle(title: "Enable location", summary: "Allow sites to request access to your location", isOn: $config.enableGeolocation)
                    YesNoItem(title: "Clear location access", summary: "Clear location access for all websites",
                              question: "Clear website location access?") {
                        SitePermissions.shared.clear(.location)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
    }
}

/// accessibility_preferences.xml with the FontSizePreview / InvertedContrastPreview.
struct AccessibilitySettingsView: View {
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var config = config
        VStack(spacing: 0) {
            TopBar(title: "Accessibility")
            ScrollView {
                VStack(spacing: 0) {
                    SummaryToggle(title: "Force enable zoom", summary: "Override a website's request to control zoom behavior",
                                  isOn: $config.forceUserScalable)

                    Text("Text size").sectionHeader(palette)
                    preview
                    slider("Text scaling", "\(config.textZoomPercent)%", value: $config.textZoom, range: 0...30)
                    slider("Minimum font size", config.minimumFontPoints == 0 ? "Off" : "\(config.minimumFontPoints)pt",
                           value: $config.minFontSize, range: 0...20)

                    Text("Inverted screen rendering").sectionHeader(palette)
                    invertedPreview
                    SummaryToggle(title: "Inverted rendering", summary: "Black becomes white and vice versa", isOn: $config.inverted)
                    slider("Contrast", String(format: "%.1f", config.contrast), value: $config.invertedContrast, range: 0...30)
                        .disabled(!config.inverted)
                        .opacity(config.inverted ? 1 : 0.5)
                }
                .padding(.bottom, 32)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
    }

    private var preview: some View {
        let size = max(CGFloat(config.minimumFontPoints), 13 * CGFloat(config.textZoomPercent) / 100)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Preview").font(.system(size: 12)).foregroundStyle(.gray)
            Text("The quick brown fox jumps over the lazy dog.").font(.system(size: size)).foregroundStyle(.black)
            Text("Small print").font(.system(size: max(CGFloat(config.minimumFontPoints), 9 * CGFloat(config.textZoomPercent) / 100)))
                .foregroundStyle(.black)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16)
    }

    private var invertedPreview: some View {
        let base = VStack(alignment: .leading, spacing: 4) {
            Text("Preview").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
            Text("Black text on a white page.").foregroundStyle(.black)
            Text("A link").foregroundStyle(.blue).underline()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white)
        return Group {
            if config.inverted {
                base.colorInvert().contrast(config.contrast)
            } else {
                base
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 16)
    }

    private func slider(_ title: String, _ value: String, value binding: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 16))
                Spacer()
                Text(value).font(.system(size: 14)).foregroundStyle(palette.secondaryText)
            }
            Slider(value: Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .tint(palette.primaryColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// advanced_preferences.xml (plug-ins, text encoding, default zoom and overview
/// mode have no WKWebView equivalent; user agent replaces the debug UAString).
struct AdvancedSettingsView: View {
    @Environment(Config.self) private var config
    @Environment(BrowserModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.palette) private var palette
    @State private var pickEngine = false
    @State private var resetting = false

    var body: some View {
        @Bindable var config = config
        VStack(spacing: 0) {
            TopBar(title: "Advanced")
            ScrollView {
                VStack(spacing: 0) {
                    SettingsItem("Set search engine", value: config.engine.label) { pickEngine = true }
                    SummaryToggle(title: "Show search suggestions", summary: "Ask the search engine while you type", isOn: $config.searchSuggestions)
                    SummaryToggle(title: "Open in background", summary: "Open new tabs behind the current tab", isOn: $config.openInBackground)
                    SettingsToggle("Enable JavaScript", isOn: $config.enableJavascript)
                    SettingsItem("Website settings", value: "Advanced settings for individual websites") { router.push(.websiteSettings) }

                    Text("Page content").sectionHeader(palette)
                    SettingsToggle("Block pop-ups", isOn: $config.blockPopupWindows)
                    SummaryToggle(title: "Request desktop sites", summary: "Open new tabs with the desktop version of websites",
                                  isOn: $config.desktopUserAgent)

                    Text("Reset defaults").sectionHeader(palette)
                    SettingsItem("Reset to default", value: "Restore default settings") { resetting = true }
                }
                .padding(.bottom, 32)
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .sheet(isPresented: $pickEngine) {
            RadioDialog(title: "Set search engine", items: SearchEngine.all.map { ($0.id, $0.label) }, selected: config.searchEngine) {
                config.searchEngine = $0
            }
        }
        .alert("Reset to default", isPresented: $resetting) {
            Button("Cancel", role: .cancel) {}
            Button("OK", role: .destructive) { config.resetToDefaults() }
        } message: {
            Text("Revert settings to default values?")
        }
    }
}

/// bandwidth_preferences.xml (WKWebView has no preloading switches).
struct BandwidthSettingsView: View {
    @Environment(Config.self) private var config
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var config = config
        VStack(spacing: 0) {
            TopBar(title: "Bandwidth management")
            ScrollView {
                VStack(spacing: 0) {
                    SummaryToggle(title: "Load images", summary: "Display images on web pages", isOn: $config.loadImages)
                }
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
    }
}

/// WebsiteSettingsActivity: per-site permissions and stored data.
struct WebsiteSettingsView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var records: [SiteDataRecord] = []
    @State private var clearAll = false

    var body: some View {
        let permissions = SitePermissions.shared.decisions
        VStack(spacing: 0) {
            TopBar(title: "Website settings") {
                if !records.isEmpty || !permissions.isEmpty {
                    IconButton(icon: "trash") { clearAll = true }
                }
            }
            if records.isEmpty && permissions.isEmpty {
                Text("No websites have stored data or permissions.").foregroundStyle(palette.secondaryText)
                    .padding(32).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !permissions.isEmpty {
                            Text("Permissions").sectionHeader(palette)
                            ForEach(permissions.keys.sorted(), id: \.self) { origin in
                                let summary = PermissionKind.allCases.compactMap { kind -> String? in
                                    permissions[origin]?[kind.rawValue].map { "\(kind.title): \($0 ? "allowed" : "blocked")" }
                                }.joined(separator: ", ")
                                row(origin, summary) { SitePermissions.shared.clear(origin: origin) }
                            }
                        }
                        if !records.isEmpty {
                            Text("Stored data").sectionHeader(palette)
                            ForEach(records) { record in
                                row(record.name, Array(Set(record.kinds)).sorted().joined(separator: ", ")) {
                                    Task {
                                        await model.engine.clearSiteData(record)
                                        await reload()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .task { await reload() }
        .alert("Clear all", isPresented: $clearAll) {
            Button("Cancel", role: .cancel) {}
            Button("OK", role: .destructive) {
                SitePermissions.shared.clear()
                Task {
                    await model.engine.clearAllSiteData()
                    await reload()
                }
            }
        } message: {
            Text("Delete all website data and location permissions?")
        }
    }

    private func reload() async { records = await model.engine.siteData() }

    private func row(_ title: String, _ summary: String, clear: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).lineLimit(1)
                Text(summary).font(.system(size: 13)).foregroundStyle(palette.secondaryText)
            }
            Spacer()
            Menu {
                Button("Clear", role: .destructive, action: clear)
            } label: {
                Image(systemName: "xmark.circle").foregroundStyle(palette.secondaryText).frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
