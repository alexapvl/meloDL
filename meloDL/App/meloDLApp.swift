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
    static let forcedOnboardingV102Applied = "settings.forcedOnboardingV102Applied"
}

enum AppWindowID {
    static let main = "main"
}

@main
@MainActor
struct meloDLApp: App {
    @StateObject private var appSettings: AppSettings
    @StateObject private var sessionCoordinator: DownloadSessionCoordinator
    @State private var didTriggerLaunchReindex = false
    @State private var isShowingSettings = false
    @State private var settingsDestination: SettingsDestination = .downloads
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycleDelegate
    private let notificationDelegate = DownloadNotificationCenterDelegate()
    private let launchMenubarOnlyMode: Bool
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: SettingsKeys.forcedOnboardingV102Applied) {
            defaults.set(false, forKey: SettingsKeys.onboardingCompleted)
            defaults.set(true, forKey: SettingsKeys.forcedOnboardingV102Applied)
        }

        if CommandLine.arguments.contains(LaunchArguments.menubarOnly) {
            defaults.set(true, forKey: SettingsKeys.menubarOnlyMode)
        } else if CommandLine.arguments.contains(LaunchArguments.windowMode) {
            defaults.set(false, forKey: SettingsKeys.menubarOnlyMode)
        }

        let isMenubarOnly = defaults.bool(forKey: SettingsKeys.menubarOnlyMode)
        let onboardingCompleted = defaults.bool(forKey: SettingsKeys.onboardingCompleted)
        let appSettings = AppSettings()
        let sessionCoordinator = DownloadSessionCoordinator(appSettings: appSettings)
        _appSettings = StateObject(wrappedValue: appSettings)
        _sessionCoordinator = StateObject(wrappedValue: sessionCoordinator)
        AppLifecycleDelegate.sessionCoordinator = sessionCoordinator
        self.launchMenubarOnlyMode = isMenubarOnly && onboardingCompleted
        UNUserNotificationCenter.current().delegate = notificationDelegate
        DownloadNotificationService.shared.configureNotificationCategories()
        AppModeController.applyMenubarOnlyMode(launchMenubarOnlyMode)
        LoginItemService.setEnabled(defaults.bool(forKey: SettingsKeys.openAtLogin))
    }

    var body: some Scene {
        mainWindowScene
    }

    private var mainWindowScene: some Scene {
        Window("meloDL", id: AppWindowID.main) {
            mainWindowContent
            .background {
                MainWindowChromeConfigurator()
                    .frame(width: 0, height: 0)
            }
        }
        .defaultLaunchBehavior(.presented)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Intentionally empty to disable Command-N new window.
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...", action: checkForAllUpdates)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...", action: showSettingsPage)
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private var mainWindowContent: some View {
        ZStack {
            mainWindowPages
        }
        .animation(.smooth(duration: 0.2), value: isShowingSettings)
    }

    @ViewBuilder
    private var mainWindowPages: some View {
        if appSettings.onboardingCompleted && isShowingSettings {
            #if DEBUG
            SettingsView(
                updater: updaterController.updater,
                appSettings: appSettings,
                initialDestination: settingsDestination,
                onDismiss: closeSettingsPage,
                onReplayOnboarding: replayOnboarding
            )
            .disableFocusRings()
            .transition(.opacity)
            #else
            SettingsView(
                updater: updaterController.updater,
                appSettings: appSettings,
                initialDestination: settingsDestination,
                onDismiss: closeSettingsPage
            )
            .disableFocusRings()
            .transition(.opacity)
            #endif
        } else if launchMenubarOnlyMode && appSettings.onboardingCompleted {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    triggerLaunchReindexIfNeeded()
                    configureMenuBarControllerIfNeeded()
                    DispatchQueue.main.async {
                        closeMenubarLaunchPlaceholderWindowsIfNeeded()
                    }
                }
        } else {
            Group {
                if appSettings.onboardingCompleted {
                    ContentView(
                        appSettings: appSettings,
                        coordinator: sessionCoordinator,
                        onOpenSettings: showSettingsPage(_:)
                    )
                } else {
                    OnboardingView(
                        appSettings: appSettings,
                        updater: updaterController.updater
                    ) {
                        focusMainWindowIfNeeded()
                    }
                }
            }
            .onAppear {
                triggerLaunchReindexIfNeeded()
                appLifecycleDelegate.menuBarController = nil
                focusMainWindowIfNeeded()
                DispatchQueue.main.async {
                    consolidateMainWindows()
                }
            }
            .disableFocusRings()
            .transition(.opacity)
        }
    }

    private func checkForAppUpdates() {
        guard updaterController.updater.canCheckForUpdates else { return }
        updaterController.updater.checkForUpdates()
    }

    private func checkForAllUpdates() {
        sessionCoordinator.checkForAllUpdates(checkForAppUpdates: checkForAppUpdates)
    }

    #if DEBUG
    private func replayOnboarding() {
        appSettings.onboardingCompleted = false
        isShowingSettings = false
        AppModeController.applyMenubarOnlyMode(false)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            consolidateMainWindows()
            mainAppWindow()?.makeKeyAndOrderFront(nil)
        }
    }
    #endif

    private func showSettingsPage() {
        showSettingsPage(.downloads)
    }

    private func showSettingsPage(_ destination: SettingsDestination) {
        settingsDestination = destination
        isShowingSettings = true

        if mainAppWindow() == nil {
            openWindow(id: AppWindowID.main)
        }

        DispatchQueue.main.async {
            consolidateMainWindows()
        }

        if launchMenubarOnlyMode {
            focusMainWindowIfNeeded(allowMenubarLaunch: true)
        }
    }

    private func closeSettingsPage() {
        isShowingSettings = false

        if launchMenubarOnlyMode && appSettings.onboardingCompleted {
            DispatchQueue.main.async {
                for window in NSApplication.shared.windows where window.level == .normal {
                    window.close()
                }
                AppModeController.applyMenubarOnlyMode(true)
            }
        }
    }

    private func focusMainWindowIfNeeded(allowMenubarLaunch: Bool = false) {
        guard allowMenubarLaunch || !launchMenubarOnlyMode else { return }

        // Window creation races app activation during relaunch from accessory mode.
        // Focus once immediately and once shortly after to catch late window creation.
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            mainAppWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    private func mainAppWindow() -> NSWindow? {
        NSApplication.shared.windows.first {
            $0.level == .normal && $0.canBecomeKey && !$0.isMiniaturized
        }
    }

    private func consolidateMainWindows() {
        let mainWindows = NSApplication.shared.windows.filter {
            $0.level == .normal && $0.canBecomeKey && !$0.isMiniaturized
        }
        guard mainWindows.count > 1 else { return }

        let keeper = mainWindows.first(where: \.isKeyWindow) ?? mainWindows.first
        for window in mainWindows where window !== keeper {
            window.close()
        }
    }

    private func closeMenubarLaunchPlaceholderWindowsIfNeeded() {
        guard launchMenubarOnlyMode, appSettings.onboardingCompleted, !isShowingSettings else { return }

        for window in NSApplication.shared.windows where window.level == .normal {
            window.close()
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
            appLifecycleDelegate.menuBarController = nil
            return
        }
        guard appLifecycleDelegate.menuBarController == nil else { return }
        appLifecycleDelegate.menuBarController = MenuBarController(
            appSettings: appSettings,
            sessionCoordinator: sessionCoordinator,
            onCheckAllUpdates: checkForAllUpdates,
            onOpenSettings: showSettingsPage(_:),
            onSwitchToDockMode: switchToDockMode,
            onQuit: quitApp
        )
    }

    private func triggerLaunchReindexIfNeeded() {
        guard !didTriggerLaunchReindex else { return }
        didTriggerLaunchReindex = true
        let rootsSnapshot = appSettings.duplicateIndexRoots
        Task.detached(priority: .utility) {
            await TrackIndexer.shared.reindexNow(roots: rootsSnapshot)
        }
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

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    static weak var sessionCoordinator: DownloadSessionCoordinator?
    var menuBarController: MenuBarController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let menubarOnly = UserDefaults.standard.bool(forKey: SettingsKeys.menubarOnlyMode)
        let onboardingCompleted = UserDefaults.standard.bool(forKey: SettingsKeys.onboardingCompleted)
        return !(menubarOnly && onboardingCompleted)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sessionCoordinator = Self.sessionCoordinator, sessionCoordinator.hasActiveSessionsForQuit else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit and cancel active downloads?"
        alert.informativeText = "Active sessions will be marked as cancelled. Waiting and review sessions will stay in your history."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit and Cancel Downloads")
        alert.addButton(withTitle: "Stay")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await sessionCoordinator.cancelActiveSessionsForQuitAndPersist()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateCancel
    }
}

private struct MainWindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(from: nsView)
    }

    private func configureWindow(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

private enum AppModeController {
    static func applyMenubarOnlyMode(_ enabled: Bool) {
        if enabled {
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
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
