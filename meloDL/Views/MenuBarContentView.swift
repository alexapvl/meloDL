import AppKit
import SwiftUI

struct MenuBarContentView: View {
    let appSettings: AppSettings
    let sessionCoordinator: DownloadSessionCoordinator
    let onOpenSettings: () -> Void

    var body: some View {
        ContentView(
            appSettings: appSettings,
            coordinator: sessionCoordinator,
            onOpenSettings: {
                NSApp.activate(ignoringOtherApps: true)
                onOpenSettings()
            }
        )
        .frame(width: SessionLayout.windowMinWidth, height: SessionLayout.windowMinHeight)
        .environment(\.compactWindowChrome, true)
    }
}
