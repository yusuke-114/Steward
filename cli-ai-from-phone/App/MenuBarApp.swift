import AppKit
import SwiftUI

@main
@MainActor
struct MenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("Steward") {
            MainWindowView(app: app, settings: app.settings)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1080, height: 700)
    }
}

/// The app deliberately owns its appearance instead of inheriting the system
/// setting: remote-command controls must stay visually consistent at a glance.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
