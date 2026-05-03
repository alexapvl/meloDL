import AppKit
import SwiftUI
import Sparkle
import UserNotifications

private enum LaunchArguments {
    static let menubarOnly = "--menubar-only"
    static let windowMode = "--window-mode"
}

private enum SettingsKeys {
    static let menubarOnlyMode = "settings.menubarOnlyMode"
    static let openAtLogin = "settings.openAtLogin"
    static let onboardingCompleted = "settings.onboardingCompleted"
}

@main
struct meloDLApp: App {
    @StateObject private var appSettings = AppSettings()
    @State private var menuBarController: MenuBarController?
    private let notificationDelegate = DownloadNotificationCenterDelegate()
    private let launchMenubarOnlyMode: Bool
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        let defaults = UserDefaults.standard
        if CommandLine.arguments.contains(LaunchArguments.menubarOnly) {
            defaults.set(true, forKey: SettingsKeys.menubarOnlyMode)
        } else if CommandLine.arguments.contains(LaunchArguments.windowMode) {
            defaults.set(false, forKey: SettingsKeys.menubarOnlyMode)
        }

        let isMenubarOnly = defaults.bool(forKey: SettingsKeys.menubarOnlyMode)
        let onboardingCompleted = defaults.bool(forKey: SettingsKeys.onboardingCompleted)
        self.launchMenubarOnlyMode = isMenubarOnly && onboardingCompleted
        UNUserNotificationCenter.current().delegate = notificationDelegate
        DownloadNotificationService.shared.configureNotificationCategories()
        AppModeController.applyMenubarOnlyMode(launchMenubarOnlyMode)
        if launchMenubarOnlyMode {
            let openAtLogin = defaults.bool(forKey: SettingsKeys.openAtLogin)
            LoginItemService.setEnabled(openAtLogin)
        } else {
            defaults.set(false, forKey: SettingsKeys.openAtLogin)
            LoginItemService.setEnabled(false)
        }
    }

    var body: some Scene {
        mainWindowScene
        settingsScene
    }

    private var mainWindowScene: some Scene {
        WindowGroup {
            if launchMenubarOnlyMode && appSettings.onboardingCompleted {
                Color.clear
                    .frame(width: 0, height: 0)
                    .onAppear {
                        configureMenuBarControllerIfNeeded()
                        DispatchQueue.main.async {
                            for window in NSApplication.shared.windows where window.level == .normal {
                                window.close()
                            }
                        }
                    }
            } else {
                Group {
                    if appSettings.onboardingCompleted {
                        ContentView(
                            appSettings: appSettings,
                            onCheckAppUpdates: checkForAppUpdates
                        )
                    } else {
                        OnboardingView(appSettings: appSettings) {
                            focusMainWindowIfNeeded()
                        }
                    }
                }
                .onAppear {
                    menuBarController = nil
                    focusMainWindowIfNeeded()
                }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Intentionally empty to disable Command-N new window.
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...", action: checkForAllUpdates)
            }
        }
    }

    private var settingsScene: some Scene {
        Settings {
            SettingsView(
                updater: updaterController.updater,
                appSettings: appSettings
            )
        }
    }

    private func checkForAppUpdates() {
        guard updaterController.updater.canCheckForUpdates else { return }
        updaterController.updater.checkForUpdates()
    }

    private func checkForAllUpdates() {
        checkForAppUpdates()
        Task.detached(priority: .utility) {
            await GitHubUpdateService.shared.checkForUpdates()
        }
    }

    private func focusMainWindowIfNeeded() {
        guard !launchMenubarOnlyMode else { return }

        // Window creation races app activation during relaunch from accessory mode.
        // Focus once immediately and once shortly after to catch late window creation.
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first(where: { $0.level == .normal })?.makeKeyAndOrderFront(nil)
        }
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }

    private func switchToDockMode() {
        AppRelauncher.relaunch(menubarOnly: false)
    }

    private func configureMenuBarControllerIfNeeded() {
        guard launchMenubarOnlyMode else {
            menuBarController = nil
            return
        }
        guard menuBarController == nil else { return }
        menuBarController = MenuBarController(
            appSettings: appSettings,
            onCheckAllUpdates: checkForAllUpdates,
            onSwitchToDockMode: switchToDockMode,
            onQuit: quitApp
        )
    }
}

private final class DownloadNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            DownloadNotificationService.shared.handleNotificationResponse(response)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

private enum AppModeController {
    static func applyMenubarOnlyMode(_ enabled: Bool) {
        if !enabled {
            // LSUIElement = YES starts the app as .accessory (no Dock icon).
            // For window mode, upgrade to .regular so Dock icon and app menu appear.
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

enum AppRelauncher {
    static func relaunch(menubarOnly: Bool) {
        let appPath = Bundle.main.bundlePath
        guard !appPath.isEmpty else {
            NSApplication.shared.terminate(nil)
            return
        }

        let modeArgument = menubarOnly ? LaunchArguments.menubarOnly : LaunchArguments.windowMode
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appPath, "--args", modeArgument]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
