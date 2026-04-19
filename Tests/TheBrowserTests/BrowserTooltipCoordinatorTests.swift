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

    try? await Task.sleep(nanoseconds: 40_000_000)

    #expect(coordinator.activeTooltipID == tooltipID)
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
    try? await Task.sleep(nanoseconds: 40_000_000)
    #expect(coordinator.activeTooltipID == firstTooltipID)

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
    try? await Task.sleep(nanoseconds: 40_000_000)
    #expect(coordinator.activeTooltipID == firstTooltipID)

    coordinator.setHovering(false, for: firstTooltipID)
    try? await Task.sleep(nanoseconds: 40_000_000)
    #expect(coordinator.activeTooltipID == nil)

    coordinator.setHovering(true, for: secondTooltipID)
    #expect(coordinator.activeTooltipID == nil)

    try? await Task.sleep(nanoseconds: 40_000_000)
    #expect(coordinator.activeTooltipID == secondTooltipID)
}
