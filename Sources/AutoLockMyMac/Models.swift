import Foundation

enum LockAction: String, CaseIterable, Codable, Identifiable {
    case displaySleep
    case screenSaver

    var id: Self { self }

    var title: String {
        switch self {
        case .displaySleep:
            "关闭屏幕并锁定"
        case .screenSaver:
            "开启屏保"
        }
    }

    var detail: String {
        switch self {
        case .displaySleep:
            "让显示器立即休眠；请将 macOS 设为睡眠后立即需要密码，以确保锁定。"
        case .screenSaver:
            "启动系统屏保；如果系统设置要求密码，解锁仍由 macOS 接管。"
        }
    }
}

enum SensitivityPreset: String, CaseIterable, Codable, Identifiable {
    case close
    case balanced
    case relaxed
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .close:
            "近距离"
        case .balanced:
            "均衡"
        case .relaxed:
            "宽松"
        case .custom:
            "自定义"
        }
    }

    var threshold: Int {
        switch self {
        case .close:
            -60
        case .balanced:
            -72
        case .relaxed:
            -82
        case .custom:
            -72
        }
    }

    var awaySampleCount: Int {
        switch self {
        case .close:
            2
        case .balanced:
            3
        case .relaxed:
            5
        case .custom:
            3
        }
    }

    var detail: String {
        switch self {
        case .close:
            "更敏感，适合希望设备一离开桌面就快速执行动作。"
        case .balanced:
            "默认推荐，适合大多数办公环境。"
        case .relaxed:
            "容忍更大的波动，减少误判。"
        case .custom:
            "手动设置 RSSI 门限。"
        }
    }
}

enum ProximityState: String {
    case unknown
    case near
    case away

    var title: String {
        switch self {
        case .unknown:
            "等待判断"
        case .near:
            "设备在旁边"
        case .away:
            "设备已离开"
        }
    }
}

struct BluetoothDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let identifier: String
    let rssi: Int?
    let lastSeen: Date?
}

struct DeviceSample {
    let rssi: Int?
    let isRecentlyVisible: Bool
    let timestamp: Date
}

enum BluetoothAvailability {
    case unknown
    case unsupported
    case unauthorized
    case poweredOff
    case ready

    var isReady: Bool { self == .ready }

    var message: String {
        switch self {
        case .unknown:
            "正在初始化蓝牙……"
        case .unsupported:
            "这台 Mac 不支持低功耗蓝牙（BLE）。"
        case .unauthorized:
            "尚未获得蓝牙权限。请到「系统设置 → 隐私与安全性 → 蓝牙」里允许 AutoLockMyMac 使用蓝牙。"
        case .poweredOff:
            "蓝牙已关闭，请先在系统里打开蓝牙。"
        case .ready:
            "蓝牙已就绪。"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var selectedDeviceIdentifier: String?
    var sensitivityPreset: SensitivityPreset
    var customThreshold: Double
    var customAwaySampleCount: Int
    var lockAction: LockAction
    var isMonitoringEnabled: Bool
    var sampleInterval: Double

    static let `default` = AppSettings(
        selectedDeviceIdentifier: nil,
        sensitivityPreset: .balanced,
        customThreshold: -72,
        customAwaySampleCount: 3,
        lockAction: .displaySleep,
        isMonitoringEnabled: false,
        sampleInterval: 5
    )

    var effectiveThreshold: Int {
        switch sensitivityPreset {
        case .custom:
            Int(customThreshold.rounded())
        default:
            sensitivityPreset.threshold
        }
    }

    var effectiveAwaySampleCount: Int {
        switch sensitivityPreset {
        case .custom:
            max(1, customAwaySampleCount)
        default:
            sensitivityPreset.awaySampleCount
        }
    }
}
