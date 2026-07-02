import AppKit
import SwiftUI

@main
struct AutoLockMyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("AutoLockMyMac", id: "main") {
            MainView()
                .environmentObject(model)
        }
        .defaultSize(width: 980, height: 620)

        MenuBarExtra {
            StatusMenuView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MainView()
                .environmentObject(model)
        }
    }
}
