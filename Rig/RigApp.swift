import SwiftUI

@main
struct RigApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {}
            .defaultLaunchBehavior(.suppressed)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Settings…") {
                        appDelegate.presentSettingsWindow()
                    }
                    .keyboardShortcut(",")
                }
            }
    }
}
