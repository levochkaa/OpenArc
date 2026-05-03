import Foundation
import Testing

@Test
@MainActor
func tooltipAppearsOnlyAfterContinuousHoverDelay() async {
    let coordinator = BrowserTooltipCoordinator(
        activationDelayNanoseconds: 20_000_000,
        cooldownDelayNanoseconds: 10_000_000
    )
    let tooltipID = UUID()

    coordinator.setHovering(true, for: tooltipID)
    #expect(coordinator.activeTooltipID == nil)

    await expectActiveTooltip(tooltipID, in: coordinator)
}

@Test
@MainActor
func warmStateMakesNextTooltipAppearImmediately() async {
    let coordinator = BrowserTooltipCoordinator(
        activationDelayNanoseconds: 20_000_000,
        cooldownDelayNanoseconds: 30_000_000
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
@MainActor
func leavingAllTooltipTargetsResetsWarmStateAfterCooldown() async {
    let coordinator = BrowserTooltipCoordinator(
        activationDelayNanoseconds: 20_000_000,
        cooldownDelayNanoseconds: 20_000_000
    )
    let firstTooltipID = UUID()
    let secondTooltipID = UUID()

    coordinator.setHovering(true, for: firstTooltipID)
    await expectActiveTooltip(firstTooltipID, in: coordinator)

    coordinator.setHovering(false, for: firstTooltipID)
    await expectActiveTooltip(nil, in: coordinator)

    coordinator.setHovering(true, for: secondTooltipID)
    #expect(coordinator.activeTooltipID == nil)

    await expectActiveTooltip(secondTooltipID, in: coordinator)
}

@MainActor
private func expectActiveTooltip(
    _ expectedTooltipID: UUID?,
    in coordinator: BrowserTooltipCoordinator,
    timeoutNanoseconds: UInt64 = 500_000_000,
    pollIntervalNanoseconds: UInt64 = 5_000_000
) async {
    var elapsedNanoseconds: UInt64 = 0

    while coordinator.activeTooltipID != expectedTooltipID && elapsedNanoseconds < timeoutNanoseconds {
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        elapsedNanoseconds += pollIntervalNanoseconds
    }

    #expect(coordinator.activeTooltipID == expectedTooltipID)
}
