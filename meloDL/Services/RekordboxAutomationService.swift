import AppKit
import ApplicationServices
import Foundation
import os

enum RekordboxAutomationError: LocalizedError {
    case notRunning
    case accessibilityDenied
    case automationDenied
    case menuNotFound
    case lostFocus
    case dialogDidNotOpen
    case dialogStuck
    case exportTimedOut
    case scriptFailed(String)

    /// Errors that won't go away by retrying, as opposed to a dialog that got stuck once.
    var cannotControlRekordbox: Bool {
        switch self {
        case .accessibilityDenied, .automationDenied, .menuNotFound: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Open Rekordbox, then try again."
        case .accessibilityDenied:
            return "meloDL needs Accessibility access to control Rekordbox. Allow it under Permissions in Settings > Rekordbox, then try again."
        case .automationDenied:
            return "meloDL needs permission to control System Events. Allow it under Permissions in Settings > Rekordbox, then try again."
        case .menuNotFound:
            return "meloDL couldn't find Rekordbox's File menu items. This only works with Rekordbox set to English."
        case .lostFocus:
            return "Rekordbox lost focus, so meloDL stopped typing. Keep Rekordbox in front until it finishes."
        case .dialogDidNotOpen:
            return "Rekordbox didn't open its file dialog. Close any open Rekordbox dialogs and try again."
        case .dialogStuck:
            return "Rekordbox's file dialog didn't close. Check Rekordbox for a message."
        case .exportTimedOut:
            return "Rekordbox didn't finish exporting the collection."
        case .scriptFailed(let message):
            return message
        }
    }
}

enum AutomationPermission {
    case granted
    case denied
    case notDetermined
    case unknown
}

/// Drives Rekordbox's File menu through System Events, the only automation Rekordbox exposes.
@MainActor
final class RekordboxAutomationService {
    static let shared = RekordboxAutomationService()

