// BrowserMobileTabThumbnails.swift

import UIKit

/// Last pictures of tabs for the switcher and the bar's tab stack. Memory holds
/// the recent ones; Caches keeps JPEGs so the switcher has pictures after a relaunch.
@MainActor final class BrowserMobileTabThumbnails {
    // MARK: Internal

    static let shared = BrowserMobileTabThumbnails()
    static let didChange = Notification.Name("BrowserMobileTabThumbnailsDidChange")

    /// The status bar's height over the screen's width: pages lie below it,
    /// and pictures of them get its place back on top.
    var statusBarShare: CGFloat = 0

    // MARK: Private

    private let cache = NSCache<NSString, UIImage>()

    private let directory: URL?
    private var missing = Set<String>()

    init(
        directory: URL? = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appending(path: "TabThumbnails", directoryHint: .isDirectory),
    ) {
        self.directory = directory
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    /// Gives a picture of a page that starts below the status bar the status
    /// bar's place above it again, filled with the page's top edge, so every
    /// picture covers the whole screen.
    static func padTop(_ image: UIImage, by height: CGFloat) -> UIImage {
        let height = (height * image.scale).rounded() / image.scale
        guard height > 0, let cgImage = image.cgImage,
              let edge = cgImage.cropping(to: CGRect(x: 0, y: 0, width: cgImage.width, height: 1))
        else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let size = CGSize(width: image.size.width, height: image.size.height + height)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: edge, scale: image.scale, orientation: .up)
                .draw(in: CGRect(x: 0, y: 0, width: size.width, height: height))
            image.draw(at: CGPoint(x: 0, y: height))
        }
    }

    // MARK: Private

    private static func cost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    // MARK: Internal

    func image(for tabID: String) -> UIImage? {
        if let image = cache.object(forKey: tabID as NSString) { return image }
        guard !missing.contains(tabID), let url = fileURL(tabID),
              let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: 3)
        else {
            missing.insert(tabID)
            return nil
        }
        cache.setObject(image, forKey: tabID as NSString, cost: Self.cost(image))
        return image
    }

    /// Keeps the picture; `persist` also writes it to Caches, which a
    /// private tab's picture never is.
    func store(_ image: UIImage, for tabID: String, persist: Bool = true) {
        missing.remove(tabID)
        cache.setObject(image, forKey: tabID as NSString, cost: Self.cost(image))
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["tabID": tabID])
        guard persist, let directory, let url = fileURL(tabID) else { return }
        Task.detached(priority: .utility) {
            guard let data = image.jpegData(compressionQuality: 0.7) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func remove(_ tabID: String) {
        cache.removeObject(forKey: tabID as NSString)
        missing.insert(tabID)
        if let url = fileURL(tabID) { try? FileManager.default.removeItem(at: url) }
    }

    /// Captures the tab's page as it draws now.
    func capture(_ tabID: String, workspace: BrowserMobileWorkspace, width: CGFloat) {
        let persist = workspace.tabs.first { $0.id == tabID }?.isPrivate != true
        let statusBarShare = statusBarShare
        workspace.snapshot(tabID: tabID, width: width) { [weak self] image in
            guard let image else { return }
            self?.store(Self.padTop(image, by: image.size.width * statusBarShare), for: tabID, persist: persist)
        }
    }

    private func fileURL(_ tabID: String) -> URL? {
        guard let directory, let name = tabID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return directory.appending(path: name + ".jpg")
    }
}
