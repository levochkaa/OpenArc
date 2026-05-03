import AppKit
import QuartzCore
import SwiftUI

struct AnimationCompletionObserverModifier<Value: VectorArithmetic>: AnimatableModifier {
    var targetValue: Value
    var completion: (Value) -> Void

    var animatableData: Value {
        didSet {
            notifyCompletionIfFinished()
        }
    }

    init(observedValue: Value, completion: @escaping (Value) -> Void) {
        targetValue = observedValue
        animatableData = observedValue
        self.completion = completion
    }

    func body(content: Content) -> some View {
        content
    }

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
        spaceID: String?
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

    @ViewBuilder
    func browserWindowDragGesture(isEnabled: Bool = true) -> some View {
        if isEnabled {
            contentShape(Rectangle())
                .gesture(WindowDragGesture(), including: .gesture)
                .allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}
struct BrowserSidebarAppTabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: BrowserSidebarAppTabFrame] = [:]

    static func reduce(
        value: inout [String: BrowserSidebarAppTabFrame],
        nextValue: () -> [String: BrowserSidebarAppTabFrame]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}
struct BrowserSidebarAppTabsContainerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
struct BrowserSidebarTabRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: BrowserSidebarTabRowFrame] = [:]

    static func reduce(
        value: inout [String: BrowserSidebarTabRowFrame],
        nextValue: () -> [String: BrowserSidebarTabRowFrame]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}
struct BrowserSidebarEmptySectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [BrowserSidebarEmptySectionFrame] = []

    static func reduce(
        value: inout [BrowserSidebarEmptySectionFrame],
        nextValue: () -> [BrowserSidebarEmptySectionFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}
