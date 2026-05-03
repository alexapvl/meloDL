import AppKit
import Foundation
import UserNotifications
import os

@MainActor
final class DownloadNotificationService {
    static let shared = DownloadNotificationService()

    static let notificationIdentifierPrefix = "download-finished-"
    static let downloadFolderPathKey = "downloadFolderPath"
    static let categoryIdentifier = "DOWNLOAD_FINISHED_CATEGORY"
    static let openFolderActionIdentifier = "OPEN_DOWNLOAD_FOLDER_ACTION"

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "DownloadNotificationService")

    private init() {}

    func configureNotificationCategories() {
        let openFolderAction = UNNotificationAction(
            identifier: Self.openFolderActionIdentifier,
            title: "Open Folder",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [openFolderAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func postDownloadFinishedNotification(folderURL: URL) {
        Task {
            let authorized = await ensureNotificationAuthorization()
            guard authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Download finished"
            content.body = "Use Open Folder to reveal your download"
            content.sound = .default
            content.userInfo = [Self.downloadFolderPathKey: folderURL.path]
            content.categoryIdentifier = Self.categoryIdentifier

            let request = UNNotificationRequest(
                identifier: Self.notificationIdentifierPrefix + UUID().uuidString,
                content: content,
                trigger: nil
            )

            do {
                try await addRequest(request)
            } catch {
                logger.error("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard response.actionIdentifier == Self.openFolderActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        guard let folderPath = userInfo[Self.downloadFolderPathKey] as? String else { return }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        NSWorkspace.shared.open(folderURL)
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        await ensureNotificationAuthorization()
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await notificationSettings()
        return settings.authorizationStatus
    }

    private func ensureNotificationAuthorization() async -> Bool {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await requestAuthorization()
            } catch {
                logger.error("Notification authorization failed: \(error.localizedDescription)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func addRequest(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
