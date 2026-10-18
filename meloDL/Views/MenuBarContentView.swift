import AppKit
import SwiftUI

struct MenuBarContentView: View {
    let appSettings: AppSettings
    let sessionCoordinator: DownloadSessionCoordinator
    let onOpenSettings: (SettingsDestination) -> Void

    var body: some View {
        ContentView(
            appSettings: appSettings,
            coordinator: sessionCoordinator,
            onOpenSettings: { destination in
                NSApp.activate(ignoringOtherApps: true)
                onOpenSettings(destination)
            }
        )
        .frame(width: SessionLayout.windowMinWidth, height: SessionLayout.windowMinHeight)
        .environment(\.compactWindowChrome, true)
    }
}
