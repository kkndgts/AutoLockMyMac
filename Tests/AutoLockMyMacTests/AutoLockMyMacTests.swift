import Testing
@testable import AutoLockMyMac

@Test
func missingSamplesOnlyTriggerAfterDeviceWasSeenNearby() {
    var evaluator = ProximityEvaluator()

    for _ in 0 ..< 5 {
        let decision = evaluator.evaluate(rssi: nil, threshold: -72, graceSampleCount: 3)
        #expect(decision.shouldTriggerLockAction == false)
    }

    _ = evaluator.evaluate(rssi: -60, threshold: -72, graceSampleCount: 3)
    _ = evaluator.evaluate(rssi: nil, threshold: -72, graceSampleCount: 3)
    _ = evaluator.evaluate(rssi: nil, threshold: -72, graceSampleCount: 3)
    let away = evaluator.evaluate(rssi: nil, threshold: -72, graceSampleCount: 3)

    #expect(away.state == .away)
    #expect(away.shouldTriggerLockAction)
}

@Test
func absenceOnlyTriggersOnceUntilDeviceReturns() {
    var evaluator = ProximityEvaluator()

    _ = evaluator.evaluate(rssi: -60, threshold: -72, graceSampleCount: 1)
    let firstAway = evaluator.evaluate(rssi: nil, threshold: -72, graceSampleCount: 1)
    let stillAway = evaluator.evaluate(rssi: nil, threshold: -72, graceSampleCount: 1)

    #expect(firstAway.shouldTriggerLockAction)
    #expect(stillAway.state == .away)
    #expect(stillAway.shouldTriggerLockAction == false)
}

@Test
func proximityNeedsEnoughAwaySamplesBeforeTriggering() {
    var evaluator = ProximityEvaluator()

    let firstNear = evaluator.evaluate(rssi: -60, threshold: -72, graceSampleCount: 3)
    #expect(firstNear.state == .near)
    #expect(firstNear.shouldTriggerLockAction == false)

    let firstAway = evaluator.evaluate(rssi: -85, threshold: -72, graceSampleCount: 3)
    let secondAway = evaluator.evaluate(rssi: -88, threshold: -72, graceSampleCount: 3)
    let thirdAway = evaluator.evaluate(rssi: -90, threshold: -72, graceSampleCount: 3)

    #expect(firstAway.state == .unknown)
    #expect(secondAway.state == .unknown)
    #expect(thirdAway.state == .away)
    #expect(thirdAway.shouldTriggerLockAction)
}

@Test
func proximityResetsTriggerAfterReturningNearby() {
    var evaluator = ProximityEvaluator()

    _ = evaluator.evaluate(rssi: -60, threshold: -72, graceSampleCount: 2)
    let away = evaluator.evaluate(rssi: -90, threshold: -72, graceSampleCount: 2)
    let awayTrigger = evaluator.evaluate(rssi: -91, threshold: -72, graceSampleCount: 2)
    let backNear = evaluator.evaluate(rssi: -64, threshold: -72, graceSampleCount: 2)

    #expect(away.state == .unknown)
    #expect(awayTrigger.shouldTriggerLockAction)
    #expect(backNear.state == .near)
    #expect(backNear.shouldTriggerLockAction == false)
}

@Test
func customSensitivityUsesCustomValues() {
    let settings = AppSettings(
        selectedDeviceIdentifier: nil,
        sensitivityPreset: .custom,
        customThreshold: -67,
        customAwaySampleCount: 4,
        lockAction: .screenSaver,
        isMonitoringEnabled: true,
        sampleInterval: 5
    )

    #expect(settings.effectiveThreshold == -67)
    #expect(settings.effectiveAwaySampleCount == 4)
}
