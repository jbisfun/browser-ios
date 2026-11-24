import FossifyCommons
import Observation
import SwiftUI

/// Port of BrowserSettings (SharedPreferences -> a UserDefaults suite, so the
/// keys never collide with the other apps sharing the launcher's process).
/// Colors and the app font size live in FossifyCommons.BaseConfig.
@MainActor
@Observable
final class Config {
    static let shared = Config()

    @ObservationIgnored private let d = UserDefaults(suiteName: "org.fossify.browser") ?? .standard

    // General
    var homepage: String { didSet { d.set(homepage, forKey: "homepage") } }

    // Privacy & security
    var showSecurityWarnings: Bool { didSet { d.set(showSecurityWarnings, forKey: "show_security_warnings") } }
    var acceptCookies: Bool { didSet { d.set(acceptCookies, forKey: "accept_cookies") } }
    var enableGeolocation: Bool { didSet { d.set(enableGeolocation, forKey: "enable_geolocation") } }

    // Accessibility
    var forceUserScalable: Bool { didSet { d.set(forceUserScalable, forKey: "force_userscalable") } }
    /// Raw seek bar value like AOSP (0...30, 10 = 100 %).
    var textZoom: Int { didSet { d.set(textZoom, forKey: "text_zoom") } }
    /// Raw seek bar value like AOSP (0...20, 0 = off).
    var minFontSize: Int { didSet { d.set(minFontSize, forKey: "min_font_size") } }
    var inverted: Bool { didSet { d.set(inverted, forKey: "inverted") } }
    /// Raw seek bar value like AOSP (0...30 -> contrast 1.0...4.0).
    var invertedContrast: Int { didSet { d.set(invertedContrast, forKey: "inverted_contrast") } }

    // Advanced
    var searchEngine: String { didSet { d.set(searchEngine, forKey: "search_engine") } }
    var openInBackground: Bool { didSet { d.set(openInBackground, forKey: "open_in_background") } }
    var enableJavascript: Bool { didSet { d.set(enableJavascript, forKey: "enable_javascript") } }
    var blockPopupWindows: Bool { didSet { d.set(blockPopupWindows, forKey: "block_popup_windows") } }
    var desktopUserAgent: Bool { didSet { d.set(desktopUserAgent, forKey: "desktop_user_agent") } }

    // Bandwidth management
    var loadImages: Bool { didSet { d.set(loadImages, forKey: "load_images") } }
    var searchSuggestions: Bool { didSet { d.set(searchSuggestions, forKey: "search_suggestions") } }

    private init() {
        homepage = d.string(forKey: "homepage") ?? Homepage.defaultPage
        showSecurityWarnings = d.object(forKey: "show_security_warnings") as? Bool ?? true
        acceptCookies = d.object(forKey: "accept_cookies") as? Bool ?? true
        enableGeolocation = d.object(forKey: "enable_geolocation") as? Bool ?? true
        forceUserScalable = d.object(forKey: "force_userscalable") as? Bool ?? false
        textZoom = d.object(forKey: "text_zoom") as? Int ?? 10
        minFontSize = d.object(forKey: "min_font_size") as? Int ?? 0
        inverted = d.object(forKey: "inverted") as? Bool ?? false
        invertedContrast = d.object(forKey: "inverted_contrast") as? Int ?? 0
        searchEngine = d.string(forKey: "search_engine") ?? SearchEngine.defaultID
        openInBackground = d.object(forKey: "open_in_background") as? Bool ?? false
        enableJavascript = d.object(forKey: "enable_javascript") as? Bool ?? true
        blockPopupWindows = d.object(forKey: "block_popup_windows") as? Bool ?? true
        desktopUserAgent = d.object(forKey: "desktop_user_agent") as? Bool ?? false
        loadImages = d.object(forKey: "load_images") as? Bool ?? true
        searchSuggestions = d.object(forKey: "search_suggestions") as? Bool ?? true
    }

    /// "Reset to default" (reset_default_preferences).
    func resetToDefaults() {
        for key in d.dictionaryRepresentation().keys { d.removeObject(forKey: key) }
        homepage = Homepage.defaultPage
        showSecurityWarnings = true
        acceptCookies = true
        enableGeolocation = true
        forceUserScalable = false
        textZoom = 10
        minFontSize = 0
        inverted = false
        invertedContrast = 0
        searchEngine = SearchEngine.defaultID
        openInBackground = false
        enableJavascript = true
        blockPopupWindows = true
        desktopUserAgent = false
        loadImages = true
        searchSuggestions = true
    }

    // BrowserSettings.getAdjustedTextZoom / getAdjustedMinimumFontSize
    var textZoomPercent: Int { 100 + (textZoom - 10) * 5 }
    var minimumFontPoints: Int { minFontSize > 0 ? minFontSize + 3 : 0 }
    var contrast: Double { 1 + Double(invertedContrast) / 10 }

    var engine: SearchEngine { SearchEngine.find(searchEngine) }

    /// Everything a page needs to apply the settings.
    var pageSettings: PageSettings {
        PageSettings(javascript: enableJavascript, blockPopups: blockPopupWindows, loadImages: loadImages,
                     acceptCookies: acceptCookies, textZoomPercent: textZoomPercent, minimumFontSize: minimumFontPoints,
                     forceUserScalable: forceUserScalable, inverted: inverted, contrast: contrast,
                     geolocation: enableGeolocation, securityWarnings: showSecurityWarnings)
    }
}

/// The homepage choices of HomepagePreference.
enum Homepage {
    static let mostVisited = "browser://most-visited"
    static let blank = "about:blank"
    /// "Default page": the search engine's start page (AOSP used Google's).
    static let defaultPage = "about:default"
}
