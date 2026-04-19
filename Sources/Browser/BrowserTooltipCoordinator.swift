import Foundation
import SwiftUI

@MainActor
final class BrowserTooltipCoordinator: ObservableObject {
    @Published private(set) var activeTooltipID: UUID?

    private let activationDelayNanoseconds: UInt64
    private let cooldownDelayNanoseconds: UInt64

    private var hoveredTooltipID: UUID?
    private var isWarm = false
    private var activationTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?

    init(
        activationDelayNanoseconds: UInt64 = 1_000_000_000,
        cooldownDelayNanoseconds: UInt64 = 300_000_000
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
                try await Task.sleep(nanoseconds: self.activationDelayNanoseconds)
            } catch {
                return
            }

            self.activateTooltipIfStillHovered(tooltipID)
        }
    }

    private func endHover(for tooltipID: UUID) {
        if hoveredTooltipID == tooltipID {
            hoveredTooltipID = nil
        }

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
                try await Task.sleep(nanoseconds: self.cooldownDelayNanoseconds)
            } catch {
                return
            }

            self.resetIfNoTooltipIsHovered()
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
