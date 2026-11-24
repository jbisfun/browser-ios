import Foundation

/// search/SearchEngineInfo + all_search_engines.xml, with today's engines and
/// their OpenSearch suggest endpoints (`{searchTerms}` is replaced).
struct SearchEngine: Identifiable, Hashable {
    let id: String
    let label: String
    let home: String
    let search: String
    let suggest: String?

    static let defaultID = "google"

    static let all: [SearchEngine] = [
        SearchEngine(id: "google", label: "Google", home: "https://www.google.com/",
                     search: "https://www.google.com/search?q={searchTerms}&ie=UTF-8",
                     suggest: "https://suggestqueries.google.com/complete/search?client=firefox&q={searchTerms}"),
        SearchEngine(id: "bing", label: "Bing", home: "https://www.bing.com/",
                     search: "https://www.bing.com/search?q={searchTerms}",
                     suggest: "https://api.bing.com/osjson.aspx?query={searchTerms}"),
        SearchEngine(id: "yahoo", label: "Yahoo!", home: "https://www.yahoo.com/",
                     search: "https://search.yahoo.com/search?p={searchTerms}",
                     suggest: "https://search.yahoo.com/sugg/os?command={searchTerms}&output=fxjson"),
        SearchEngine(id: "duckduckgo", label: "DuckDuckGo", home: "https://duckduckgo.com/",
                     search: "https://duckduckgo.com/?q={searchTerms}",
                     suggest: "https://duckduckgo.com/ac/?q={searchTerms}&type=list"),
        SearchEngine(id: "startpage", label: "Startpage", home: "https://www.startpage.com/",
                     search: "https://www.startpage.com/do/search?query={searchTerms}",
                     suggest: nil),
        SearchEngine(id: "ecosia", label: "Ecosia", home: "https://www.ecosia.org/",
                     search: "https://www.ecosia.org/search?q={searchTerms}",
                     suggest: "https://ac.ecosia.org/autocomplete?q={searchTerms}&type=list"),
        SearchEngine(id: "brave", label: "Brave Search", home: "https://search.brave.com/",
                     search: "https://search.brave.com/search?q={searchTerms}",
                     suggest: "https://search.brave.com/api/suggest?q={searchTerms}"),
        SearchEngine(id: "qwant", label: "Qwant", home: "https://www.qwant.com/",
                     search: "https://www.qwant.com/?q={searchTerms}",
                     suggest: nil),
        SearchEngine(id: "wikipedia", label: "Wikipedia", home: "https://www.wikipedia.org/",
                     search: "https://en.wikipedia.org/wiki/Special:Search?search={searchTerms}",
                     suggest: "https://en.wikipedia.org/w/api.php?action=opensearch&search={searchTerms}"),
    ]

    static func find(_ id: String) -> SearchEngine { all.first { $0.id == id } ?? all[0] }

    func searchURL(_ query: String) -> URL? {
        URL(string: search.replacingOccurrences(of: "{searchTerms}", with: Self.encode(query)))
    }

    /// OpenSearchSearchEngine.getSuggestions: `["query", ["s1", "s2", ...]]`.
    func suggestions(for query: String) async -> [String] {
        guard let suggest, !query.isEmpty,
              let url = URL(string: suggest.replacingOccurrences(of: "{searchTerms}", with: Self.encode(query))) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let array = json as? [Any], array.count > 1, let list = array[1] as? [Any] {
            return list.compactMap { $0 as? String }.prefix(5).map { $0 }
        }
        return []
    }

    /// True when `url` is this engine's result page; returns the query (for the url bar).
    func query(from url: URL) -> String? {
        guard let base = URL(string: search), base.host == url.host, base.path == url.path,
              let key = URLComponents(string: search)?.queryItems?.first(where: { $0.value == "{searchTerms}" })?.name
        else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// UrlUtils.smartUrlFilter / fixUrl: turns what was typed into a URL, or nil for a search.
enum UrlUtils {
    static func smartUrl(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("file:") || lower.hasPrefix("data:") || lower.hasPrefix("javascript:") {
            return URL(string: text)
        }
        if text.contains(" ") { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "mailto", "tel", "sms"].contains(scheme) {
            return url
        }
        // ACCEPTED_URI_SCHEMA: host[:port][/path] with a dot, localhost or an IP.
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let looksLikeHost = host == "localhost" || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
            && host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil)
        return looksLikeHost ? URL(string: "http://" + text) : nil
    }

    /// UrlUtils.stripUrl: the url as shown in suggestions and lists.
    static func strip(_ url: String) -> String {
        var s = url
        for prefix in ["http://", "https://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
