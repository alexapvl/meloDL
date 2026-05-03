import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let appSettings: AppSettings
    private let onCheckAllUpdates: () -> Void
    private let onSwitchToDockMode: () -> Void
    private let onQuit: () -> Void

    init(
        appSettings: AppSettings,
        onCheckAllUpdates: @escaping () -> Void,
        onSwitchToDockMode: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.appSettings = appSettings
        self.onCheckAllUpdates = onCheckAllUpdates
        self.onSwitchToDockMode = onSwitchToDockMode
        self.onQuit = onQuit
        super.init()
        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        if let image = NSImage(named: "MenuBarLogo") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "meloDL"
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let rootView = MenuBarContentView(
            appSettings: appSettings,
            onCheckAppUpdates: onCheckAllUpdates,
            onQuit: onQuit
        )
        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.contentSize = NSSize(width: 580, height: 640)
        popover.behavior = .transient
    }

    @objc
    private func handleStatusItemAction(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        let eventType = NSApp.currentEvent?.type

        if eventType == .rightMouseUp {
            if popover.isShown {
                popover.performClose(sender)
            }
            showRightClickMenu(from: button)
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showRightClickMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let openAtLoginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleOpenAtLogin(_:)),
            keyEquivalent: ""
        )
        openAtLoginItem.state = appSettings.openAtLogin ? .on : .off
        openAtLoginItem.target = self
        menu.addItem(openAtLoginItem)

        menu.addItem(.separator())

        let updatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu.addItem(updatesItem)

        let switchModeItem = NSMenuItem(
            title: "Switch to Dock Mode",
            action: #selector(switchToDockMode(_:)),
            keyEquivalent: ""
        )
        switchModeItem.target = self
        menu.addItem(switchModeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit meloDL",
            action: #selector(quitApp(_:)),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc
    private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let newValue = !appSettings.openAtLogin
        appSettings.openAtLogin = newValue
        LoginItemService.setEnabled(newValue)
    }

    @objc
    private func checkForUpdates(_ sender: NSMenuItem) {
        onCheckAllUpdates()
    }

    @objc
    private func switchToDockMode(_ sender: NSMenuItem) {
        appSettings.openAtLogin = false
        LoginItemService.setEnabled(false)
        onSwitchToDockMode()
    }

    @objc
    private func quitApp(_ sender: NSMenuItem) {
        onQuit()
    }
}