    private static let bundleIdentifier = "com.pioneerdj.rekordboxdj"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "RekordboxAutomation")

    var isRekordboxRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    /// Whether meloDL may send Apple Events to System Events. `ask` shows the macOS prompt when undecided.
    func systemEventsPermission(ask: Bool) async -> AutomationPermission {
        let systemEventsID = "com.apple.systemevents"
        // The check needs System Events running; it's a background app, so launching it shows nothing.
        if NSRunningApplication.runningApplications(withBundleIdentifier: systemEventsID).isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app"),
                configuration: configuration
            )
        }

        return await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: systemEventsID)
            guard let descriptor = target.aeDesc else { return .unknown }
            let status = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, ask)
            switch Int(status) {
            case Int(noErr): return .granted
            case Int(errAEEventNotPermitted): return .denied
            case Int(errAEEventWouldRequireUserConsent): return .notDetermined
            default: return .unknown
            }
        }.value
    }

    /// File > Export Collection in xml format, saved to `fileURL`.
    func exportCollection(to fileURL: URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An existing file would make Rekordbox ask to replace it.
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }

        try await runFileDialogAction(.export, path: fileURL.path)
        try await waitForFinishedFile(at: fileURL)
    }

    /// File > Import > Import Track for one file.
    func importTrack(at fileURL: URL) async throws {
        try await runFileDialogAction(.importTrack, path: fileURL.path)
    }

    /// File > Import > Import Playlist. Rekordbox adds every file to the collection and makes a playlist
    /// named after the playlist file.
    func importPlaylist(at fileURL: URL) async throws {
        try await runFileDialogAction(.importPlaylist, path: fileURL.path)
    }

    /// Deletes the playlist an import just created, after reading the screen to make sure it's that one:
    /// the sidebar entry, the browser header with the track count, and the name in the confirmation dialog.
    /// Returns false, deleting nothing, when any check doesn't match.
    func deleteImportedPlaylist(named name: String, trackCount: Int) async -> Bool {
        guard CGPreflightScreenCaptureAccess(), isRekordboxRunning else { return false }
        let reader = RekordboxScreenReader()

        do {
            guard try await bringRekordboxToFront(),
                  let entry = try await reader.findSidebarEntry(named: name) else {
                logger.warning("Import playlist \(name, privacy: .public) not found in the sidebar")
                return false
            }
            guard isRekordboxFrontmost else { return false }
            reader.click(entry)
            try await Task.sleep(nanoseconds: 800_000_000)

            guard try await reader.headerShows(name: name, trackCount: trackCount),
                  try await isMenuItemEnabled("Delete Playlist", menu: "Playlist"),
                  isRekordboxFrontmost else {
                logger.warning("Selected playlist didn't match \(name, privacy: .public); left it in place")
                return false
            }

            try await clickMenuItem("Delete Playlist", menu: "Playlist")
            try await Task.sleep(nanoseconds: 700_000_000)
            guard let okButton = try await reader.confirmationOKButton(naming: name), isRekordboxFrontmost else {
                logger.warning("Delete dialog didn't name \(name, privacy: .public); cancelling")
                await pressEscapeIfFrontmost()
                return false
            }
            reader.click(okButton)
            try await Task.sleep(nanoseconds: 500_000_000)
            return true
        } catch {
            logger.failure("Removing the import playlist failed: \(error.localizedDescription)")
            return false
        }
    }

    private var isRekordboxFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleIdentifier
    }

    private func bringRekordboxToFront() async throws -> Bool {
        let output = try await Self.runOSAScript(
            #"tell application "System Events" to tell process "rekordbox" to set frontmost to true"#,
            arguments: []
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        return output.exitCode == 0 && isRekordboxFrontmost
    }

    private func isMenuItemEnabled(_ item: String, menu: String) async throws -> Bool {
        let output = try await Self.runOSAScript(
            #"on run argv"# + "\n" +
            #"tell application "System Events" to tell process "rekordbox" to return enabled of menu item (item 1 of argv) of menu (item 2 of argv) of menu bar 1"# + "\n" +
            "end run",
            arguments: [item, menu]
        )
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func clickMenuItem(_ item: String, menu: String) async throws {
        let output = try await Self.runOSAScript(
            #"on run argv"# + "\n" +
            #"tell application "System Events" to tell process "rekordbox" to click menu item (item 1 of argv) of menu (item 2 of argv) of menu bar 1"# + "\n" +
            "end run",
            arguments: [item, menu]
        )
        guard output.exitCode == 0 else { throw Self.error(fromStderr: output.stderr) }
    }

    private func pressEscapeIfFrontmost() async {
        guard isRekordboxFrontmost else { return }
        _ = try? await Self.runOSAScript(#"tell application "System Events" to key code 53"#, arguments: [])
    }

    private enum Action: String {
        case export
        case importTrack
        case importPlaylist
    }

    private func runFileDialogAction(_ action: Action, path: String) async throws {
        guard isRekordboxRunning else { throw RekordboxAutomationError.notRunning }
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
            throw RekordboxAutomationError.accessibilityDenied
        }

        // Typing non-ASCII paths into the dialog drops characters, so the path is pasted instead.
        let pasteboard = NSPasteboard.general
        let savedItems = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        defer { Self.restore(savedItems, to: pasteboard) }

        let output = try await Self.runOSAScript(Self.fileDialogScript, arguments: [action.rawValue])
        guard output.exitCode != 0 else { return }

        logger.failure("Rekordbox \(action.rawValue) failed: \(output.stderr)")
        throw Self.error(fromStderr: output.stderr)
    }

    private func waitForFinishedFile(at fileURL: URL) async throws {
        var lastSize: Int64 = -1
        for _ in 0 ..< 120 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0, size == lastSize, Self.endsWithClosingTag(fileURL) {
                return
            }
            lastSize = size
        }
        throw RekordboxAutomationError.exportTimedOut
    }

    private static func endsWithClosingTag(_ fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 64 else { return false }
        try? handle.seek(toOffset: end - 64)
        let tail = (try? handle.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return tail.contains("</DJ_PLAYLISTS>")
    }

    private static func error(fromStderr stderr: String) -> RekordboxAutomationError {
        let code = stderr.range(of: #"\((-?\d+)\)\s*$"#, options: .regularExpression)
            .flatMap { Int(stderr[$0].trimmingCharacters(in: CharacterSet(charactersIn: "() \n"))) }
        switch code {
        case 1001: return .notRunning
        case 1002: return .lostFocus
        case 1003: return .dialogDidNotOpen
        case 1004: return .dialogStuck
        case -1719, -25211: return .accessibilityDenied
        case -1743: return .automationDenied
        case -1728: return .menuNotFound
        default:
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .scriptFailed(message.isEmpty ? "Controlling Rekordbox failed." : message)
        }
    }

    // MARK: - Pasteboard

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entries: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                entries[type] = item.data(forType: type)
            }
            return entries
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    // MARK: - Script

    private static func runOSAScript(_ source: String, arguments: [String]) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"] + arguments

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessOutput(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: stdout, encoding: .utf8) ?? "",
                    stderr: String(data: stderr, encoding: .utf8) ?? ""
                ))
            }

            do {
                try process.run()
                stdinPipe.fileHandleForWriting.write(Data(source.utf8))
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Every keystroke is preceded by a frontmost check, so nothing is typed into another app.
    private static let fileDialogScript = """
    on run argv
        set requestedAction to item 1 of argv
        tell application "System Events"
            if not (exists process "rekordbox") then error "Rekordbox is not open." number 1001
            tell process "rekordbox"
                set frontmost to true
                delay 0.6
                if not frontmost then error "Rekordbox is not in front." number 1002
                set baseWindowCount to count of windows
                if requestedAction is "export" then
                    click menu item "Export Collection in xml format" of menu "File" of menu bar 1
                else if requestedAction is "importPlaylist" then
                    click menu item "Import Playlist" of menu "Import" of menu item "Import" of menu "File" of menu bar 1
                else
                    click menu item "Import Track" of menu "Import" of menu item "Import" of menu "File" of menu bar 1
                end if
                repeat 50 times
                    if (count of windows) > baseWindowCount then exit repeat
                    delay 0.1
                end repeat
                if (count of windows) is less than or equal to baseWindowCount then error "No file dialog." number 1003
                -- Rekordbox can open other windows while importing, so wait on the dialog itself.
                set dialogName to name of window 1
                try
                    delay 0.4
                    if not frontmost then error "Rekordbox is not in front." number 1002
                    keystroke "g" using {command down, shift down}
                    delay 0.8
                    if not frontmost then error "Rekordbox is not in front." number 1002
                    keystroke "v" using {command down}
                    delay 0.5
                    if not frontmost then error "Rekordbox is not in front." number 1002
                    key code 36
                    delay 0.8
                    if not frontmost then error "Rekordbox is not in front." number 1002
                    key code 36
                    repeat 150 times
                        if not (exists window dialogName) then exit repeat
                        delay 0.1
                    end repeat
                    if exists window dialogName then error "File dialog still open." number 1004
                on error errorMessage number errorNumber
                    if frontmost and (exists window dialogName) then key code 53
                    error errorMessage number errorNumber
                end try
            end tell
        end tell
    end run
    """
}
