// BrowserTooltipCoordinatorTests.swift

import Foundation
import Testing

@Test func tooltipPlacementClampsBelowLeadingTooltipInsideTrailingEdge() {
    let topLeft = BrowserTooltipPlacementResolver.topLeft(
        sourceFrame: CGRect(x: 280, y: 40, width: 40, height: 24),
        tooltipSize: CGSize(width: 140, height: 40),
        containerSize: CGSize(width: 320, height: 200),
        placement: .belowLeading,
        viewportPadding: 8,
    )

    #expect(topLeft.x == 172)
    #expect(topLeft.y == 58)
}

@Test func tooltipPlacementClampsBelowLeadingTooltipInsideLeadingEdge() {
    let topLeft = BrowserTooltipPlacementResolver.topLeft(
        sourceFrame: CGRect(x: -80, y: 40, width: 40, height: 24),
        tooltipSize: CGSize(width: 140, height: 40),
        containerSize: CGSize(width: 320, height: 200),
        placement: .belowLeading,
        viewportPadding: 8,
    )

    #expect(topLeft.x == 8)
    #expect(topLeft.y == 58)
}

@Test func tooltipPlacementClampsAboveCapsuleTooltipInsideTopEdge() {
    let topLeft = BrowserTooltipPlacementResolver.topLeft(
        sourceFrame: CGRect(x: 120, y: 6, width: 40, height: 24),
        tooltipSize: CGSize(width: 120, height: 40),
        containerSize: CGSize(width: 320, height: 200),
        placement: .aboveCapsule,
        verticalGap: 8,
        viewportPadding: 8,
    )

    #expect(topLeft.x == 80)
    #expect(topLeft.y == 8)
}

@Test func tooltipOverlayViewportUsesVisibleScreenBoundsOutsideFullscreen() {
    let viewport = BrowserTooltipOverlayViewportResolver.viewport(
        windowSize: CGSize(width: 800, height: 600),
        windowScreenFrame: CGRect(x: 520, y: 120, width: 800, height: 600),
        screenVisibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        isWindowFullscreen: false,
    )

    #expect(viewport.size == CGSize(width: 1440, height: 900))
    #expect(viewport.sourceFrameOffset == CGPoint(x: 520, y: 180))
}

@Test func tooltipOverlayViewportStaysInsideWindowDuringFullscreen() {
    let viewport = BrowserTooltipOverlayViewportResolver.viewport(
        windowSize: CGSize(width: 1440, height: 900),
        windowScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        screenVisibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
        isWindowFullscreen: true,
    )

    #expect(viewport.size == CGSize(width: 1440, height: 900))
    #expect(viewport.sourceFrameOffset == .zero)
}

@Test func tooltipMeasuredSizeUsesIdealWidthWhenItFits() {
    let size = BrowserTooltipMeasuredSizeResolver.resolvedSize(
        idealSize: CGSize(width: 184, height: 42),
        constrainedSize: CGSize(width: 360, height: 42),
        maximumWidth: 360,
    )

    #expect(size == CGSize(width: 184, height: 42))
}

@Test func tooltipMeasuredSizeUsesConstrainedActualWidthOnlyWhenNeeded() {
    let size = BrowserTooltipMeasuredSizeResolver.resolvedSize(
        idealSize: CGSize(width: 520, height: 42),
        constrainedSize: CGSize(width: 316, height: 64),
        maximumWidth: 360,
    )

    #expect(size == CGSize(width: 316, height: 64))
}

@Test
@MainActor func tooltipAppearsOnlyAfterContinuousHoverDelay() async {
    let coordinator = BrowserTooltipCoordinator(
        activationDelayNanoseconds: 20_000_000,
        cooldownDelayNanoseconds: 10_000_000,
    )
    let tooltipID = UUID()

    coordinator.setHovering(true, for: tooltipID)
    #expect(coordinator.activeTooltipID == nil)

    await expectActiveTooltip(tooltipID, in: coordinator)
}

@Test
@MainActor func warmStateMakesNextTooltipAppearImmediately() async {
    let coordinator = BrowserTooltipCoordinator(
        activationDelayNanoseconds: 20_000_000,
        cooldownDelayNanoseconds: 30_000_000,
    )
    let firstTooltipID = UUID()
    let secondTooltipID = UUID()

    coordinator.setHovering(true, for: firstTooltipID)
    await expectActiveTooltip(firstTooltipID, in: coordinator)

    coordinator.setHovering(false, for: firstTooltipID)
    coordinator.setHovering(true, for: secondTooltipID)

    #expect(coordinator.activeTooltipID == secondTooltipID)
}

@Test
@MainActor func leavingAllTooltipTargetsResetsWarmStateAfterCooldown() async {
    let coordinator = BrowserTooltipCoordinator(
        activationDelayNanoseconds: 20_000_000,
        cooldownDelayNanoseconds: 20_000_000,
    )
    let firstTooltipID = UUID()
    let secondTooltipID = UUID()

    coordinator.setHovering(true, for: firstTooltipID)
    await expectActiveTooltip(firstTooltipID, in: coordinator)

    coordinator.setHovering(false, for: firstTooltipID)
    #expect(coordinator.activeTooltipID == nil)
    try? await Task.sleep(nanoseconds: 80_000_000)

    coordinator.setHovering(true, for: secondTooltipID)
    #expect(coordinator.activeTooltipID == nil)

    await expectActiveTooltip(secondTooltipID, in: coordinator)
}

@Test
@MainActor func leavingHidesAtOnceAndKeepsTheNextTargetWarmDuringCooldown() async {
    let coordinator = BrowserTooltipCoordinator(
        activationDelayNanoseconds: 20_000_000,
        cooldownDelayNanoseconds: 5_000_000_000,
    )
    let firstTooltipID = UUID()
    let secondTooltipID = UUID()

    coordinator.setHovering(true, for: firstTooltipID)
    await expectActiveTooltip(firstTooltipID, in: coordinator)

    coordinator.setHovering(false, for: firstTooltipID)
    #expect(coordinator.activeTooltipID == nil)

    coordinator.setHovering(true, for: secondTooltipID)
    #expect(coordinator.activeTooltipID == secondTooltipID)
}

@MainActor private func expectActiveTooltip(
    _ expectedTooltipID: UUID?,
    in coordinator: BrowserTooltipCoordinator,
    timeoutNanoseconds: UInt64 = 500_000_000,
    pollIntervalNanoseconds: UInt64 = 5_000_000,
) async {
    var elapsedNanoseconds: UInt64 = 0

    while coordinator.activeTooltipID != expectedTooltipID, elapsedNanoseconds < timeoutNanoseconds {
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        elapsedNanoseconds += pollIntervalNanoseconds
    }

    #expect(coordinator.activeTooltipID == expectedTooltipID)
}

@Test
@MainActor func staleExitDoesNotCancelAnotherTargetsActivation() async {
    let coordinator = BrowserTooltipCoordinator(
        activationDelayNanoseconds: 20_000_000,
        cooldownDelayNanoseconds: 10_000_000,
    )
    let first = UUID()
    let second = UUID()
    coordinator.setHovering(true, for: first)
    coordinator.setHovering(true, for: second)
    coordinator.setHovering(false, for: first)
    await expectActiveTooltip(second, in: coordinator)
}
