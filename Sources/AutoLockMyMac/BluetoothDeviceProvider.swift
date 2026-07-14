import CoreBluetooth
import Foundation
import IOBluetooth

/// CBPeripheral 不是 Sendable，但本类的 central 用 `.main` 队列创建，
/// 所有 delegate 回调都在主线程，跨入 MainActor 闭包是安全的。
/// 用这个包装盒显式告诉编译器可以安全传递。
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
final class BluetoothDeviceProvider: NSObject {
    var onAvailabilityChange: ((BluetoothAvailability) -> Void)?
    var onDevicesChange: (() -> Void)?
    private(set) var availability: BluetoothAvailability = .unknown

    private var central: CBCentralManager!
    private var discovered: [UUID: DiscoveredDevice] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]

    private var monitoredIdentifier: UUID?
    private var monitoredPeripheral: CBPeripheral?
    private var scanMode: ScanMode = .idle
    private var discoveryStopWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    /// 读取系统里“我的设备”中已配对的蓝牙设备名称（经过规范化）。
    /// macOS 上 IOBluetooth 能拿到已配对设备清单，但它给的是经典蓝牙 MAC，
    /// 而 CoreBluetooth 扫描结果是 UUID + 广播名，两者无法用地址对应，
    /// 因此只能用设备名称作为交叉匹配的依据。
    func pairedDeviceNames() -> Set<String> {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return Set(devices.compactMap { $0.name }.map { Self.normalize($0) })
    }

    /// 系统“我的设备”里是否存在已配对的手机类设备（iPhone/Android 手机等）。
    /// 手机的 BLE 广播通常无名、随机地址，无法靠名称匹配进交集；只有当确实配对过
    /// 手机时，才把扫描到的 Apple 厂商近距离设备作为“可能的手机”放出来供认领。
    func hasPairedPhone() -> Bool {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        // kBluetoothDeviceClassMajorPhone == 0x02
        return devices.contains { $0.deviceClassMajor == 0x02 }
    }

    func loadDiscoveredDevices() -> [BluetoothDeviceInfo] {
        let pairedNames = pairedDeviceNames()
        let includePhoneCandidates = hasPairedPhone()

        return discovered.values
            .compactMap { device -> BluetoothDeviceInfo? in
                let isPairedMatch = pairedNames.contains(Self.normalize(device.name))
                // “可能的手机”：仅当配对过手机、且这是 Apple 厂商的近距离设备（信号不弱）时。
                // 你配对过的 iPhone 其 CoreBluetooth identifier 是稳定的，认领一次即可长期监控。
                let isPhoneCandidate = includePhoneCandidates
                    && device.isApple
                    && isPairedMatch == false
                    && device.rssi >= Self.phoneCandidateRSSIFloor

                guard device.id == monitoredIdentifier || isPairedMatch || isPhoneCandidate else {
                    return nil
                }

                let displayName: String
                if isPairedMatch || device.id == monitoredIdentifier {
                    displayName = device.name
                } else {
                    displayName = "可能的手机 · \(device.rssi) dBm"
                }

                return BluetoothDeviceInfo(
                    id: device.id.uuidString,
                    name: displayName,
                    identifier: device.id.uuidString,
                    rssi: device.rssi,
                    lastSeen: device.lastSeen
                )
            }
            .sorted { lhs, rhs in
                let lhsSeen = lhs.lastSeen ?? .distantPast
                let rhsSeen = rhs.lastSeen ?? .distantPast
                if lhsSeen != rhsSeen {
                    return lhsSeen > rhsSeen
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func sampleDevice(identifier: String, freshnessInterval: TimeInterval) -> DeviceSample? {
        guard let uuid = UUID(uuidString: identifier), let device = discovered[uuid] else {
            return nil
        }

        let isFresh = Date().timeIntervalSince(device.lastSeen) <= freshnessInterval
        return DeviceSample(
            rssi: isFresh ? device.rssi : nil,
            isRecentlyVisible: isFresh,
            timestamp: Date()
        )
    }

    /// 指定要持续监控的设备：macOS 无法用 MAC 扫描，这里用 UUID 解析外设并主动连接，
    /// 这样即使设备当前没有在广播，也能通过 readRSSI() 拿到信号强度。
    func setMonitoredDevice(identifier: String?) {
        let newIdentifier = identifier.flatMap { UUID(uuidString: $0) }

        if let previous = monitoredPeripheral, previous.identifier != newIdentifier {
            central.cancelPeripheralConnection(previous)
            monitoredPeripheral = nil
        }

        monitoredIdentifier = newIdentifier

        guard let newIdentifier else {
            return
        }

        let peripheral = peripherals[newIdentifier]
            ?? central.retrievePeripherals(withIdentifiers: [newIdentifier]).first
        if let peripheral {
            peripherals[newIdentifier] = peripheral
            monitoredPeripheral = peripheral
        }

        connectMonitoredIfNeeded()
    }

    /// 每次采样时调用：连上就主动读一次 RSSI；没连上就发起连接。
    func requestRSSIUpdate() {
        guard let peripheral = monitoredPeripheral else {
            return
        }
        if peripheral.state == .connected {
            peripheral.readRSSI()
        } else {
            ensureMonitoringScanActive()
            connectMonitoredIfNeeded()
        }
    }

    func refreshDiscovery(duration: TimeInterval = 8) {
        guard central.state == .poweredOn else {
            return
        }
        startScanning(mode: .discovery)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.scanMode == .discovery {
                self.stopScanning()
            }
        }
        discoveryStopWorkItem?.cancel()
        discoveryStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func startMonitoring() {
        ensureMonitoringScanActive()
        connectMonitoredIfNeeded()
    }

    func stopMonitoring() {
        stopScanning()
        if let peripheral = monitoredPeripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func startScanning(mode: ScanMode) {
        guard central.state == .poweredOn else {
            return
        }

        discoveryStopWorkItem?.cancel()
        discoveryStopWorkItem = nil

        if central.isScanning {
            if scanMode == mode {
                return
            }
            central.stopScan()
        }

        scanMode = mode
        guard central.isScanning == false else {
            return
        }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log("开始扫描 BLE 广播（\(mode.description)）…")
    }

    private func ensureMonitoringScanActive() {
        guard monitoredIdentifier != nil else {
            return
        }

        if monitoredPeripheral?.state == .connected {
            stopScanning()
            return
        }

        startScanning(mode: .monitoring)
    }

    func stopScanning() {
        discoveryStopWorkItem?.cancel()
        discoveryStopWorkItem = nil
        if central.isScanning {
            central.stopScan()
        }
        scanMode = .idle
    }

    private func connectMonitoredIfNeeded() {
        guard central.state == .poweredOn, let peripheral = monitoredPeripheral else {
            return
        }
        switch peripheral.state {
        case .connected:
            stopScanning()
            peripheral.readRSSI()
        case .connecting:
            break
        default:
            ensureMonitoringScanActive()
            log("尝试连接被监控设备 \(peripheral.identifier.uuidString.prefix(8))…")
            central.connect(peripheral, options: nil)
        }
    }

    private func updateAvailability(_ newValue: BluetoothAvailability) {
        guard newValue != availability else {
            return
        }
        availability = newValue
        onAvailabilityChange?(newValue)
    }

    private func record(
        identifier: UUID,
        name: String?,
        rssi: Int,
        isApple: Bool? = nil,
        isConnectable: Bool? = nil
    ) {
        let existing = discovered[identifier]

        let resolvedName: String
        if let name, name.isEmpty == false {
            resolvedName = name
        } else if let existing, existing.name.hasPrefix(Self.unnamedPrefix) == false {
            resolvedName = existing.name
        } else {
            resolvedName = Self.unnamedPrefix + " (" + identifier.uuidString.prefix(8) + ")"
        }

        discovered[identifier] = DiscoveredDevice(
            id: identifier,
            name: resolvedName,
            rssi: rssi,
            lastSeen: Date(),
            isApple: isApple ?? existing?.isApple ?? false,
            isConnectable: isConnectable ?? existing?.isConnectable ?? false
        )
        onDevicesChange?()
    }

    private func log(_ message: String) {
        NSLog("[AutoLockMyMac.BLE] %@", message)
    }

    private static let unnamedPrefix = "未命名设备"

    /// “可能的手机”候选的信号下限：只纳入较近（约几米内）的 Apple 厂商设备，
    /// 避免把远处他人的 iPhone/AirPods 也混进列表。
    private static let phoneCandidateRSSIFloor = -75

    /// 统一设备名称用于跨框架匹配：去首尾空白并忽略大小写。
    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct DiscoveredDevice {
        let id: UUID
        var name: String
        var rssi: Int
        var lastSeen: Date
        var isApple: Bool
        var isConnectable: Bool
    }

    private enum ScanMode: Equatable {
        case idle
        case discovery
        case monitoring

        var description: String {
            switch self {
            case .idle: "空闲"
            case .discovery: "发现设备"
            case .monitoring: "监控设备"
            }
        }
    }
}

extension BluetoothDeviceProvider: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            let availability: BluetoothAvailability
            switch state {
            case .poweredOn:
                availability = .ready
            case .poweredOff:
                availability = .poweredOff
            case .unauthorized:
                availability = .unauthorized
            case .unsupported:
                availability = .unsupported
            case .resetting, .unknown:
                availability = .unknown
            @unknown default:
                availability = .unknown
            }
            log("蓝牙状态变化：\(availability)")
            updateAvailability(availability)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssiValue = RSSI.intValue
        let identifier = peripheral.identifier
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let resolvedName = advertisedName ?? peripheral.name

        // 解析广播包：厂商标识（Apple = 0x004C）、是否可连接、服务 UUID。
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let companyID = manufacturerData.flatMap { data in
            data.count >= 2 ? Int(data[0]) | (Int(data[1]) << 8) : nil
        }
        let isApple = companyID == 0x004C
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false

        let box = UncheckedSendableBox(value: peripheral)

        MainActor.assumeIsolated {
            let peripheral = box.value
            peripherals[identifier] = peripheral

            // RSSI == 127 表示广播包里没有有效的信号强度读数，但设备仍可被连接读取。
            if rssiValue != 127 {
                record(
                    identifier: identifier,
                    name: resolvedName,
                    rssi: rssiValue,
                    isApple: isApple,
                    isConnectable: isConnectable
                )
            }

            if identifier == monitoredIdentifier {
                if monitoredPeripheral == nil {
                    monitoredPeripheral = peripheral
                }
                connectMonitoredIfNeeded()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let shortID = String(peripheral.identifier.uuidString.prefix(8))
        let box = UncheckedSendableBox(value: peripheral)
        MainActor.assumeIsolated {
            let peripheral = box.value
            log("已连接 \(shortID)，开始读取 RSSI")
            peripheral.delegate = self
            stopScanning()
            peripheral.readRSSI()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let shortID = String(peripheral.identifier.uuidString.prefix(8))
        let reason = error?.localizedDescription ?? "未知错误"
        MainActor.assumeIsolated {
            log("连接失败 \(shortID)：\(reason)")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let identifier = peripheral.identifier
        let shortID = String(identifier.uuidString.prefix(8))
        let reason = error?.localizedDescription ?? "正常断开"
        MainActor.assumeIsolated {
            log("断开 \(shortID)：\(reason)")
            if identifier == monitoredIdentifier {
                // 设备走远或休眠会导致断开，尝试重新连接以便它回到附近时继续读 RSSI。
                ensureMonitoringScanActive()
                connectMonitoredIfNeeded()
            }
        }
    }
}

extension BluetoothDeviceProvider: CBPeripheralDelegate {
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: Error?
    ) {
        let rssiValue = RSSI.intValue
        let identifier = peripheral.identifier
        let name = peripheral.name
        let errorDescription = error?.localizedDescription

        MainActor.assumeIsolated {
            if let errorDescription {
                log("读取 RSSI 失败 \(identifier.uuidString.prefix(8))：\(errorDescription)")
                return
            }
            guard rssiValue != 127 else {
                return
            }
            record(identifier: identifier, name: name, rssi: rssiValue)
        }
    }
}
