import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    @Published private(set) var discoveredDevices: [BluetoothDeviceInfo] = []
    @Published private(set) var proximityState: ProximityState = .unknown
    @Published private(set) var latestRSSI: Int?
    @Published private(set) var lastSampleDate: Date?
    @Published private(set) var lastActionDate: Date?
    @Published private(set) var statusMessage = "请选择一个会持续广播的蓝牙设备（如手环、智能手表或 BLE 信标）。"
    @Published private(set) var isScreenLocked = false

    private let settingsKey = "auto_lock_my_mac.settings"
    private let legacySettingsKey = "lock_my_pc.settings"
    private let provider = BluetoothDeviceProvider()
    private let actionRunner = LockActionRunner()
    private var evaluator = ProximityEvaluator()
    private var timer: Timer?
    private var wakeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var samplingMode: SamplingMode = .normal

    init() {
        let storedData = UserDefaults.standard.data(forKey: settingsKey)
            ?? UserDefaults.standard.data(forKey: legacySettingsKey)
        if let data = storedData,
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            var normalized = loaded
            normalized.sampleInterval = loaded.effectiveSampleInterval
            settings = normalized
        } else {
            settings = .default
        }

        observeSystemEvents()

        provider.onAvailabilityChange = { [weak self] availability in
            self?.handleAvailabilityChange(availability)
        }
        provider.onDevicesChange = { [weak self] in
            self?.discoveredDevices = self?.provider.loadDiscoveredDevices() ?? []
        }

        refreshDevices()
        handleAvailabilityChange(provider.availability)

        if settings.isMonitoringEnabled {
            startMonitoring()
        }
    }

    var selectedDevice: BluetoothDeviceInfo? {
        guard let identifier = settings.selectedDeviceIdentifier else {
            return nil
        }
        return discoveredDevices.first(where: { $0.identifier == identifier })
    }

    var thresholdDescription: String {
        "\(settings.effectiveThreshold) dBm"
    }

    var sampleIntervalDescription: String {
        "\(Int(settings.effectiveSampleInterval.rounded())) 秒"
    }

    var awaySamplesDescription: String {
        "\(settings.effectiveAwaySampleCount) 次连续低于门限"
    }

    var menuBarIconName: String {
        switch proximityState {
        case .near:
            return "lock.open.fill"
        case .away:
            return "lock.fill"
        case .unknown:
            return settings.isMonitoringEnabled ? "lock.trianglebadge.exclamationmark" : "lock"
        }
    }

    func refreshDevices() {
        discoveredDevices = provider.loadDiscoveredDevices()
        provider.refreshDiscovery()
    }

    func selectDevice(identifier: String?) {
        settings.selectedDeviceIdentifier = identifier
        provider.setMonitoredDevice(identifier: identifier)
        resetMonitoringState(message: "设备已切换，等待新的 RSSI 采样。")
        if settings.isMonitoringEnabled {
            startMonitoring()
        }
    }

    func setSensitivityPreset(_ preset: SensitivityPreset) {
        settings.sensitivityPreset = preset
        if preset != .custom {
            settings.customThreshold = Double(preset.threshold)
            settings.customAwaySampleCount = preset.awaySampleCount
        }
        resetMonitoringState(message: "灵敏度已更新，新的门限会从下一次采样开始生效。")
        if settings.isMonitoringEnabled {
            sampleSelectedDevice(triggerReason: .timer)
        }
    }

    func setSpecificThreshold(_ value: Int) {
        settings.customThreshold = Double(value)
        updateSensitivityPresetFromManualValues()
        resetMonitoringState(message: "RSSI 门限已更新。")
        if settings.isMonitoringEnabled {
            sampleSelectedDevice(triggerReason: .timer)
        }
    }

    func setSpecificAwaySampleCount(_ count: Int) {
        settings.customAwaySampleCount = count
        updateSensitivityPresetFromManualValues()
        resetMonitoringState(message: "离开判定次数已更新。")
        if settings.isMonitoringEnabled {
            sampleSelectedDevice(triggerReason: .timer)
        }
    }

    func setSampleInterval(_ value: Double) {
        settings.sampleInterval = min(AppSettings.maximumSampleInterval, max(AppSettings.minimumSampleInterval, value))
        resetMonitoringState(message: "扫描间隔已更新。")
        if settings.isMonitoringEnabled {
            startMonitoring()
        }
    }

    func setLockAction(_ action: LockAction) {
        settings.lockAction = action
    }

    func toggleMonitoring(_ enabled: Bool) {
        if enabled {
            guard settings.selectedDeviceIdentifier != nil else {
                settings.isMonitoringEnabled = false
                statusMessage = "请先选择一个蓝牙设备，再开启监控。"
                return
            }
            settings.isMonitoringEnabled = true
            startMonitoring()
        } else {
            settings.isMonitoringEnabled = false
            stopMonitoring(message: "监控已暂停。")
        }
    }

    func performImmediateCheck() {
        sampleSelectedDevice(triggerReason: .manual)
    }

    func runLockActionNow() {
        actionRunner.perform(settings.lockAction)
        lastActionDate = Date()
    }

    private func startMonitoring() {
        samplingMode = .normal
        invalidateTimer()

        guard settings.selectedDeviceIdentifier != nil else {
            statusMessage = "先选择一个蓝牙设备，然后再开启监控。"
            return
        }

        provider.setMonitoredDevice(identifier: settings.selectedDeviceIdentifier)
        provider.startMonitoring()
        statusMessage = "监控中，按照设定的采样周期读取蓝牙信号。"
        sampleSelectedDevice(triggerReason: .timer)
    }

    private func stopMonitoring(message: String) {
        samplingMode = .normal
        invalidateTimer()
        provider.stopMonitoring()
        resetMonitoringState(message: message)
    }

    private func sampleSelectedDevice(triggerReason: TriggerReason) {
        guard provider.availability.isReady else {
            proximityState = .unknown
            latestRSSI = nil
            statusMessage = provider.availability.message
            return
        }

        guard let identifier = settings.selectedDeviceIdentifier else {
            proximityState = .unknown
            latestRSSI = nil
            statusMessage = "请选择一个蓝牙设备。"
            return
        }

        provider.requestRSSIUpdate()
        refreshDevices()

        let freshnessInterval = max(AppSettings.minimumSampleInterval, settings.effectiveSampleInterval * 3)
        let sample = provider.sampleDevice(identifier: identifier, freshnessInterval: freshnessInterval)
        let rssi = sample?.rssi

        latestRSSI = rssi
        lastSampleDate = Date()

        let decision: ProximityDecision
        if triggerReason == .manual {
            // 手动“立即检测”：直接按门限即时判定，该锁就锁、不该锁就保持。
            decision = evaluator.evaluateImmediate(
                rssi: rssi,
                threshold: settings.effectiveThreshold
            )
        } else {
            decision = evaluator.evaluate(
                rssi: rssi,
                threshold: settings.effectiveThreshold,
                graceSampleCount: settings.effectiveAwaySampleCount
            )
        }
        proximityState = decision.state

        if let rssi {
            statusMessage = "最新 RSSI 为 \(rssi) dBm，当前门限为 \(settings.effectiveThreshold) dBm。"
        } else if sample == nil {
            statusMessage = "还没有扫描到该设备的蓝牙广播，请确认它正在广播并靠近电脑。"
        } else {
            statusMessage = "最近没有收到该设备的蓝牙广播，可能已经离开或进入了休眠。"
        }

        if decision.shouldTriggerLockAction {
            statusMessage = "设备已判定离开，已执行“\(settings.lockAction.title)”。"
            actionRunner.perform(settings.lockAction)
            lastActionDate = Date()
        }

        if triggerReason == .wake, decision.state == .near, settings.lockAction == .screenSaver {
            actionRunner.dismissScreenSaverIfPossible()
        }

        updateSamplingMode(for: decision)
    }

    private func handleAvailabilityChange(_ availability: BluetoothAvailability) {
        guard availability.isReady else {
            proximityState = .unknown
            latestRSSI = nil
            statusMessage = availability.message
            return
        }

        if settings.isMonitoringEnabled {
            provider.setMonitoredDevice(identifier: settings.selectedDeviceIdentifier)
            provider.startMonitoring()
            sampleSelectedDevice(triggerReason: .timer)
        } else {
            refreshDevices()
        }
    }

    private func resetMonitoringState(message: String) {
        evaluator.reset()
        proximityState = .unknown
        latestRSSI = nil
        lastSampleDate = nil
        statusMessage = message
    }

    private func updateSensitivityPresetFromManualValues() {
        if let matchedPreset = SensitivityPreset.allCases.first(where: {
            $0 != .custom &&
            $0.threshold == Int(settings.customThreshold.rounded()) &&
            $0.awaySampleCount == settings.customAwaySampleCount
        }) {
            settings.sensitivityPreset = matchedPreset
        } else {
            settings.sensitivityPreset = .custom
        }
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        UserDefaults.standard.set(data, forKey: settingsKey)

    }

    private func observeSystemEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                self?.handleWake()
            }
            .store(in: &cancellables)

        let distributedCenter = DistributedNotificationCenter.default()

        distributedCenter.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in
                self?.isScreenLocked = true
            }
            .store(in: &cancellables)

        distributedCenter.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in
                self?.isScreenLocked = false
            }
            .store(in: &cancellables)
    }

    private func handleWake() {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard settings.isMonitoringEnabled else {
                return
            }
            sampleSelectedDevice(triggerReason: .wake)
        }
    }

    private func updateSamplingMode(for decision: ProximityDecision) {
        guard settings.isMonitoringEnabled else {
            invalidateTimer()
            return
        }

        let needsFastConfirmation =
            evaluator.hasSeenNearby &&
            decision.state == .unknown &&
            evaluator.consecutiveAwaySamples > 0 &&
            evaluator.consecutiveAwaySamples < settings.effectiveAwaySampleCount

        let newMode: SamplingMode = needsFastConfirmation ? .fastConfirmation : .normal
        scheduleTimer(for: newMode)
    }

    private func scheduleTimer(for mode: SamplingMode) {
        let interval = interval(for: mode)

        if samplingMode == mode,
           let timer,
           timer.isValid,
           abs(timer.timeInterval - interval) < 0.001 {
            return
        }

        samplingMode = mode
        invalidateTimer()

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleSelectedDevice(triggerReason: .timer)
            }
        }
        timer?.tolerance = max(1, interval * 0.25)
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func interval(for mode: SamplingMode) -> TimeInterval {
        switch mode {
        case .normal:
            return settings.effectiveSampleInterval
        case .fastConfirmation:
            return 5
        }
    }
}

private extension AppModel {
    enum TriggerReason {
        case timer
        case manual
        case wake
    }

    enum SamplingMode {
        case normal
        case fastConfirmation
    }
}
