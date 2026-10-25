// BrowserBatterySaverController.swift

import Combine
import Foundation
import IOKit.ps

// MARK: - BrowserBatterySaverApplying

protocol BrowserBatterySaverApplying: Sendable {
    func setBatterySaverActive(_ isActive: Bool)
}

// MARK: - BrowserChromiumBatterySaverApplier

struct BrowserChromiumBatterySaverApplier: BrowserBatterySaverApplying {
    func setBatterySaverActive(_ isActive: Bool) {
        BrowserSetBatterySaverModeEnabled(isActive)
    }
}

// MARK: - BrowserBatteryStateProviding

protocol BrowserBatteryStateProviding: AnyObject, Sendable {
    var currentState: BrowserBatteryState { get }
    var onStateChange: ((BrowserBatteryState) -> Void)? { get set }

    func start()
    func stop()
}

// MARK: - BrowserPowerSourceMonitor

final class BrowserPowerSourceMonitor: BrowserBatteryStateProviding, @unchecked Sendable {
    // MARK: Internal

    private(set) var currentState = BrowserBatteryState(
        hasBattery: false,
        isUsingBatteryPower: false,
        batteryPercentage: nil,
    )

    var onStateChange: ((BrowserBatteryState) -> Void)?

    // MARK: Private

    private var runLoopSource: CFRunLoopSource?

    deinit {
        stop()
    }

    private static func readCurrentState() -> BrowserBatteryState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return BrowserBatteryState(hasBattery: false, isUsingBatteryPower: false, batteryPercentage: nil)
        }

        let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?
            .takeUnretainedValue() as String?
        let isUsingBatteryPower = sourceType == kIOPSBatteryPowerValue as String
        guard
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
            !sources.isEmpty
        else {
            return BrowserBatteryState(
                hasBattery: false,
                isUsingBatteryPower: isUsingBatteryPower,
                batteryPercentage: nil,
            )
        }

        var totalCurrentCapacity = 0
        var totalMaxCapacity = 0
        var hasBattery = false

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                boolValue(from: description[kIOPSIsPresentKey as String])
            else {
                continue
            }

            hasBattery = true
            if
                let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int,
                let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int,
                maxCapacity > 0
            {
                totalCurrentCapacity += currentCapacity
                totalMaxCapacity += maxCapacity
            }
        }

        let batteryPercentage = totalMaxCapacity > 0
            ? Int((Double(totalCurrentCapacity) / Double(totalMaxCapacity) * 100).rounded(.down))
            : nil

        return BrowserBatteryState(
            hasBattery: hasBattery,
            isUsingBatteryPower: isUsingBatteryPower,
            batteryPercentage: batteryPercentage,
        )
    }

    private static func boolValue(from value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }

        if let value = value as? NSNumber {
            return value.boolValue
        }

        return false
    }

    func start() {
        guard runLoopSource == nil else {
            refresh()
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else {
                return
            }

            let monitor = Unmanaged<BrowserPowerSourceMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            monitor.refresh()
        }, context)?.takeRetainedValue() else {
            refresh()
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        refresh()
    }

    func stop() {
        guard let runLoopSource else {
            return
        }

        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        self.runLoopSource = nil
    }

    private func refresh() {
        let nextState = Self.readCurrentState()
        guard nextState != currentState else {
            return
        }

        currentState = nextState
        onStateChange?(nextState)
    }
}

// MARK: - BrowserBatterySaverController

@MainActor final class BrowserBatterySaverController {
    // MARK: Internal

    private(set) var isActive = false

    // MARK: Private

    private let preferencesStore: BrowserUserPreferencesStore
    private let stateProvider: BrowserBatteryStateProviding
    private let applier: BrowserBatterySaverApplying

    private var isStarted = false
    private var preferencesCancellable: AnyCancellable?

    init(
        preferencesStore: BrowserUserPreferencesStore,
        stateProvider: BrowserBatteryStateProviding = BrowserPowerSourceMonitor(),
        applier: BrowserBatterySaverApplying = BrowserChromiumBatterySaverApplier(),
    ) {
        self.preferencesStore = preferencesStore
        self.stateProvider = stateProvider
        self.applier = applier

        stateProvider.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handlePowerStateChange(state)
            }
        }
        self.preferencesCancellable = preferencesStore.$batterySaverEnabled.sink { [weak self] _ in
            self?.updateActiveState()
        }
    }

    deinit {
        stateProvider.stop()
    }

    func start() {
        guard !isStarted else {
            return
        }

        isStarted = true
        stateProvider.start()
        updateActiveState()
    }

    func stop() {
        guard isStarted else {
            return
        }

        isStarted = false
        stateProvider.stop()
        setActive(false)
    }

    private func handlePowerStateChange(_: BrowserBatteryState) {
        updateActiveState()
    }

    private func updateActiveState() {
        guard isStarted else {
            return
        }

        setActive(BrowserBatterySaverPolicy.shouldActivate(
            for: stateProvider.currentState,
            isEnabledInPreferences: preferencesStore.batterySaverEnabled,
        ))
    }

    private func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else {
            return
        }

        self.isActive = isActive
        applier.setBatterySaverActive(isActive)
    }
}
