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

    init() {
        let storedData = UserDefaults.standard.data(forKey: settingsKey)
            ?? UserDefaults.standard.data(forKey: legacySettingsKey)
        if let data = storedData,
           let loaded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = loaded
        } else {
            settings = .default
        }

        observeSystemEvents()

        provider.onAvailabilityChange = { [weak self] availability in
            self?.handleAvailabilityChange(availability)
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
        timer?.invalidate()

        guard settings.selectedDeviceIdentifier != nil else {
            statusMessage = "先选择一个蓝牙设备，然后再开启监控。"
            return
        }

        provider.startScanning()
        provider.setMonitoredDevice(identifier: settings.selectedDeviceIdentifier)
        statusMessage = "监控中，按照设定的采样周期读取蓝牙信号。"
        sampleSelectedDevice(triggerReason: .timer)

        timer = Timer.scheduledTimer(withTimeInterval: settings.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleSelectedDevice(triggerReason: .timer)
            }
        }
    }

    private func stopMonitoring(message: String) {
        timer?.invalidate()
        timer = nil
        provider.stopScanning()
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

        let freshnessInterval = max(15, settings.sampleInterval * 3)
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
    }

    private func handleAvailabilityChange(_ availability: BluetoothAvailability) {
        guard availability.isReady else {
            proximityState = .unknown
            latestRSSI = nil
            statusMessage = availability.message
            return
        }

        provider.startScanning()
        provider.setMonitoredDevice(identifier: settings.selectedDeviceIdentifier)
        refreshDevices()
        if settings.isMonitoringEnabled {
            sampleSelectedDevice(triggerReason: .timer)
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
}

private extension AppModel {
    enum TriggerReason {
        case timer
        case manual
        case wake
    }
}
