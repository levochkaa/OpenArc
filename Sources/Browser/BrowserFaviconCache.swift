import AppKit
import Foundation

@MainActor final class BrowserFaviconCache: ObservableObject {
    // MARK: Lifecycle

    init(dataLoader: DataLoader? = nil) {
        self.dataLoader = dataLoader ?? { url in
            await BrowserFaviconCache.loadData(from: url)
        }
    }

    // MARK: Internal

    typealias DataLoader = @Sendable (URL) async -> Data?

    static let shared = BrowserFaviconCache()

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

    // MARK: Private

    @Published private var imagesByURL = [URL: NSImage]()

    private let dataLoader: DataLoader
    private var failedURLs = Set<URL>()
    private var loadTasks = [URL: Task<Data?, Never>]()

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

    private func storeLoadedImageData(_ data: Data?, for url: URL) {
        guard imagesByURL[url] == nil else {
            return
        }

        guard
            let data,
            let image = BrowserImageThumbnailer.image(
                data: data,
                maximumPixelSize: BrowserImageThumbnailer.chromeIconMaximumPixelSize
            )
        else {
            failedURLs.insert(url)
            return
        }

        store(image, for: url)
    }
}
