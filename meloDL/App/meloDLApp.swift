import SwiftUI
import Sparkle

@main
struct meloDLApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsView(updater: updaterController.updater)
        }
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for App Updates...", action: checkForUpdatesViewModel.updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct SettingsView: View {
    let updater: SPUUpdater

    var body: some View {
        TabView {
            UpdateSettingsView(updater: updater)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 400, height: 200)
    }
}

struct UpdateSettingsView: View {
    @State private var automaticallyChecks: Bool
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self._automaticallyChecks = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            Toggle("Automatically check for app updates", isOn: $automaticallyChecks)
                .onChange(of: automaticallyChecks) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }
        }
        .padding()
    }
}
