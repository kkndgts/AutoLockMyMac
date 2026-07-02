import AppKit
import SwiftUI

struct StatusMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.proximityState.title, systemImage: model.menuBarIconName)
                .font(.headline)

            if let device = model.selectedDevice {
                Text(device.name)
                    .font(.subheadline)
            } else {
                Text("未选择设备")
                    .font(.subheadline)
            }

            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("打开主界面") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Toggle("启用监控", isOn: Binding(
                get: { model.settings.isMonitoringEnabled },
                set: { model.toggleMonitoring($0) }
            ))

            Button("立即检测") {
                model.performImmediateCheck()
            }

            Button("测试动作") {
                model.runLockActionNow()
            }

            Divider()

            Button("退出 AutoLockMyMac") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 260)
        .padding(12)
    }
}
