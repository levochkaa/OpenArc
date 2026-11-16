// BrowserFaviconCache.swift

import AppKit
import Foundation

@MainActor final class BrowserFaviconCache: ObservableObject {
    // MARK: Internal

    typealias DataLoader = @Sendable (URL) async -> Data?

    static let shared = BrowserFaviconCache()

    private nonisolated static let pageIconScheme = "openarc-page-icon"

    /// The icon a page showed last, as the browser recorded it. Pages it has no
    /// record of fall back to a favicon service.
    var pageIconProvider: (String) -> Data? = { _ in nil }

    // MARK: Private

    @Published private var imagesByURL = [URL: NSImage]()

    private let dataLoader: DataLoader
    private var failedURLs = Set<URL>()
    private var loadTasks = [URL: Task<Data?, Never>]()

    init(dataLoader: DataLoader? = nil) {
        self.dataLoader = dataLoader ?? { url in
            await BrowserFaviconCache.loadData(from: url)
        }
    }

    /// Stands for the recorded icon of a page whose own icon address is unknown,
    /// such as an unloaded tab after a restart.
    nonisolated static func pageIconURL(forPageURLString urlString: String) -> URL? {
        guard !urlString.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = pageIconScheme
        components.path = "icon"
        components.queryItems = [URLQueryItem(name: "page", value: urlString)]
        return components.url
    }

    nonisolated static func pageURLString(forPageIconURL url: URL) -> String? {
        guard url.scheme == pageIconScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "page" }?
            .value
    }

    private nonisolated static func loadData(from url: URL) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if
                let httpResponse = response as? HTTPURLResponse,
                !(200...299).contains(httpResponse.statusCode)
            {
                return nil
            }

            return data
        } catch {
            return nil
        }
    }

    private nonisolated static func serviceIconURL(forPageURLString urlString: String) -> URL? {
        guard let encodedURL = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "https://www.google.com/s2/favicons?sz=64&domain_url=\(encodedURL)")
    }

    func image(for url: URL?) -> NSImage? {
        guard let url else {
            return nil
        }

        return imagesByURL[url]
    }

    func store(_ image: NSImage, for url: URL) {
        imagesByURL[url] = image
        failedURLs.remove(url)
    }

    func loadImageIfNeeded(from url: URL?) async {
        guard
            let url,
            imagesByURL[url] == nil,
            !failedURLs.contains(url)
        else {
            return
        }

        if let pageURLString = Self.pageURLString(forPageIconURL: url) {
            if let data = pageIconProvider(pageURLString) {
                storeLoadedImageData(data, for: url)
                return
            }
            guard let serviceURL = Self.serviceIconURL(forPageURLString: pageURLString) else {
                failedURLs.insert(url)
                return
            }
            let data = await dataLoader(serviceURL)
            storeLoadedImageData(data, for: url)
            return
        }

        if let loadTask = loadTasks[url] {
            let data = await loadTask.value
            storeLoadedImageData(data, for: url)
            return
        }

        let loadTask = Task<Data?, Never> {
            await dataLoader(url)
        }
        loadTasks[url] = loadTask

        let data = await loadTask.value
        loadTasks[url] = nil

        storeLoadedImageData(data, for: url)
    }

    private func storeLoadedImageData(_ data: Data?, for url: URL) {
        guard imagesByURL[url] == nil else {
            return
        }

        guard
            let data,
            let image = BrowserImageThumbnailer.image(
                data: data,
                maximumPixelSize: BrowserImageThumbnailer.chromeIconMaximumPixelSize,
            )
        else {
            failedURLs.insert(url)
            return
        }

        store(image, for: url)
    }
}
