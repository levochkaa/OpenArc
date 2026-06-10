import Foundation

// MARK: - BrowserBatteryState

struct BrowserBatteryState: Equatable {
    let hasBattery: Bool
    let isUsingBatteryPower: Bool
    let batteryPercentage: Int?
}

// MARK: - BrowserBatterySaverPolicy

enum BrowserBatterySaverPolicy {
    static let lowBatteryThresholdPercent = 20

    static func shouldActivate(
        for state: BrowserBatteryState,
        isEnabledInPreferences: Bool
    ) -> Bool {
        guard
            isEnabledInPreferences,
            state.hasBattery,
            state.isUsingBatteryPower,
            let batteryPercentage = state.batteryPercentage
        else {
            return false
        }

        return batteryPercentage <= lowBatteryThresholdPercent
    }
}
