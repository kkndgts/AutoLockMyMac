import Foundation

struct LockActionRunner {
    func perform(_ action: LockAction) {
        switch action {
        case .displaySleep:
            run(executablePath: "/usr/bin/pmset", arguments: ["displaysleepnow"])
        case .screenSaver:
            run(executablePath: "/usr/bin/open", arguments: ["-a", "ScreenSaverEngine"])
        }
    }

    func dismissScreenSaverIfPossible() {
        run(executablePath: "/usr/bin/killall", arguments: ["ScreenSaverEngine"])
    }

    private func run(executablePath: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            // Ignore command failures. Some system states cannot be lifted by a third-party app.
        }
    }
}
