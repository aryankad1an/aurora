import CryptoKit
import SwiftUI
import UIKit

/// A company's own logo, where it has one on file, on the same rounded square a
/// company's monogram uses — so a list of companies, some with logos and some
/// without, keeps one silhouette. Until the logo has loaded, or when there's
/// none, or it can't be fetched, the monogram stands in.
struct CompanyLogo: View {
    let name: String
    let url: URL?
    var size: CGFloat = Theme.Avatar.medium

    @State private var logo: LogoImage?

    init(name: String, url: URL?, size: CGFloat = Theme.Avatar.medium) {
        self.name = name
        self.url = url
        self.size = size
        // A logo already in memory shows on the first frame: a list scrolled
        // back up shouldn't flash monograms before its logos return.
        _logo = State(initialValue: url.flatMap(LogoCache.shared.cached))
    }

    init(job: Job, size: CGFloat = Theme.Avatar.medium) {
        self.init(name: job.company, url: job.logoLink, size: size)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    }

    var body: some View {
        ZStack {
            if let logo {
                Image(uiImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    // A transparent logo gets a little room inside its tile; a
                    // full-bleed app icon fills it.
                    .padding(logo.isTransparent ? size * 0.12 : 0)
                    .frame(width: size, height: size)
                    .background(logo.prefersDarkTile ? Color(white: 0.12) : Color.white)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
                    .transition(.opacity)
            } else {
                MonogramAvatar(company: name, size: size)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url else {
                logo = nil
                return
            }
            if let hit = LogoCache.shared.cached(url) {
                logo = hit
                return
            }
            let loaded = await LogoCache.shared.logo(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { logo = loaded }
        }
        .accessibilityHidden(true)
    }
}

/// A decoded logo, with what it needs to be drawn legibly.
struct LogoImage {
    let image: UIImage
    /// Some of it is see-through, so the tile behind it shows.
    let isTransparent: Bool
    /// A light logo on a transparent ground (a white wordmark made for a dark
    /// header), which would vanish on the usual white tile.
    let prefersDarkTile: Bool
}

/// Company logos, fetched once and kept: in memory for the session, and on disk
/// so the next launch doesn't fetch them again. A logo that fails isn't asked
/// for again until the app restarts.
final class LogoCache {
    static let shared = LogoCache()

    private let memory = NSCache<NSURL, LogoBox>()
    private var failed = Set<URL>()
    private var inFlight: [URL: Task<LogoImage?, Never>] = [:]

    private init() {
        memory.countLimit = 600
    }

    func cached(_ url: URL) -> LogoImage? {
        memory.object(forKey: url as NSURL)?.logo
    }

    func logo(for url: URL) async -> LogoImage? {
        if let hit = cached(url) { return hit }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return await running.value }
        let task = Task.detached(priority: .utility) { await Self.load(url) }
        inFlight[url] = task
        let logo = await task.value
        inFlight[url] = nil
        if let logo {
            memory.setObject(LogoBox(logo), forKey: url as NSURL)
        } else {
            failed.insert(url)
        }
        return logo
    }

    // MARK: Loading (off the main actor)

    private nonisolated static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private nonisolated static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".img")
    }

