import Foundation

struct ProximityDecision {
    let state: ProximityState
    let shouldTriggerLockAction: Bool
}

struct ProximityEvaluator {
    private(set) var hasSeenNearby = false
    private(set) var consecutiveAwaySamples = 0
    private(set) var hasTriggeredForCurrentAbsence = false

    mutating func reset() {
        hasSeenNearby = false
        consecutiveAwaySamples = 0
        hasTriggeredForCurrentAbsence = false
    }

    mutating func evaluate(rssi: Int?, threshold: Int, graceSampleCount: Int) -> ProximityDecision {
        if let rssi, rssi >= threshold {
            hasSeenNearby = true
            consecutiveAwaySamples = 0
            hasTriggeredForCurrentAbsence = false
            return ProximityDecision(state: .near, shouldTriggerLockAction: false)
        }

        consecutiveAwaySamples += 1
        let isAway = hasSeenNearby && consecutiveAwaySamples >= graceSampleCount
        let shouldTrigger = isAway && !hasTriggeredForCurrentAbsence

        if shouldTrigger {
            hasTriggeredForCurrentAbsence = true
        }

        return ProximityDecision(
            state: isAway ? .away : .unknown,
            shouldTriggerLockAction: shouldTrigger
        )
    }

    /// 手动“立即检测”使用：不经过连续多次的缓冲，直接按门限给出确定结果。
    /// RSSI 不低于门限 → 保持在旁边（不锁）；低于门限 → 立即判离开并执行锁定；
    /// 无有效 RSSI（扫不到）→ 无法判断，保持不变、不动作。
    mutating func evaluateImmediate(rssi: Int?, threshold: Int) -> ProximityDecision {
        guard let rssi else {
            return ProximityDecision(state: .unknown, shouldTriggerLockAction: false)
        }

        if rssi >= threshold {
            hasSeenNearby = true
            consecutiveAwaySamples = 0
            hasTriggeredForCurrentAbsence = false
            return ProximityDecision(state: .near, shouldTriggerLockAction: false)
        }

        consecutiveAwaySamples = max(consecutiveAwaySamples, 1)
        hasTriggeredForCurrentAbsence = true
        return ProximityDecision(state: .away, shouldTriggerLockAction: true)
    }
}
