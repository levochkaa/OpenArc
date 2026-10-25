// BrowserTooltipCoordinator.swift

import Combine
import Foundation

// MARK: - BrowserTooltipPlacement

enum BrowserTooltipPlacement {
    case belowLeading
    case aboveCapsule
}

// MARK: - BrowserTooltipPlacementResolver

enum BrowserTooltipPlacementResolver {
    // MARK: Internal

    static let defaultViewportPadding: CGFloat = 8

    static func topLeft(
        sourceFrame: CGRect,
        tooltipSize: CGSize,
        containerSize: CGSize,
        placement: BrowserTooltipPlacement,
        verticalGap: CGFloat = 8,
        anchorXFraction: CGFloat = 0.75,
        anchorYFraction: CGFloat = 0.75,
        viewportPadding: CGFloat = defaultViewportPadding,
    ) -> CGPoint {
        let proposedTopLeft = proposedTopLeft(
            sourceFrame: sourceFrame,
            tooltipSize: tooltipSize,
            placement: placement,
            verticalGap: verticalGap,
            anchorXFraction: anchorXFraction,
            anchorYFraction: anchorYFraction,
        )

        return CGPoint(
            x: clamped(
                proposedTopLeft.x,
                minimum: viewportPadding,
                maximum: max(viewportPadding, containerSize.width - tooltipSize.width - viewportPadding),
            ),
            y: clamped(
                proposedTopLeft.y,
                minimum: viewportPadding,
                maximum: max(viewportPadding, containerSize.height - tooltipSize.height - viewportPadding),
            ),
        )
    }

    // MARK: Private

    private static func proposedTopLeft(
        sourceFrame: CGRect,
        tooltipSize: CGSize,
        placement: BrowserTooltipPlacement,
        verticalGap: CGFloat,
        anchorXFraction: CGFloat,
        anchorYFraction: CGFloat,
    ) -> CGPoint {
        switch placement {
        case .belowLeading:
            CGPoint(
                x: sourceFrame.minX + sourceFrame.width * anchorXFraction,
                y: sourceFrame.minY + sourceFrame.height * anchorYFraction,
            )
        case .aboveCapsule:
            CGPoint(
                x: sourceFrame.midX - tooltipSize.width / 2,
                y: sourceFrame.minY - verticalGap - tooltipSize.height,
            )
        }
    }

    private static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

// MARK: - BrowserTooltipOverlayViewport

struct BrowserTooltipOverlayViewport: Equatable {
    let size: CGSize
    let sourceFrameOffset: CGPoint
}

// MARK: - BrowserTooltipOverlayViewportResolver

enum BrowserTooltipOverlayViewportResolver {
    static func viewport(
        windowSize: CGSize,
        windowScreenFrame: CGRect?,
        screenVisibleFrame: CGRect?,
        isWindowFullscreen: Bool,
    ) -> BrowserTooltipOverlayViewport {
        guard !isWindowFullscreen,
              let windowScreenFrame,
              let screenVisibleFrame,
              !screenVisibleFrame.isEmpty
        else {
            return BrowserTooltipOverlayViewport(size: windowSize, sourceFrameOffset: .zero)
        }

        return BrowserTooltipOverlayViewport(
            size: screenVisibleFrame.size,
            sourceFrameOffset: CGPoint(
                x: windowScreenFrame.minX - screenVisibleFrame.minX,
                y: screenVisibleFrame.maxY - windowScreenFrame.maxY,
            ),
        )
    }
}

// MARK: - BrowserTooltipMeasuredSizeResolver

enum BrowserTooltipMeasuredSizeResolver {
    static func resolvedSize(
        idealSize: CGSize,
        constrainedSize: CGSize,
        maximumWidth: CGFloat,
    ) -> CGSize {
        guard maximumWidth > 0 else {
            return .zero
        }

        guard idealSize.width > maximumWidth else {
            return idealSize
        }

        return CGSize(
            width: min(constrainedSize.width, maximumWidth),
            height: constrainedSize.height,
        )
    }
}

// MARK: - BrowserTooltipCoordinator

@MainActor final class BrowserTooltipCoordinator: ObservableObject {
    // MARK: Internal

    @Published private(set) var activeTooltipID: UUID?

    // MARK: Private

    private let activationDelayNanoseconds: UInt64
    private let cooldownDelayNanoseconds: UInt64

    private var hoveredTooltipID: UUID?
    private var isWarm = false
    private var activationTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?

    init(
        activationDelayNanoseconds: UInt64 = 1_000_000_000,
        cooldownDelayNanoseconds: UInt64 = 300_000_000,
    ) {
        self.activationDelayNanoseconds = activationDelayNanoseconds
        self.cooldownDelayNanoseconds = cooldownDelayNanoseconds
    }

    deinit {
        activationTask?.cancel()
        cooldownTask?.cancel()
    }

    func setHovering(_ isHovering: Bool, for tooltipID: UUID) {
        if isHovering {
            beginHover(for: tooltipID)
        } else {
            endHover(for: tooltipID)
        }
    }

    private func beginHover(for tooltipID: UUID) {
        cooldownTask?.cancel()
        cooldownTask = nil
        hoveredTooltipID = tooltipID

        if isWarm {
            activationTask?.cancel()
            activationTask = nil
            activeTooltipID = tooltipID
            return
        }

        guard activeTooltipID != tooltipID else {
            return
        }

        activationTask?.cancel()
        activationTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(nanoseconds: activationDelayNanoseconds)
            } catch {
                return
            }

            activateTooltipIfStillHovered(tooltipID)
        }
    }

    private func endHover(for tooltipID: UUID) {
        guard hoveredTooltipID == tooltipID else { return }
        hoveredTooltipID = nil

        activationTask?.cancel()
        activationTask = nil

        guard hoveredTooltipID == nil else {
            return
        }

        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(nanoseconds: cooldownDelayNanoseconds)
            } catch {
                return
            }

            resetIfNoTooltipIsHovered()
        }
    }

    private func activateTooltipIfStillHovered(_ tooltipID: UUID) {
        guard hoveredTooltipID == tooltipID else {
            return
        }

        activeTooltipID = tooltipID
        isWarm = true
    }

    private func resetIfNoTooltipIsHovered() {
        guard hoveredTooltipID == nil else {
            return
        }

        activeTooltipID = nil
        isWarm = false
    }
}