    private nonisolated static func load(_ url: URL) async -> LogoImage? {
        let file = file(for: url)
        if let data = try? Data(contentsOf: file), let logo = await decode(data) {
            return logo
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue("image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 3_000_000,
              let logo = await decode(data) else { return nil }
        try? data.write(to: file, options: .atomic)
        return logo
    }

    /// The image, shrunk to what a tile can show, and read for transparency
    /// and lightness. Nil when it isn't an image, or is too small to be one.
    private nonisolated static func decode(_ data: Data) async -> LogoImage? {
        guard let full = UIImage(data: data), min(full.size.width, full.size.height) >= 32 else { return nil }
        let side: CGFloat = 180
        let scale = min(1, side / max(full.size.width, full.size.height))
        let target = CGSize(width: (full.size.width * scale).rounded(), height: (full.size.height * scale).rounded())
        let image = await full.byPreparingThumbnail(ofSize: target) ?? full
        let (transparent, light) = tone(of: image)
        return LogoImage(image: image, isTransparent: transparent, prefersDarkTile: transparent && light)
    }

    /// Whether a fifth or more of the image is see-through, and whether what
    /// isn't is nearly white — read from a 16 × 16 copy.
    private nonisolated static func tone(of image: UIImage) -> (transparent: Bool, light: Bool) {
        guard let cg = image.cgImage else { return (false, false) }
        let n = 16
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                          bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return (false, false) }
        var clear = 0, opaque = 0
        var luminance = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            if alpha < 0.5 {
                clear += 1
                continue
            }
            opaque += 1
            // Un-premultiply, then the usual luma weights.
            let r = Double(pixels[i]) / 255 / alpha, g = Double(pixels[i + 1]) / 255 / alpha
            let b = Double(pixels[i + 2]) / 255 / alpha
            luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let transparent = clear * 5 >= n * n
        let light = opaque > 0 && luminance / Double(opaque) > 0.86
        return (transparent, light)
    }
}

/// `NSCache` holds objects; a logo is a struct.
private final class LogoBox {
    let logo: LogoImage
    init(_ logo: LogoImage) { self.logo = logo }
}

/// Finds the logo a website offers for itself, the way the import does: its
/// apple-touch-icon, a PNG `<link rel=icon>`, a web-app manifest icon, or
/// /apple-touch-icon.png — each downloaded and checked to be a real PNG, at
/// least 64 px and roughly square. What Edit Company's "Find on website" runs.
enum LogoFinder {
    private nonisolated static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    nonisolated static func find(on website: URL) async -> URL? {
        guard let (html, page) = await fetchPage(website) else {
            return await check(URL(string: "/apple-touch-icon.png", relativeTo: website)?.absoluteURL)
        }
        var candidates = iconLinks(in: html, base: page)
        if let manifest = manifestURL(in: html, base: page) {
            candidates += await manifestIcons(manifest)
        }
        candidates.append((3, 0, URL(string: "/apple-touch-icon.png", relativeTo: page)?.absoluteURL))
        var tried = Set<URL>()
        for candidate in candidates.sorted(by: { ($0.0, -$0.1) < ($1.0, -$1.1) }) {
            guard var url = candidate.2 else { continue }
            if url.scheme == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                parts.scheme = "https"
                url = parts.url ?? url
            }
            guard tried.insert(url).inserted, tried.count <= 6 else { continue }
            if let good = await check(url) { return good }
        }
        return nil
    }

    private nonisolated static func fetchPage(_ url: URL) async -> (String, URL)? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode < 400,
              data.count < 4_000_000 else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        return (html, http.url ?? url)
    }

    /// Every `<link>` tag's attributes.
    private nonisolated static func linkTags(in html: String) -> [[String: String]] {
        let tag = #/<link\b[^>]*>/#.ignoresCase()
        let attribute = #/([a-zA-Z][a-zA-Z-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/#
        return html.matches(of: tag).map { match in
            var attrs: [String: String] = [:]
            for a in String(match.output).matches(of: attribute) {
                let value = a.output.2 ?? a.output.3 ?? a.output.4 ?? ""
                attrs[String(a.output.1).lowercased()] = String(value)
            }
            return attrs
        }
    }

    private nonisolated static func iconLinks(in html: String, base: URL) -> [(Int, Int, URL?)] {
        linkTags(in: html).compactMap { attrs in
            let rel = attrs["rel"]?.lowercased() ?? ""
            guard rel.contains("icon"), !rel.contains("mask-icon"), let href = attrs["href"] else { return nil }
            let path = href.lowercased().split(separator: "?").first.map(String.init) ?? ""
            let type = attrs["type"]?.lowercased() ?? ""
            guard !path.hasSuffix(".svg"), !path.hasSuffix(".ico"), !type.contains("svg") else { return nil }
            let size = (attrs["sizes"] ?? "").split(separator: " ")
                .compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max() ?? 0
            return (rel.contains("apple-touch-icon") ? 0 : 1, size, URL(string: href, relativeTo: base)?.absoluteURL)
        }
    }

    private nonisolated static func manifestURL(in html: String, base: URL) -> URL? {
        linkTags(in: html).first { ($0["rel"]?.lowercased() ?? "").contains("manifest") }
            .flatMap { $0["href"] }
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    private nonisolated static func manifestIcons(_ url: URL) async -> [(Int, Int, URL?)] {
        struct Manifest: Decodable {
            struct Icon: Decodable { let src: String?; let sizes: String? }
            let icons: [Icon]?
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return (manifest.icons ?? []).compactMap { icon in
            guard let src = icon.src, !src.lowercased().hasSuffix(".svg") else { return nil }
            let size = (icon.sizes ?? "").split(separator: " ")
                .compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max() ?? 0
            return (2, size, URL(string: src, relativeTo: url)?.absoluteURL)
        }
    }

    /// `url` when it's a usable logo: an https PNG, at least 64 px, roughly square.
    private nonisolated static func check(_ url: URL?) async -> URL? {
        guard let url, url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 3_000_000,
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
              let image = UIImage(data: data) else { return nil }
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard min(w, h) >= 64, (0.8...1.25).contains(w / h) else { return nil }
        return url
    }
}
