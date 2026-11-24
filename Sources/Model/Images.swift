import Foundation
import Observation
import SwiftUI
import UIKit

/// Page thumbnails (the history provider's "thumbnail" column), JPEGs in Caches.
enum Thumbnails {
    static func file(_ url: String) -> URL {
        BrowserFiles.cacheDir("thumbs").appendingPathComponent(BrowserFiles.key(url) + ".jpg")
    }

    static func file(key: String) -> URL {
        BrowserFiles.cacheDir("thumbs").appendingPathComponent(key + ".jpg")
    }

    static func exists(_ url: String) -> Bool { FileManager.default.fileExists(atPath: file(url).path) }

    static func save(_ image: UIImage, for url: String) {
        guard let data = image.jpegData(compressionQuality: 0.6) else { return }
        try? data.write(to: file(url), options: .atomic)
    }

    static func image(_ url: String) -> UIImage? { UIImage(contentsOfFile: file(url).path) }

    static func clear() { try? FileManager.default.removeItem(at: BrowserFiles.cacheDir("thumbs")) }
}

/// Favicons (the "favicon" column / DownloadTouchIcon): icon url per host, images cached on disk.
@MainActor
@Observable
final class Favicons {
    static let shared = Favicons()

    private var icons: [String: String]
    @ObservationIgnored private var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    private(set) var revision = 0

    private init() {
        icons = BrowserFiles.load([String: String].self, "favicons.json") ?? [:]
    }

    func remember(_ icon: URL, for page: URL) {
        guard let host = page.host, icons[host] != icon.absoluteString else { return }
        icons[host] = icon.absoluteString
        images[host] = nil
        try? FileManager.default.removeItem(at: file(host))
        BrowserFiles.save(icons, "favicons.json")
    }

    private func file(_ host: String) -> URL {
        BrowserFiles.cacheDir("favicons").appendingPathComponent(BrowserFiles.key(host) + ".png")
    }

    func image(for pageURL: String) -> UIImage? {
        guard let url = URL(string: pageURL), let host = url.host else { return nil }
        _ = revision
        if let image = images[host] { return image }
        if let image = UIImage(contentsOfFile: file(host).path) {
            images[host] = image
            return image
        }
        fetch(host: host, scheme: url.scheme ?? "https")
        return nil
    }

    private func fetch(host: String, scheme: String) {
        guard !loading.contains(host), scheme == "http" || scheme == "https" else { return }
        loading.insert(host)
        let source = URL(string: icons[host] ?? "\(scheme)://\(host)/favicon.ico")
        Task {
            defer { loading.remove(host) }
            guard let source, let (data, response) = try? await URLSession.shared.data(from: source),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = UIImage(data: data), let png = image.pngData() else { return }
            try? png.write(to: file(host), options: .atomic)
            images[host] = image
            revision += 1
        }
    }
}

/// A site's favicon or the globe placeholder.
struct FaviconView: View {
    @Environment(\.palette) private var palette
    let url: String
    var size: CGFloat = 20

    var body: some View {
        if let image = Favicons.shared.image(for: url) {
            Image(uiImage: image).resizable().interpolation(.medium).scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "globe").font(.system(size: size * 0.85)).foregroundStyle(palette.secondaryText)
                .frame(width: size, height: size)
        }
    }
}
