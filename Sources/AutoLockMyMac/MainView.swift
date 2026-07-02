import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerPanel
                devicePanel
                sensitivityPanel
                actionPanel
                notePanel
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.proximityState.title)
                            .font(.title2.weight(.semibold))
                        Text(model.statusMessage)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(statusColor)
                        .frame(width: 14, height: 14)
                }

                HStack(spacing: 24) {
                    infoBlock(title: "监控", value: model.settings.isMonitoringEnabled ? "开启" : "关闭")
                    infoBlock(title: "门限", value: model.thresholdDescription)
                    infoBlock(title: "离开判定", value: model.awaySamplesDescription)
                    infoBlock(title: "RSSI", value: model.latestRSSI.map { "\($0) dBm" } ?? "--")
                }

                HStack(spacing: 12) {
                    Toggle("启用离开检测", isOn: Binding(
                        get: { model.settings.isMonitoringEnabled },
                        set: { model.toggleMonitoring($0) }
                    ))
                    .toggleStyle(.switch)

                    Spacer()

                    Button {
                        model.performImmediateCheck()
                    } label: {
                        Label("立即检测", systemImage: "dot.radiowaves.left.and.right")
                    }

                    Button {
                        model.runLockActionNow()
                    } label: {
                        Label("测试动作", systemImage: "lock")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("当前状态")
        }
    }

    private var devicePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Text("作为判断依据的蓝牙设备")
                        .font(.headline)
                    Spacer()
                    Button {
                        model.refreshDevices()
                    } label: {
                        Label("刷新设备", systemImage: "arrow.clockwise")
                    }
                }

                Picker("判断设备", selection: selectedDeviceBinding) {
                    Text("请选择设备").tag(String?.none)
                    ForEach(model.discoveredDevices) { device in
                        Text(deviceRowTitle(device)).tag(Optional(device.identifier))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 420, alignment: .leading)

                if let device = model.selectedDevice {
                    VStack(alignment: .leading, spacing: 8) {
                        deviceInfoRow(title: "设备名称", value: device.name)
                        deviceInfoRow(title: "设备标识", value: device.identifier)
                        deviceInfoRow(title: "信号强度", value: device.rssi.map { "\($0) dBm" } ?? "暂无")
                    }
                } else {
                    Text("先在这里选中一个正在广播的 BLE 设备，应用才会用它的信号强度判断你是否离开。")
                        .foregroundStyle(.secondary)
                }

                if model.discoveredDevices.isEmpty {
                    Text("当前还没有扫描到正在广播的蓝牙设备。请确认目标设备已开机并在广播，然后点击刷新。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("判断设备")
        }
    }

    private var sensitivityPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("灵敏度")
                    .font(.headline)

                Picker("推荐预设", selection: Binding(
                    get: { model.settings.sensitivityPreset },
                    set: { model.setSensitivityPreset($0) }
                )) {
                    ForEach(SensitivityPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.settings.sensitivityPreset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("具体 RSSI 门限")
                        Spacer()
                        Text(model.thresholdDescription)
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(model.settings.effectiveThreshold) },
                            set: { model.setSpecificThreshold(Int($0.rounded())) }
                        ),
                        in: -95 ... -35,
                        step: 1
                    )

                    HStack {
                        Stepper(
                            "门限微调",
                            value: Binding(
                                get: { model.settings.effectiveThreshold },
                                set: { model.setSpecificThreshold($0) }
                            ),
                            in: -95 ... -35
                        )
                        Spacer()
                        TextField(
                            "RSSI",
                            value: Binding(
                                get: { model.settings.effectiveThreshold },
                                set: { model.setSpecificThreshold(min(-35, max(-95, $0))) }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("连续低于门限多少次才算离开")
                        Spacer()
                        Text(model.awaySamplesDescription)
                            .foregroundStyle(.secondary)
                    }

                    Stepper(
                        value: Binding(
                            get: { model.settings.effectiveAwaySampleCount },
                            set: { model.setSpecificAwaySampleCount($0) }
                        ),
                        in: 1 ... 10
                    ) {
                        Text("连续样本数")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("灵敏度设置")
        }
    }

    private var actionPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("离开后执行")
                    .font(.headline)

                Picker("动作", selection: Binding(
                    get: { model.settings.lockAction },
                    set: { model.setLockAction($0) }
                )) {
                    ForEach(LockAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.settings.lockAction.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("动作")
        }
    }

    private var notePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("关闭主窗口后，应用会继续留在状态栏的小锁图标里运行。")
                Text("真正的 macOS 登录锁屏界面不能被第三方应用自动解锁；唤醒后只会重新检测设备，并在屏保模式下尝试退出屏保。")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("说明")
        }
    }

    private func infoBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deviceInfoRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
        }
    }

    private func deviceRowTitle(_ device: BluetoothDeviceInfo) -> String {
        if let rssi = device.rssi {
            return "\(device.name)  (\(rssi) dBm)"
        }
        return device.name
    }

    private var statusColor: Color {
        switch model.proximityState {
        case .near:
            .green
        case .away:
            .red
        case .unknown:
            .orange
        }
    }

    private var selectedDeviceBinding: Binding<String?> {
        Binding(
            get: { model.settings.selectedDeviceIdentifier },
            set: { model.selectDevice(identifier: $0) }
        )
    }
}
