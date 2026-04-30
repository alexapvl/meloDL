import AppKit
import SwiftUI

struct MenuBarContentView: View {
    let appSettings: AppSettings
    let onCheckAppUpdates: () -> Void
    let onQuit: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            ContentView(
                appSettings: appSettings,
                onCheckAppUpdates: onCheckAppUpdates,
                onOpenSettings: {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            )
            .frame(width: 580, height: 600)

            Divider()

            HStack {
                Spacer()
                Button("Quit meloDL", action: onQuit)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
