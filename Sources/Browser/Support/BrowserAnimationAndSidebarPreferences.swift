import AppKit
import QuartzCore
import SwiftUI

// MARK: - AnimationCompletionObserverModifier

struct AnimationCompletionObserverModifier<Value: VectorArithmetic>: @MainActor AnimatableModifier {
    // MARK: Lifecycle

    init(observedValue: Value, completion: @escaping (Value) -> Void) {
        self.targetValue = observedValue
        self.animatableData = observedValue
        self.completion = completion
    }

    // MARK: Internal

    var targetValue: Value
    var completion: (Value) -> Void

    var animatableData: Value {
        didSet {
            notifyCompletionIfFinished()
        }
    }

    func body(content: Content) -> some View {
        content
    }

    // MARK: Private

    private func notifyCompletionIfFinished() {
        guard animatableData == targetValue else {
            return
        }

        DispatchQueue.main.async {
            completion(targetValue)
        }
    }
}

extension View {
    func onAnimationCompleted<Value: VectorArithmetic>(
        for value: Value,
        perform completion: @escaping (Value) -> Void
    ) -> some View {
        modifier(AnimationCompletionObserverModifier(observedValue: value, completion: completion))
    }

    func browserSidebarTabRowFrame(
        tabID: String,
        section: BrowserSidebarTabSection,
        sectionIndex: Int,
        spaceID: String?,
        pinnedFolderID: String? = nil,
        folderChildIndex: Int? = nil
    ) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarTabRowFramePreferenceKey.self,
                    value: [
                        tabID: BrowserSidebarTabRowFrame(
                            tabID: tabID,
                            section: section,
                            sectionIndex: sectionIndex,
                            spaceID: spaceID,
                            pinnedFolderID: pinnedFolderID,
                            folderChildIndex: folderChildIndex,
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    func browserSidebarAppTabFrame(
        tabID: String,
        sectionIndex: Int
    ) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarAppTabFramePreferenceKey.self,
                    value: [
                        tabID: BrowserSidebarAppTabFrame(
                            tabID: tabID,
                            sectionIndex: sectionIndex,
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    func browserSidebarAppTabsContainerFrame() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarAppTabsContainerFramePreferenceKey.self,
                    value: proxy.frame(
                        in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                    )
                )
            }
        }
    }

    func browserSidebarEmptySectionFrame(section: BrowserSidebarTabSection, spaceID: String?) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarEmptySectionFramePreferenceKey.self,
                    value: [
                        BrowserSidebarEmptySectionFrame(
                            section: section,
                            spaceID: spaceID,
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    func browserSidebarPinnedFolderRowFrame(
        folderID: String,
        firstSectionIndex: Int,
        afterSectionIndex: Int,
        childCount: Int,
        spaceID: String?,
        childHorizontalInset: CGFloat
    ) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(
                    in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                )
                Color.clear.preference(
                    key: BrowserSidebarPinnedFolderRowFramePreferenceKey.self,
                    value: [
                        BrowserSidebarPinnedFolderRowFrame(
                            folderID: folderID,
                            firstSectionIndex: firstSectionIndex,
                            afterSectionIndex: afterSectionIndex,
                            childCount: childCount,
                            spaceID: spaceID,
                            frame: frame,
                            childPreviewFrame: CGRect(
                                x: frame.minX + childHorizontalInset,
                                y: frame.minY,
                                width: max(frame.width - childHorizontalInset, 0),
                                height: frame.height
                            )
                        ),
                    ]
                )
            }
        }
    }

    func browserSidebarSpaceHeaderFrame(spaceID: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserSidebarSpaceHeaderFramePreferenceKey.self,
                    value: [
                        BrowserSidebarSpaceHeaderFrame(
                            spaceID: spaceID,
                            frame: proxy.frame(
                                in: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
                            )
                        ),
                    ]
                )
            }
        }
    }

    @ViewBuilder func browserWindowDragGesture(isEnabled: Bool = true) -> some View {
        if isEnabled {
            contentShape(Rectangle())
                .gesture(WindowDragGesture(), including: .gesture)
                .allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}

// MARK: - BrowserSidebarAppTabFramePreferenceKey

struct BrowserSidebarAppTabFramePreferenceKey: PreferenceKey {
    static let defaultValue = [String: BrowserSidebarAppTabFrame]()

    static func reduce(
        value: inout [String: BrowserSidebarAppTabFrame],
        nextValue: () -> [String: BrowserSidebarAppTabFrame]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

// MARK: - BrowserSidebarAppTabsContainerFramePreferenceKey

struct BrowserSidebarAppTabsContainerFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

// MARK: - BrowserSidebarTabRowFramePreferenceKey

struct BrowserSidebarTabRowFramePreferenceKey: PreferenceKey {
    static let defaultValue = [String: BrowserSidebarTabRowFrame]()

    static func reduce(
        value: inout [String: BrowserSidebarTabRowFrame],
        nextValue: () -> [String: BrowserSidebarTabRowFrame]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

// MARK: - BrowserSidebarEmptySectionFramePreferenceKey

struct BrowserSidebarEmptySectionFramePreferenceKey: PreferenceKey {
    static let defaultValue = [BrowserSidebarEmptySectionFrame]()

    static func reduce(
        value: inout [BrowserSidebarEmptySectionFrame],
        nextValue: () -> [BrowserSidebarEmptySectionFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - BrowserSidebarPinnedFolderRowFramePreferenceKey

struct BrowserSidebarPinnedFolderRowFramePreferenceKey: PreferenceKey {
    static let defaultValue = [BrowserSidebarPinnedFolderRowFrame]()

    static func reduce(
        value: inout [BrowserSidebarPinnedFolderRowFrame],
        nextValue: () -> [BrowserSidebarPinnedFolderRowFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - BrowserSidebarSpaceHeaderFramePreferenceKey

struct BrowserSidebarSpaceHeaderFramePreferenceKey: PreferenceKey {
    static let defaultValue = [BrowserSidebarSpaceHeaderFrame]()

    static func reduce(
        value: inout [BrowserSidebarSpaceHeaderFrame],
        nextValue: () -> [BrowserSidebarSpaceHeaderFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}
