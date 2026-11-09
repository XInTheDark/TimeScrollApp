import AppIntents

struct TimeScrollShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartCaptureIntent(),
                    phrases: ["Start \(.applicationName) capture",
                              "Start recording with \(.applicationName)",
                              "Start capturing in \(.applicationName)"],
                    shortTitle: "Start Capture",
                    systemImageName: "record.circle")
        AppShortcut(intent: StopCaptureIntent(),
                    phrases: ["Stop \(.applicationName) capture",
                              "Stop recording with \(.applicationName)",
                              "Stop capturing in \(.applicationName)"],
                    shortTitle: "Stop Capture",
                    systemImageName: "stop.circle")
        AppShortcut(intent: GetCaptureStateIntent(),
                    phrases: ["Is \(.applicationName) capturing",
                              "Is \(.applicationName) recording"],
                    shortTitle: "Capture State",
                    systemImageName: "questionmark.circle")
    }
}
