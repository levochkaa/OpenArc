// BrowserMobileTabThumbnails.swift

import UIKit

/// Last pictures of tabs for the switcher and the bar's tab stack. Memory holds
/// the recent ones; Caches keeps JPEGs so the switcher has pictures after a relaunch.
@MainActor final class BrowserMobileTabThumbnails {
    // MARK: Internal

    static let shared = BrowserMobileTabThumbnails()
    static let didChange = Notification.Name("BrowserMobileTabThumbnailsDidChange")

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

    func store(_ image: UIImage, for tabID: String) {
        missing.remove(tabID)
        cache.setObject(image, forKey: tabID as NSString, cost: Self.cost(image))
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["tabID": tabID])
        guard let directory, let url = fileURL(tabID) else { return }
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
        workspace.snapshot(tabID: tabID, width: width) { [weak self] image in
            guard let image else { return }
            self?.store(image, for: tabID)
        }
    }

    private func fileURL(_ tabID: String) -> URL? {
        guard let directory, let name = tabID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return directory.appending(path: name + ".jpg")
    }
}
