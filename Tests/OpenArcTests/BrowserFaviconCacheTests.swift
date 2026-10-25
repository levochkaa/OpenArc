import AppKit
import Foundation
import Testing

@Test
@MainActor func faviconCacheReturnsStoredImageSynchronously() throws {
    let cache = BrowserFaviconCache(dataLoader: { _ in nil })
    let url = try #require(URL(string: "https://example.com/favicon.ico"))
    let image = NSImage(size: NSSize(width: 16, height: 16))

    #expect(cache.image(for: url) == nil)

    cache.store(image, for: url)

    let cachedImage = try #require(cache.image(for: url))
    #expect(cachedImage === image)
}

@Test
@MainActor func faviconCacheLoadsImageDataOnDemand() async throws {
    let url = try #require(URL(string: "https://example.com/favicon.ico"))
    let imageData = try #require(makeTestFaviconImage().tiffRepresentation)
    let cache = BrowserFaviconCache(dataLoader: { requestedURL in
        requestedURL == url ? imageData : nil
    })

    await cache.loadImageIfNeeded(from: url)

    #expect(cache.image(for: url) != nil)
}

@Test
@MainActor func faviconCacheCoalescesConcurrentLoadsForSameURL() async throws {
    let url = try #require(URL(string: "https://example.com/favicon.ico"))
    let imageData = try #require(makeTestFaviconImage().tiffRepresentation)
    let dataLoader = BlockingFaviconDataLoader(data: imageData)
    let cache = BrowserFaviconCache(dataLoader: { requestedURL in
        await dataLoader.load(requestedURL)
    })

    let firstLoad = Task { @MainActor in
        await cache.loadImageIfNeeded(from: url)
        return cache.image(for: url) != nil
    }

    await dataLoader.waitForCallCount(1)
    #expect(await dataLoader.callCount() == 1)

    let releaseLoad = Task { @MainActor in
        await dataLoader.release()
    }
    await cache.loadImageIfNeeded(from: url)
    let secondCallerObservedCachedImage = cache.image(for: url) != nil
    let firstCallerObservedCachedImage = await firstLoad.value
    await releaseLoad.value

    #expect(firstCallerObservedCachedImage)
    #expect(secondCallerObservedCachedImage)
    #expect(await dataLoader.callCount() == 1)
    #expect(await dataLoader.loadedURLs() == [url])
}

private func makeTestFaviconImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 16, height: 16).fill()
    image.unlockFocus()
    return image
}

// MARK: - BlockingFaviconDataLoader

private actor BlockingFaviconDataLoader {
    // MARK: Lifecycle

    init(data: Data) {
        self.data = data
    }

    // MARK: Internal

    func load(_ url: URL) async -> Data? {
        requestedURLs.append(url)
        resumeInvocationWaiters()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        return data
    }

    func waitForCallCount(_ expectedCallCount: Int) async {
        guard requestedURLs.count < expectedCallCount else {
            return
        }

        await withCheckedContinuation { continuation in
            invocationWaiters.append((expectedCallCount, continuation))
        }
    }

    func callCount() -> Int {
        requestedURLs.count
    }

    func loadedURLs() -> [URL] {
        requestedURLs
    }

    func release() {
        guard !isReleased else {
            return
        }

        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: Private

    private let data: Data
    private var invocationWaiters = [(Int, CheckedContinuation<Void, Never>)]()
    private var isReleased = false
    private var requestedURLs = [URL]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    private func resumeInvocationWaiters() {
        let waiters = invocationWaiters
        invocationWaiters.removeAll()

        for waiter in waiters {
            if requestedURLs.count >= waiter.0 {
                waiter.1.resume()
            } else {
                invocationWaiters.append(waiter)
            }
        }
    }
}
