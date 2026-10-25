import Testing

@Test func batterySaverPolicyActivatesAtTwentyPercentOnBatteryPower() {
    let state = BrowserBatteryState(
        hasBattery: true,
        isUsingBatteryPower: true,
        batteryPercentage: 20
    )

    #expect(BrowserBatterySaverPolicy.shouldActivate(
        for: state,
        isEnabledInPreferences: true
    ))
}

@Test func batterySaverPolicyDoesNotActivateAboveThreshold() {
    let state = BrowserBatteryState(
        hasBattery: true,
        isUsingBatteryPower: true,
        batteryPercentage: 21
    )

    #expect(!BrowserBatterySaverPolicy.shouldActivate(
        for: state,
        isEnabledInPreferences: true
    ))
}

@Test func batterySaverPolicyRequiresBatteryPowerAndEnabledPreference() {
    let pluggedInState = BrowserBatteryState(
        hasBattery: true,
        isUsingBatteryPower: false,
        batteryPercentage: 10
    )
    let noBatteryState = BrowserBatteryState(
        hasBattery: false,
        isUsingBatteryPower: true,
        batteryPercentage: 10
    )
    let unknownPercentageState = BrowserBatteryState(
        hasBattery: true,
        isUsingBatteryPower: true,
        batteryPercentage: nil
    )

    #expect(!BrowserBatterySaverPolicy.shouldActivate(
        for: pluggedInState,
        isEnabledInPreferences: true
    ))
    #expect(!BrowserBatterySaverPolicy.shouldActivate(
        for: noBatteryState,
        isEnabledInPreferences: true
    ))
    #expect(!BrowserBatterySaverPolicy.shouldActivate(
        for: unknownPercentageState,
        isEnabledInPreferences: true
    ))
    #expect(!BrowserBatterySaverPolicy.shouldActivate(
        for: BrowserBatteryState(hasBattery: true, isUsingBatteryPower: true, batteryPercentage: 10),
        isEnabledInPreferences: false
    ))
}
